package sharedcapacity

import (
	"fmt"
	"testing"
	"time"
)

func TestResidentMemoryAdmitsFullGuestsBeyondLegacyAllowance(t *testing.T) {
	policy := Policy{Budget: Resources{MemoryMiB: 112000, VCPUs: 28}, AgingSeconds: 600, CPUAdmission: CPUAdmissionSoft, SharedMemoryHeadroom: true,
		BuildMemoryOvercommit: &BuildMemoryOvercommit{AdditionalMiB: 65536, MinimumAvailableMiB: 8192},
		Pools: map[string]Pool{
			"build":     {Cost: Resources{MemoryMiB: 12288, VCPUs: 4}, Maximum: 25},
			"qa-runner": {Cost: Resources{MemoryMiB: 2048, VCPUs: 1}, Maximum: 4},
			"qa-guest":  {Cost: Resources{MemoryMiB: 17408, VCPUs: 4}, Maximum: 4},
		}}
	broker := diagnosticBroker(t, &policy)
	broker.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: 74936, ObservedAt: broker.now()}, nil
	}
	for pool, count := range map[string]int{"build": 13, "qa-runner": 4} {
		for index := range count {
			decision, err := broker.Admit(&policy, Request{ID: fmt.Sprintf("%s-%d", pool, index), Pool: pool})
			if err != nil || !decision.Admitted {
				t.Fatalf("existing running owner did not fit: %+v %v", decision, err)
			}
			start, err := broker.ReserveStart(&policy, decision.Grant.ID, decision.Grant.Fence)
			if err != nil {
				t.Fatal(err)
			}
			if err := broker.ConfirmStarted(&policy, decision.Grant.ID, start, func(Grant) error { return nil }); err != nil {
				t.Fatal(err)
			}
		}
	}
	for index := range 3 {
		decision, err := broker.Admit(&policy, Request{ID: fmt.Sprintf("guest-%d", index), Pool: "qa-guest"})
		if err != nil || !decision.Admitted {
			t.Fatalf("fresh actual RAM was blocked by nominal commitments: %+v %v", decision, err)
		}
	}
	decision, err := broker.Admit(&policy, Request{ID: "guest-concurrent", Pool: "qa-guest"})
	if err != nil || decision.Admitted || decision.Reason != memoryPressure {
		t.Fatalf("delayed starts overspent physical RAM: %+v %v", decision, err)
	}
	snapshot, err := broker.Status(&policy)
	if err != nil || allocatedMemory(&snapshot) <= policy.Budget.MemoryMiB+policy.BuildMemoryOvercommit.AdditionalMiB || pendingStartMemory(&snapshot, "") != 3*17408 {
		t.Fatalf("full durable charges or reservations lost: %+v %v", snapshot, err)
	}
	report, err := broker.Diagnose(&policy)
	if err != nil || report.MemoryAdmission != "resident" || report.BuildMemory == nil || report.BuildMemory.AvailableMiB == nil || *report.BuildMemory.AvailableMiB != 74936 {
		t.Fatal("diagnostics did not identify resident admission and measured RAM", report, err)
	}
}

func TestResidentMemoryUpgradePreservesV6StartIdentity(t *testing.T) {
	policy := sharedHeadroomPolicy(t)
	broker := newBroker(t, &policy)
	broker.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: 74936, ObservedAt: broker.now()}, nil
	}
	decision, err := broker.Admit(&policy, Request{ID: "legacy-start", Pool: "qa"})
	if err != nil || !decision.Admitted {
		t.Fatal(decision, err)
	}
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	before.Schema = legacySharedMemoryLedgerSchema
	start := before.Starts[decision.Grant.ID]
	queuedAt := time.Now().UTC().Add(-time.Hour)
	before.Pending["old-wait"] = Pending{Request: Request{ID: "old-wait", Pool: "qa"}, QueuedAt: queuedAt}
	if err := validateSnapshot(&before); err != nil {
		t.Fatal(err)
	}
	if err := migrateSharedStarts(&before); err != nil {
		t.Fatal(err)
	}
	if before.Schema != sharedMemoryLedgerSchema || before.Starts[decision.Grant.ID] != start || !before.Pending["old-wait"].QueuedAt.Equal(queuedAt) {
		t.Fatal("resident upgrade reset start identity or pending age")
	}
}

func TestResidentMemoryProtectsUnfilledFloor(t *testing.T) {
	policy := sharedHeadroomPolicy(t)
	pool := policy.Pools["qa-runner"]
	pool.Minimum = 1
	policy.Pools["qa-runner"] = pool
	broker := newBroker(t, &policy)
	broker.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: policy.BuildMemoryOvercommit.MinimumAvailableMiB + pool.Cost.MemoryMiB + policy.Pools["qa"].Cost.MemoryMiB - 1, ObservedAt: broker.now()}, nil
	}
	decision, err := broker.Admit(&policy, Request{ID: "guest", Pool: "qa"})
	if err != nil || decision.Admitted || decision.Reason != memoryPressure {
		t.Fatal("guest consumed another class's missing floor reserve", decision, err)
	}
	decision, err = broker.Admit(&policy, Request{ID: "floor", Pool: "qa-runner"})
	if err != nil || !decision.Admitted {
		t.Fatal("the floor could not use its own reservation", decision, err)
	}
}

func TestResidentPendingDiagnosticsIgnoreLegacyCommitmentBalance(t *testing.T) {
	policy := sharedHeadroomPolicy(t)
	pending := Pending{Request: Request{ID: "guest", Pool: "qa"}}
	snapshot := Snapshot{Schema: sharedMemoryLedgerSchema, Policy: policy}
	report := Diagnostics{PolicyMatches: true, CommitmentRemaining: Resources{}, Remaining: Resources{}, Pools: []PoolDiagnostic{{Name: "qa", Granted: 0}}}
	reason, constraint := diagnosticReason(&snapshot, &pending, &report)
	if reason != memoryObservationRequired || constraint != memoryHeadroom {
		t.Fatalf("resident diagnostics used nominal balance: %s %s", reason, constraint)
	}
	report.Pools[0].Granted = policy.Pools["qa"].Maximum
	reason, constraint = diagnosticReason(&snapshot, &pending, &report)
	if reason != diagnosticBudget || constraint != "pool_maximum" {
		t.Fatalf("resident diagnostics lost pool ceiling: %s %s", reason, constraint)
	}
	report.Pools[0].Granted = 0
	snapshot.Schema = legacySharedMemoryLedgerSchema
	reason, constraint = diagnosticReason(&snapshot, &pending, &report)
	if reason != diagnosticBudget || constraint != "host_budget" {
		t.Fatalf("legacy commitment diagnostic changed: %s %s", reason, constraint)
	}
}
