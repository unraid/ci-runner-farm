package sharedcapacity

import (
	"errors"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"
)

const (
	memorySampleMissing = "missing"
	memorySampleFuture  = "future-memory-sample"
	memorySampleLow     = "low"
	memorySampleExpired = "expired-memory-sample"
)

func TestMeasuredPressureGatesBurstsBelowPhysicalCommitment(t *testing.T) {
	for _, mode := range []string{memorySampleLow, "gap", memorySampleMissing, memorySampleExpired, memorySampleFuture, memoryHealthy} {
		t.Run(mode, func(t *testing.T) {
			policy := overcommitPolicy()
			b := newBroker(t, &policy)
			b.ObserveMemory = func() (MemoryObservation, error) {
				sample := MemoryObservation{AvailableMiB: 16384 + 12288, ObservedAt: b.now()}
				switch mode {
				case memorySampleLow:
					sample.AvailableMiB = 100
				case "gap":
					sample.AvailableMiB--
				case memorySampleMissing:
					return MemoryObservation{}, errors.New(memorySampleMissing)
				case memorySampleExpired:
					sample.ObservedAt = b.now().Add(-6 * time.Second)
				case memorySampleFuture:
					sample.ObservedAt = b.now().Add(time.Second)
				}
				return sample, nil
			}
			for i := range 4 {
				requireGrant(t, b, &policy, fmt.Sprintf("floor-%d", i), buildPool)
			}
			decision, err := b.Admit(&policy, Request{ID: "memory-burst", Pool: buildPool})
			if err != nil || decision.Admitted != (mode == memoryHealthy) {
				t.Fatal(decision, err)
			}
			snapshot, err := b.Status(&policy)
			if err != nil || allocatedMemory(&snapshot) > policy.Budget.MemoryMiB {
				t.Fatal("fixture not below physical commitment", err)
			}
		})
	}
}

func TestMemoryDrainUsesOnlyFreshIdleExtrasWithoutDemand(t *testing.T) {
	policy := overcommitPolicy()
	b := newBroker(t, &policy)
	healthyMemory(b)
	for i := range 5 {
		requireGrant(t, b, &policy, fmt.Sprintf("builder-%d", i), buildPool)
	}
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	now := b.now()
	observations := map[string]Observation{}
	for id, g := range snapshot.Grants {
		observations[id] = Observation{Fence: g.Fence, ObservedAt: now}
	}
	available := uint64(1)
	status := BuildMemoryDiagnostic{State: memoryStatePressure, AvailableMiB: &available, ObservedAt: now, MinimumAvailableMiB: 16384}
	plan, err := PlanMemoryDrain(&snapshot, observations, status, now)
	if err != nil || len(plan.Grants) != 1 || len(snapshot.Pending) != 0 {
		t.Fatal(plan, err)
	}
	for id, o := range observations {
		o.Busy = true
		observations[id] = o
	}
	plan, err = PlanMemoryDrain(&snapshot, observations, status, now)
	if err != nil || len(plan.Grants) != 0 {
		t.Fatal("busy removed", plan, err)
	}
	for id, o := range observations {
		o.Busy = false
		observations[id] = o
	}
	for _, mode := range []string{memorySampleMissing, memorySampleExpired, memorySampleFuture} {
		bad := status
		switch mode {
		case memorySampleMissing:
			bad.AvailableMiB = nil
		case memorySampleExpired:
			bad.ObservedAt = now.Add(-6 * time.Second)
		case memorySampleFuture:
			bad.ObservedAt = now.Add(time.Second)
		}
		plan, err = PlanMemoryDrain(&snapshot, observations, bad, now)
		if err != nil || len(plan.Grants) != 0 {
			t.Fatal(mode, plan, err)
		}
	}
}

func TestMemoryDiagnosticsReadOnceWithoutChangingLedger(t *testing.T) {
	policy := overcommitPolicy()
	b := diagnosticBroker(t, &policy)
	healthyMemory(b)
	for i := range 4 {
		requireGrant(t, b, &policy, fmt.Sprintf("floor-%d", i), buildPool)
	}
	b.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: 100, ObservedAt: b.now()}, nil
	}
	if decision, err := b.Admit(&policy, Request{ID: "memory-burst", Pool: buildPool}); err != nil || decision.Admitted {
		t.Fatal(decision, err)
	}
	before, err := os.ReadFile(b.Path)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	b.ObserveMemory = func() (MemoryObservation, error) {
		calls++
		return MemoryObservation{AvailableMiB: 100, ObservedAt: b.now()}, nil
	}
	report, err := b.Diagnose(&policy)
	if err != nil || calls != 1 || report.BuildMemory == nil || report.BuildMemory.State != memoryStatePressure || len(report.Pending) != 1 || report.Pending[0].Reason != memoryPressure {
		t.Fatal(report, calls, err)
	}
	after, err := os.ReadFile(b.Path)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("diagnostic changed ledger", err)
	}
	b.ObserveMemory = func() (MemoryObservation, error) { return MemoryObservation{}, errors.New(memorySampleMissing) }
	report, err = b.Diagnose(&policy)
	if err != nil || report.BuildMemory.State != "unavailable" || report.BuildMemory.AvailableMiB != nil || report.Pending[0].Reason != memoryObservationRequired {
		t.Fatal(report, err)
	}
}

func TestPressurePreservesIdentityBoundFloorAndGatesClasses(t *testing.T) {
	policy := overcommitPolicy()
	pool := policy.Pools[buildPool]
	pool.MinimumRequestIDs = []string{"floor-0", "floor-1", "floor-2", "floor-3"}
	policy.Pools[buildPool] = pool
	b := newBroker(t, &policy)
	b.ObserveMemory = func() (MemoryObservation, error) { return MemoryObservation{AvailableMiB: 1, ObservedAt: b.now()}, nil }
	// Specialized identities cannot borrow a missing standard floor's exemption.
	decision, err := b.Admit(&policy, Request{ID: "specialized", Pool: buildPool})
	if err != nil || decision.Admitted {
		t.Fatal(decision, err)
	}
	for _, id := range pool.MinimumRequestIDs {
		requireGrant(t, b, &policy, id, buildPool)
	}
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	observations := map[string]Observation{}
	for id, g := range snapshot.Grants {
		observations[id] = Observation{Fence: g.Fence, ObservedAt: b.now()}
	}
	plan, err := PlanMemoryDrain(&snapshot, observations, b.BuildMemoryStatus(&policy), b.now())
	if err != nil || len(plan.Grants) != 0 {
		t.Fatal("identity floor selected", plan, err)
	}
}
