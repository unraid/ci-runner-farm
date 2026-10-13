package sharedcapacity

import (
	"errors"
	"reflect"
	"testing"
	"time"
)

func TestCancelPendingPreservesOtherDemandAndFencedGrants(t *testing.T) {
	policy := hostPolicy()
	broker := newBroker(t, &policy)
	for index := range 8 {
		requireGrant(t, broker, &policy, string(rune('a'+index)), buildPool)
	}
	occupied := requireGrant(t, broker, &policy, "occupied", "qa")
	for _, id := range []string{"abandoned", "valid"} {
		decision, err := broker.Admit(&policy, Request{ID: id, Pool: "qa"})
		if err != nil || decision.Admitted {
			t.Fatal(decision, err)
		}
	}
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	expectedAbandoned := before.Pending["abandoned"]
	proofs := 0
	cancelled, err := broker.CancelPending(&policy, &expectedAbandoned, func() error { proofs++; return nil })
	if err != nil || !cancelled || proofs != 1 {
		t.Fatal(cancelled, err, proofs)
	}
	after, err := broker.Status(&policy)
	if err != nil || !reflect.DeepEqual(before.Grants, after.Grants) || after.Pending["valid"] != before.Pending["valid"] {
		t.Fatal("unrelated state changed", err)
	}
	if cancelled, err = broker.CancelPending(&policy, &expectedAbandoned, func() error { t.Fatal("repeated cancellation attested"); return nil }); err != nil || cancelled {
		t.Fatal(cancelled, err)
	}
	if cancelled, err = broker.CancelPending(&policy, &Pending{Request: occupied.Request, QueuedAt: time.Now()}, func() error { return nil }); err == nil || cancelled {
		t.Fatal("granted request cancelled")
	}
}

func TestCancelPendingRejectsChangedIncarnationAndFailedProof(t *testing.T) {
	policy := hostPolicy()
	broker := newBroker(t, &policy)
	for index := range 8 {
		requireGrant(t, broker, &policy, string(rune('a'+index)), buildPool)
	}
	requireGrant(t, broker, &policy, "occupied", "qa")
	request := Request{ID: "waiting", Pool: "qa"}
	if _, err := broker.Admit(&policy, request); err != nil {
		t.Fatal(err)
	}
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	expected := before.Pending[request.ID]
	for _, changed := range []Pending{
		{Request: expected.Request, QueuedAt: expected.QueuedAt.Add(time.Nanosecond)},
		{Request: Request{ID: request.ID, Pool: request.Pool, Resources: Resources{MemoryMiB: 1024, VCPUs: 1}}, QueuedAt: expected.QueuedAt},
	} {
		if cancelled, cancelErr := broker.CancelPending(&policy, &changed, func() error { t.Fatal("stale cleanup reached proof"); return nil }); cancelErr == nil || cancelled {
			t.Fatal("stale pending removed")
		}
	}
	if cancelled, cancelErr := broker.CancelPending(&policy, &expected, func() error { return errors.New("unknown domain state") }); cancelErr == nil || cancelled {
		t.Fatal("unknown workload removed")
	}
	after, err := broker.Status(&policy)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("rejected cancellation changed ledger", err)
	}
	if cancelErr := broker.Cancel(&policy, request); cancelErr != nil {
		t.Fatal(cancelErr)
	}
	broker.Now = func() time.Time { return expected.QueuedAt.Add(time.Minute) }
	if _, admitErr := broker.Admit(&policy, request); admitErr != nil {
		t.Fatal(admitErr)
	}
	if cancelled, staleErr := broker.CancelPending(&policy, &expected, func() error { return nil }); staleErr == nil || cancelled {
		t.Fatal("replacement request removed by old cleanup")
	}
	queued, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	for _, grant := range queued.Grants {
		releaseGrant(t, broker, &policy, &grant)
	}
	decision, err := broker.Admit(&policy, request)
	if err != nil || !decision.Admitted {
		t.Fatal(decision, err)
	}
	queuedPending := queued.Pending[request.ID]
	if cancelled, cancelErr := broker.CancelPending(&policy, &queuedPending, func() error { return nil }); cancelErr == nil || cancelled {
		t.Fatal("promoted grant removed by pending cleanup")
	}
	afterPromotion, statusErr := broker.Status(&policy)
	if statusErr != nil || afterPromotion.Grants[request.ID] != *decision.Grant {
		t.Fatal("grant fence changed", statusErr)
	}
}
