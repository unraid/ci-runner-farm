package sharedcapacity

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

const (
	standardFloorOne = "standard-1"
	standardFloorTwo = "standard-2"
)

func selectedBuildPolicy() Policy {
	return Policy{Budget: Resources{MemoryMiB: 47000, VCPUs: 24}, AgingSeconds: 600, Pools: map[string]Pool{
		buildPool: {Cost: Resources{MemoryMiB: 12288, VCPUs: 4}, MaxCost: Resources{MemoryMiB: 16384, VCPUs: 4}, Minimum: 2, Maximum: 12, Priority: 1, MinimumRequestIDs: []string{standardFloorOne, standardFloorTwo}},
	}}
}

func admitSized(t *testing.T, b *Broker, p *Policy, id string, memory uint64) Decision {
	t.Helper()
	d, err := b.Admit(p, Request{ID: id, Pool: buildPool, Resources: Resources{MemoryMiB: memory, VCPUs: 4}})
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func TestSelectedMinimumReservesStandardHardwareAcrossSizeClasses(t *testing.T) {
	p := selectedBuildPolicy()
	b := newBroker(t, &p)
	if !admitSized(t, b, &p, "large-1", 16384).Admitted || !admitSized(t, b, &p, "small-1", 4096).Admitted {
		t.Fatal("spare capacity was not usable")
	}
	if admitSized(t, b, &p, "large-2", 16384).Admitted {
		t.Fatal("size classes consumed the actual standard floor")
	}
	// Missing floor takes precedence over older blocked elastic demand.
	first := requireGrant(t, b, &p, standardFloorOne, buildPool)
	requireGrant(t, b, &p, standardFloorTwo, buildPool)
	restarted := &Broker{Path: b.Path}
	if got := requireGrant(t, restarted, &p, standardFloorOne, buildPool); got != first {
		t.Fatal("restart changed a guaranteed grant")
	}
	snapshot, err := b.Status(&p)
	if err != nil || len(snapshot.Grants) != 4 {
		t.Fatal("expected two standard, one large and one small", err)
	}
}

func TestSelectedMinimumReservesAggregateSlots(t *testing.T) {
	p := selectedBuildPolicy()
	pool := p.Pools[buildPool]
	pool.Maximum = 3
	p.Pools[buildPool] = pool
	b := newBroker(t, &p)
	if !admitSized(t, b, &p, "tiny-1", 1).Admitted {
		t.Fatal("spare slot unavailable")
	}
	if admitSized(t, b, &p, "tiny-2", 1).Admitted {
		t.Fatal("tiny allocations consumed guaranteed slots")
	}
	requireGrant(t, b, &p, standardFloorOne, buildPool)
	requireGrant(t, b, &p, standardFloorTwo, buildPool)
}

func TestSelectedMinimumValidationAndLegacyJSON(t *testing.T) {
	for name, ids := range map[string][]string{"short": {standardFloorOne}, "duplicate": {standardFloorOne, standardFloorOne}, "empty selector": {"", standardFloorTwo}, "long": {strings.Repeat("a", 201), standardFloorTwo}} {
		t.Run(name, func(t *testing.T) {
			p := selectedBuildPolicy()
			pool := p.Pools[buildPool]
			pool.MinimumRequestIDs = ids
			p.Pools[buildPool] = pool
			if p.Validate() == nil {
				t.Fatal("invalid selector accepted")
			}
		})
	}
	p := selectedBuildPolicy()
	b := newBroker(t, &p)
	if _, err := b.Admit(&p, Request{ID: standardFloorOne, Pool: buildPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 4}}); err == nil {
		t.Fatal("selected request changed its reserved hardware")
	}
	p.Pools["qa"] = Pool{Cost: Resources{MemoryMiB: 1024, VCPUs: 1}, Maximum: 2}
	if _, err := RequestCost(&p, Request{ID: standardFloorOne, Pool: "qa"}); err == nil {
		t.Fatal("selected request used another pool")
	}
	other := p.Pools["qa"]
	other.Minimum = 1
	other.MinimumRequestIDs = []string{standardFloorOne}
	p.Pools["qa"] = other
	if p.Validate() == nil {
		t.Fatal("conflicting minimum selectors accepted across pools")
	}
	legacy := hostPolicy()
	data, err := json.Marshal(legacy)
	if err != nil || strings.Contains(string(data), "minimumRequestIDs") {
		t.Fatal("legacy policy representation changed", err)
	}
}

func TestSelectedMinimumReconciliationPreservesOwnersAndPendingAge(t *testing.T) {
	legacy := selectedBuildPolicy()
	pool := legacy.Pools[buildPool]
	pool.MinimumRequestIDs = nil
	legacy.Pools[buildPool] = pool
	b := newBroker(t, &legacy)
	for i := range 2 {
		if !admitSized(t, b, &legacy, fmt.Sprintf("large-%d", i), 16384).Admitted {
			t.Fatal("legacy reproduction failed")
		}
	}
	for i := range 2 {
		if !admitSized(t, b, &legacy, fmt.Sprintf("small-%d", i), 4096).Admitted {
			t.Fatal("legacy reproduction failed")
		}
	}
	if admitSized(t, b, &legacy, standardFloorOne, 12288).Admitted {
		t.Fatal("legacy reproduction unexpectedly has standard capacity")
	}
	before, err := b.Status(&legacy)
	if err != nil {
		t.Fatal(err)
	}
	revised := selectedBuildPolicy()
	if err = b.CheckPolicyChange(&legacy, &revised); err != nil {
		t.Fatal(err)
	}
	if err = b.ReconcilePolicy(&legacy, &revised); err != nil {
		t.Fatal(err)
	}
	if err = b.ReconcilePolicy(&legacy, &revised); err != nil {
		t.Fatal("exact destination retry failed", err)
	}
	after, err := b.Status(&revised)
	if err != nil || !reflect.DeepEqual(before.Grants, after.Grants) || !reflect.DeepEqual(before.Pending, after.Pending) {
		t.Fatal("migration changed owners, fences, hardware or queue age", err)
	}
	now := time.Now().UTC()
	observations := map[string]Observation{}
	for id, grant := range after.Grants {
		observations[id] = Observation{Fence: grant.Fence, ObservedAt: now}
	}
	plan, err := PlanDrain(&after, observations, now)
	if err != nil || len(plan.Grants) == 0 || plan.WaitingID != standardFloorOne {
		t.Fatal("missing floor did not reclaim idle same-pool extras immediately", plan, err)
	}
	for _, grant := range plan.Grants {
		releaseGrant(t, b, &revised, &grant)
	}
	if !admitSized(t, b, &revised, standardFloorOne, 12288).Admitted {
		t.Fatal("stable explicit floor request was not admitted after recovery")
	}
}

func TestSelectedFloorDrainNeverRemovesGuaranteedOwners(t *testing.T) {
	p := selectedBuildPolicy()
	p.Budget.MemoryMiB = 40960
	p.Pools["qa"] = Pool{Cost: Resources{MemoryMiB: 16384, VCPUs: 1}, Maximum: 2, Priority: 3}
	b := newBroker(t, &p)
	requireGrant(t, b, &p, standardFloorOne, buildPool)
	requireGrant(t, b, &p, standardFloorTwo, buildPool)
	if !admitSized(t, b, &p, "large-extra", 16384).Admitted {
		t.Fatal("extra rejected")
	}
	if d, err := b.Admit(&p, Request{ID: pendingQAID, Pool: "qa"}); err != nil || d.Admitted {
		t.Fatal("QA should wait", err)
	}
	snapshot, err := b.Status(&p)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	observations := map[string]Observation{}
	for id, grant := range snapshot.Grants {
		observations[id] = Observation{Fence: grant.Fence, ObservedAt: now}
	}
	plan, err := PlanDrain(&snapshot, observations, now)
	if err != nil || len(plan.Grants) != 1 || plan.Grants[0].ID != "large-extra" {
		t.Fatal("selected floor was not protected", plan, err)
	}
	for _, bad := range []Observation{{Fence: observations["large-extra"].Fence, ObservedAt: now, Busy: true}, {Fence: "wrong", ObservedAt: now}, {Fence: observations["large-extra"].Fence, ObservedAt: now.Add(-time.Minute)}} {
		observations["large-extra"] = bad
		plan, err = PlanDrain(&snapshot, observations, now)
		if err != nil || len(plan.Grants) != 0 {
			t.Fatal("busy or unknown owner was selected", plan, err)
		}
	}
}
