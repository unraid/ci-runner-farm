package sharedcapacity

import (
	"errors"
	"fmt"
	"reflect"
	"testing"
)

func TestRenewStoppedPreservesChargeAndRejectsStaleRelease(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	grant := requireGrant(t, b, &policy, "qa-1", "qa")
	for index := range 8 {
		requireGrant(t, b, &policy, fmt.Sprint("builder-", index), buildPool)
	}
	if decision, err := b.Admit(&policy, Request{ID: "waiting-guest", Pool: "qa"}); err != nil || decision.Admitted || decision.Pending == nil {
		t.Fatal("fixture lacks waiting demand", decision, err)
	}
	before, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	renewed, err := b.RenewStopped(&policy, &grant, func(observed Grant) error {
		if !reflect.DeepEqual(observed, grant) {
			t.Fatal("proof received another grant")
		}
		return nil
	})
	if err != nil || renewed.Request != grant.Request || renewed.Cost != grant.Cost || renewed.Fence == grant.Fence || renewed.Fence == "" {
		t.Fatal(renewed, err)
	}
	after, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	before.Grants[grant.ID] = renewed
	if !reflect.DeepEqual(before, after) {
		t.Fatal("renewal changed policy, charge or pending demand")
	}
	if err := b.Release(&policy, grant.ID, grant.Fence, func(Grant) error { t.Fatal("stale fence reached proof"); return nil }); !errors.Is(err, ErrFenceMismatch) {
		t.Fatal(err)
	}
	if err := b.Release(&policy, renewed.ID, renewed.Fence, func(Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestRenewStoppedFailsClosed(t *testing.T) {
	for _, change := range []string{"nil", "wrong-fence", "changed-request", "changed-charge", "changed-timestamp", "failed-proof", "missing-proof", "changed-policy"} {
		t.Run(change, func(t *testing.T) {
			policy := hostPolicy()
			b := newBroker(t, &policy)
			grant := requireGrant(t, b, &policy, "qa-1", "qa")
			before, err := b.Status(&policy)
			if err != nil {
				t.Fatal(err)
			}
			expected := &grant
			proof := func(Grant) error { return nil }
			switch change {
			case "nil":
				expected = nil
			case "wrong-fence":
				grant.Fence = "old-fence"
			case "changed-request":
				grant.Resources.MemoryMiB++
			case "changed-charge":
				grant.Cost.MemoryMiB++
			case "changed-timestamp":
				grant.GrantedAt = grant.GrantedAt.Add(1)
			case "failed-proof":
				proof = func(Grant) error { return errors.New("running or unknown") }
			case "missing-proof":
				proof = nil
			case "changed-policy":
				policy.Budget.MemoryMiB++
			}
			if _, renewErr := b.RenewStopped(&policy, expected, proof); renewErr == nil {
				t.Fatal("invalid continuation accepted")
			}
			after, err := b.Status(&before.Policy)
			if err != nil || !reflect.DeepEqual(before, after) {
				t.Fatal("rejected continuation changed ledger", err)
			}
		})
	}
}
