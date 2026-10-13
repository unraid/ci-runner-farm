package sharedcapacity

import (
	"bytes"
	"errors"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"
)

func pendingRouterFixture(t *testing.T) (*Broker, Policy, Pending) {
	t.Helper()
	policy := hostPolicy()
	policy.Pools[hostReserveGuestPool] = policy.Pools["qa"]
	delete(policy.Pools, "qa")
	b := diagnosticBroker(t, &policy)
	pending := Pending{Request: Request{ID: hostReserveRouterID, Pool: hostReserveGuestPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 2}}, QueuedAt: b.now()}
	requireGrant(t, b, &policy, "other-builder", buildPool)
	if err := b.update(&policy, false, func(s *Snapshot) error {
		s.Schema = ownedWaitLedgerSchema
		s.Pending[pending.ID] = pending
		s.Pending["other-pending"] = Pending{Request: Request{ID: "other-pending", Pool: hostReserveGuestPool}, QueuedAt: b.now(), Owner: waitOwner(), Revision: 7, Suspended: true}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return b, policy, pending
}

func TestPendingHostReservePreservesAccountingAndNoWriteReplay(t *testing.T) {
	b, policy, pending := pendingRouterFixture(t)
	before, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	proofs := 0
	changed, err := b.ReclassifyPendingHostReserve(&policy, &pending, func() error { proofs++; return nil })
	if err != nil || !changed || proofs != 1 {
		t.Fatal("classification", changed, err, proofs)
	}
	delete(before.Pending, pending.ID)
	after, err := b.Status(&policy)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("unrelated accounting changed", err)
	}
	data, err := os.ReadFile(b.Path)
	if err != nil {
		t.Fatal(err)
	}
	changed, err = b.ReclassifyPendingHostReserve(&policy, &pending, func() error { t.Fatal("absent replay proof"); return nil })
	if err != nil || changed {
		t.Fatal("replay", changed, err)
	}
	again, err := os.ReadFile(b.Path)
	if err != nil || !bytes.Equal(data, again) {
		t.Fatal("absent replay wrote", err)
	}
}

func TestPendingHostReserveRejectsChangedIncarnationsWithoutWrites(t *testing.T) {
	for _, mutation := range []string{"queue-time", "request-resources", "request-pool", "owned-demand", "revised-demand", "suspended-demand", "promoted-demand", "reserve-proof", "policy-drift"} {
		t.Run(mutation, func(t *testing.T) {
			b, policy, expected := pendingRouterFixture(t)
			switch mutation {
			case "queue-time":
				expected.QueuedAt = expected.QueuedAt.Add(time.Nanosecond)
			case "request-resources":
				expected.Resources.MemoryMiB++
			case "request-pool":
				expected.Pool = buildPool
			case "owned-demand":
				if err := b.update(&policy, false, func(s *Snapshot) error {
					p := s.Pending[expected.ID]
					p.Owner = s.Pending["other-pending"].Owner
					p.Revision = 1
					s.Pending[p.ID] = p
					return nil
				}); err != nil {
					t.Fatal(err)
				}
			case "revised-demand":
				expected.Revision = 1
			case "suspended-demand":
				expected.Suspended = true
			case "promoted-demand":
				if d, err := b.Admit(&policy, expected.Request); err != nil || !d.Admitted {
					t.Fatal("promotion fixture", err)
				}
			case "policy-drift":
				policy.Budget.MemoryMiB++
			}
			before, err := os.ReadFile(b.Path)
			if err != nil {
				t.Fatal(err)
			}
			changed, err := b.ReclassifyPendingHostReserve(&policy, &expected, func() error {
				if mutation == "reserve-proof" {
					return errors.New("reserve proof changed")
				}
				return nil
			})
			if err == nil || changed {
				t.Fatal("unsafe classification", mutation)
			}
			after, err := os.ReadFile(b.Path)
			if err != nil || !bytes.Equal(before, after) {
				t.Fatal("rejection wrote accounting", err)
			}
		})
	}
}

func TestPendingHostReserveSerializesPromotion(t *testing.T) {
	for range 12 {
		b, policy, expected := pendingRouterFixture(t)
		var workers sync.WaitGroup
		workers.Go(func() {
			changed, err := b.ReclassifyPendingHostReserve(&policy, &expected, func() error { return nil })
			if err == nil && !changed {
				t.Error("present demand classification reported absent")
			}
		})
		workers.Go(func() {
			if d, err := b.Admit(&policy, expected.Request); err != nil || !d.Admitted {
				t.Errorf("admit: %v", err)
			}
		})
		workers.Wait()
		s, err := b.Status(&policy)
		if err != nil || s.Grants[expected.ID].ID != expected.ID {
			t.Fatal("concurrent grant was removed", err)
		}
	}
}
