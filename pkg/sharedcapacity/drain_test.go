package sharedcapacity

import (
	"fmt"
	"testing"
	"time"
)

func TestDrainUsesRequestedSizeInsteadOfMaximumEnvelope(t *testing.T) {
	policy := hostPolicy()
	pool := policy.Pools["qa"]
	pool.Cost = Resources{MemoryMiB: 17408, VCPUs: 4}
	policy.Pools["qa"] = pool
	b := newBroker(t, &policy)
	for index := range 8 {
		requireGrant(t, b, &policy, fmt.Sprintf("build-%d", index), buildPool)
	}
	request := Request{ID: "waiting-small", Pool: "qa", Resources: Resources{MemoryMiB: 5120, VCPUs: 2}}
	decision, err := b.Admit(&policy, request)
	if err != nil || !decision.Admitted {
		t.Fatal("small request unnecessarily waited for the maximum envelope", err)
	}
	request = Request{ID: "waiting-large", Pool: "qa", Resources: pool.Cost}
	decision, err = b.Admit(&policy, request)
	if err != nil || decision.Admitted {
		t.Fatal("large request did not wait for capacity", err)
	}
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	observations := map[string]Observation{}
	for id, grant := range snapshot.Grants {
		observations[id] = Observation{Fence: grant.Fence, ObservedAt: now}
	}
	plan, err := PlanDrain(&snapshot, observations, now)
	if err != nil || len(plan.Grants) != 1 {
		t.Fatal("drain did not reclaim the exact larger demand", plan, err)
	}
	for _, grant := range plan.Grants {
		releaseGrant(t, b, &policy, &grant)
	}
	decision, err = b.Admit(&policy, request)
	if err != nil || !decision.Admitted || decision.Grant.Cost != request.Resources {
		t.Fatal("released capacity did not honor waiting resources", err)
	}
}

func pendingQA(t *testing.T) (*Broker, Policy, map[string]Observation, time.Time) {
	t.Helper()
	policy := hostPolicy()
	b := newBroker(t, &policy)
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	b.Now = func() time.Time { return now }
	observations := map[string]Observation{}
	for i := range 8 {
		grant := requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
		observations[grant.ID] = Observation{Fence: grant.Fence, Busy: true, ObservedAt: now}
	}
	requireGrant(t, b, &policy, "qa-0", "qa")
	if decision, err := b.Admit(&policy, Request{ID: pendingQAID, Pool: "qa"}); err != nil || decision.Admitted {
		t.Fatalf("queue QA: %+v, %v", decision, err)
	}
	return b, policy, observations, now
}

func TestDrainPreservesBusyAndUnknownWorkloads(t *testing.T) {
	b, policy, observations, now := pendingQA(t)
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := PlanDrain(&snapshot, observations, now)
	if err != nil || len(plan.Grants) != 0 || plan.WaitingID != pendingQAID || plan.Ready {
		t.Fatalf("busy workload drain: %+v, %v", plan, err)
	}
	idle := observations["build-7"]
	idle.Busy = false
	observations["build-7"] = idle
	plan, err = PlanDrain(&snapshot, observations, now)
	if err != nil || len(plan.Grants) != 1 || plan.Grants[0].ID != "build-7" || plan.Ready {
		t.Fatalf("idle workload drain: %+v, %v", plan, err)
	}
	// Advice does not mutate the ledger or prematurely free the allocation.
	after, err := b.Status(&policy)
	if err != nil || len(after.Grants) != len(snapshot.Grants) {
		t.Fatalf("drain plan freed allocations: %+v, %v", after, err)
	}
	for _, observation := range []Observation{
		{Fence: idle.Fence, ObservedAt: now.Add(-31 * time.Second)},
		{Fence: idle.Fence, ObservedAt: now.Add(time.Second)},
		{Fence: "earlier-workload", ObservedAt: now},
		{Fence: idle.Fence},
	} {
		observations["build-7"] = observation
		plan, err = PlanDrain(&snapshot, observations, now)
		if err != nil || len(plan.Grants) != 0 {
			t.Fatalf("unknown workload drain: %+v, %v", plan, err)
		}
	}
}

func TestDrainPreservesMinimumBuilderGuarantee(t *testing.T) {
	b, policy, observations, now := pendingQA(t)
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	for id, observation := range observations {
		observation.Busy = false
		observations[id] = observation
	}
	for i := 1; i < 8; i++ {
		plan, planErr := PlanDrain(&snapshot, observations, now)
		if planErr != nil {
			t.Fatal(planErr)
		}
		for _, grant := range plan.Grants {
			releaseGrant(t, b, &policy, &grant)
		}
		requireGrant(t, b, &policy, fmt.Sprintf("qa-%d", i), "qa")
		snapshot, err = b.Status(&policy)
		if err != nil {
			t.Fatal(err)
		}
		if i < 7 {
			if _, admissionErr := b.Admit(&policy, Request{ID: fmt.Sprintf("qa-%d", i+1), Pool: "qa"}); admissionErr != nil {
				t.Fatal(admissionErr)
			}
			snapshot, err = b.Status(&policy)
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	builds := 0
	for _, grant := range snapshot.Grants {
		if grant.Pool == buildPool {
			builds++
		}
	}
	if builds != 4 {
		t.Fatalf("minimum builder guarantee changed: %d", builds)
	}
}

func TestHostedRunnerAndGuestBudgetsAreSeparate(t *testing.T) {
	policy := hostPolicy()
	delete(policy.Pools, "qa")
	policy.Pools["qa-runner"] = Pool{Cost: Resources{MemoryMiB: 2048, VCPUs: 1}, Minimum: 4, Maximum: 8, Priority: 2}
	policy.Pools["qa-guest"] = Pool{Cost: Resources{MemoryMiB: 5120, VCPUs: 2}, Maximum: 8, Priority: 3}
	b := newBroker(t, &policy)
	for i := range 4 {
		requireGrant(t, b, &policy, fmt.Sprintf("listener-%d", i), "qa-runner")
	}
	for i := range 8 {
		requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
	}
	// One E2E guest can boot while eight builders and four listeners exist.
	// Additional E2E demand waits; no runner's 12 GiB allocation is reduced.
	requireGrant(t, b, &policy, "guest-0", "qa-guest")
	if decision, err := b.Admit(&policy, Request{ID: "guest-1", Pool: "qa-guest"}); err != nil || decision.Admitted {
		t.Fatalf("guest oversubscribed host: %+v, %v", decision, err)
	}
}

func TestAgedBuildSizeDemandReclaimsIdleExtraAtFullSlotLimit(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	now := time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)
	b.Now = func() time.Time { return now }
	for i := range 8 {
		requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
	}
	request := Request{ID: "small-class", Pool: buildPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 1}}
	decision, err := b.Admit(&policy, request)
	if err != nil || decision.Admitted {
		t.Fatal("aggregate slot ceiling not enforced", err)
	}
	now = now.Add(time.Duration(policy.AgingSeconds+1) * time.Second)
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	observations := map[string]Observation{}
	for id, grant := range snapshot.Grants {
		observations[id] = Observation{Fence: grant.Fence, Busy: true, ObservedAt: now}
	}
	plan, err := PlanDrain(&snapshot, observations, now)
	if err != nil || len(plan.Grants) != 0 {
		t.Fatal("busy builders selected", err)
	}
	idle := snapshot.Grants["build-7"]
	observations[idle.ID] = Observation{Fence: idle.Fence, ObservedAt: now}
	plan, err = PlanDrain(&snapshot, observations, now)
	if err != nil || len(plan.Grants) != 1 || plan.Grants[0].ID != idle.ID {
		t.Fatal("aged class at full slot limit could not reclaim idle extra", plan, err)
	}
	releaseGrant(t, b, &policy, &idle)
	decision, err = b.Admit(&policy, request)
	if err != nil || !decision.Admitted || decision.Grant.Cost != request.Resources {
		t.Fatal("exact smaller demand not admitted", err)
	}
}
