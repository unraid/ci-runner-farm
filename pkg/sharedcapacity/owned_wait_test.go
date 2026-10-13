package sharedcapacity

import (
	"errors"
	"reflect"
	"testing"
	"time"
)

const differentWaitOwner = "different-owner"

func waitOwner() *WaitOwner {
	return &WaitOwner{PrincipalID: "consumer", ReservationID: "reservation", CapacityID: "capacity", OperationID: "operation", RequestKey: "hardware", Generation: 7, Incarnation: "attempt"}
}

func TestSuspendedOwnedWaitKeepsAgeAndLetsLaterDemandProgress(t *testing.T) {
	policy := hostPolicy()
	broker := diagnosticBroker(t, &policy)
	for index := range 8 {
		requireGrant(t, broker, &policy, string(rune('a'+index)), buildPool)
	}
	occupied := requireGrant(t, broker, &policy, "occupied", "qa")
	request := Request{ID: "head", Pool: "qa"}
	owner := waitOwner()
	decision, err := broker.AdmitOwned(&policy, request, owner)
	if err != nil || decision.Admitted || decision.Pending == nil {
		t.Fatal(decision, err)
	}
	expected := *decision.Pending
	if checkErr1 := broker.SuspendPending(&policy, &expected, func() error { return nil }); checkErr1 != nil {
		t.Fatal(checkErr1)
	}
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	assertOwnedLedger(t, broker, &policy, &before, &expected)
	if checkErr2 := broker.Release(&policy, occupied.ID, occupied.Fence, func(Grant) error { return nil }); checkErr2 != nil {
		t.Fatal(checkErr2)
	}
	requireGrant(t, broker, &policy, "later", "qa")
	report, err := broker.Diagnose(&policy)
	if err != nil || len(report.Pending) != 1 || report.Pending[0].Reason != "owner_wait_ended" || report.QueueHead == request.ID {
		t.Fatal(report, err)
	}
	if report.Pending[0].Owner.Incarnation == owner.Incarnation {
		t.Fatal("diagnostics exposed raw owner incarnation")
	}
	drain, drainErr := PlanDrain(&before, nil, expected.QueuedAt.Add(time.Minute))
	if drainErr != nil || drain.WaitingID != "" || len(drain.Grants) != 0 {
		t.Fatal("ended wait triggered workload withdrawal", drain, drainErr)
	}
	if _, checkErr3 := broker.Admit(&policy, request); checkErr3 == nil {
		t.Fatal("unowned caller resumed owned demand")
	}
	if checkErr4 := broker.Cancel(&policy, request); checkErr4 == nil {
		t.Fatal("unowned caller canceled owned demand")
	}
	changed := *owner
	changed.OperationID = "later-operation"
	if _, checkErr5 := broker.AdmitOwned(&policy, request, &changed); checkErr5 == nil {
		t.Fatal("different operation resumed owned demand")
	}
	resumed, err := broker.AdmitOwned(&policy, request, owner)
	if err != nil || resumed.Admitted || resumed.Pending.Suspended || !resumed.Pending.QueuedAt.Equal(expected.QueuedAt) {
		t.Fatal("exact retry lost original age", resumed, err)
	}
	if checkErr6 := broker.SuspendPending(&policy, &expected, func() error { t.Fatal("prior wait reached proof after resume"); return nil }); checkErr6 == nil {
		t.Fatal("prior wait suspended resumed demand")
	}
}

func TestSuspendPendingRejectsStaleOwnersUnknownStateAndGrants(t *testing.T) {
	policy := hostPolicy()
	broker := newBroker(t, &policy)
	for index := range 8 {
		requireGrant(t, broker, &policy, string(rune('a'+index)), buildPool)
	}
	occupied := requireGrant(t, broker, &policy, "occupied", "qa")
	decision, err := broker.AdmitOwned(&policy, Request{ID: "owned-wait", Pool: "qa"}, waitOwner())
	if err != nil {
		t.Fatal(err)
	}
	expected := *decision.Pending
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*Pending){
		func(p *Pending) { p.Owner.OperationID = differentWaitOwner },
		func(p *Pending) { p.Owner.ReservationID = differentWaitOwner },
		func(p *Pending) { p.Owner.Generation++ },
		func(p *Pending) { p.Owner.Incarnation = differentWaitOwner },
		func(p *Pending) { p.QueuedAt = p.QueuedAt.Add(time.Nanosecond) },
		func(p *Pending) { p.Resources.VCPUs = 1 },
	} {
		stale := expected
		staleOwner := *expected.Owner
		stale.Owner = &staleOwner
		mutate(&stale)
		if checkErr7 := broker.SuspendPending(&policy, &stale, func() error { t.Fatal("stale owner reached stopped proof"); return nil }); checkErr7 == nil {
			t.Fatal("stale owner suspended demand")
		}
	}
	if checkErr8 := broker.SuspendPending(&policy, &expected, func() error { return errors.New("unknown domain") }); checkErr8 == nil {
		t.Fatal("unknown state suspended")
	}
	after, err := broker.Status(&policy)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("rejected suspension mutated state", err)
	}
	if checkErr9 := broker.Release(&policy, occupied.ID, occupied.Fence, func(Grant) error { return nil }); checkErr9 != nil {
		t.Fatal(checkErr9)
	}
	granted, err := broker.AdmitOwned(&policy, expected.Request, expected.Owner)
	if err != nil || !granted.Admitted {
		t.Fatal(granted, err)
	}
	if checkErr10 := broker.SuspendPending(&policy, &expected, func() error { t.Fatal("granted workload reached proof"); return nil }); checkErr10 == nil {
		t.Fatal("grant suspended")
	}
	after, err = broker.Status(&policy)
	if err != nil || after.Grants[expected.ID].Fence != granted.Grant.Fence {
		t.Fatal("grant fence changed", err)
	}
}

func assertOwnedLedger(t *testing.T, broker *Broker, policy *Policy, before *Snapshot, expected *Pending) {
	t.Helper()
	if !before.Pending[expected.ID].Suspended || !before.Pending[expected.ID].QueuedAt.Equal(expected.QueuedAt) || before.Schema != ownedWaitLedgerSchema {
		t.Fatal("owned wait or age lost", before)
	}
	legacy := *before
	legacy.Schema = ledgerSchema
	if checkErr11 := validateSnapshot(&legacy); checkErr11 == nil {
		t.Fatal("owned waits accepted under a downlevel schema")
	}
	if checkErr12 := broker.Initialize(policy, func() error { t.Fatal("existing owner ledger reset"); return nil }); checkErr12 != nil {
		t.Fatal(checkErr12)
	}
}
