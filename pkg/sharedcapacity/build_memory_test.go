package sharedcapacity

import (
	"errors"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"
)

const memoryHealthy = "healthy"

func TestConcurrentOvercommitRetainsTheTenBuilderLimit(t *testing.T) {
	policy := overcommitPolicy()
	b := newBroker(t, &policy)
	healthyMemory(b)
	var workers sync.WaitGroup
	for i := range 30 {
		workers.Go(func() {
			if _, err := b.Admit(&policy, Request{ID: fmt.Sprintf("build-%02d", i), Pool: buildPool}); err != nil {
				t.Error(err)
			}
		})
	}
	workers.Wait()
	// Normal owner retries settle any priority waits created by concurrency.
	for i := range 30 {
		if _, err := b.Admit(&policy, Request{ID: fmt.Sprintf("build-%02d", i), Pool: buildPool}); err != nil {
			t.Fatal(err)
		}
	}
	snapshot, err := b.Status(&policy)
	if err != nil || len(snapshot.Grants) != 10 || len(snapshot.Pending) != 20 || allocatedMemory(&snapshot) != 122880 {
		t.Fatal("concurrent requests exceeded or lost the bounded commitments", err, len(snapshot.Grants), len(snapshot.Pending))
	}
}

func TestOvercommitRequiresBoundedAllowanceAndReserve(t *testing.T) {
	for _, extra := range []BuildMemoryOvercommit{{AdditionalMiB: 0, MinimumAvailableMiB: 16384}, {AdditionalMiB: 112001, MinimumAvailableMiB: 16384}, {AdditionalMiB: 65536, MinimumAvailableMiB: 0}, {AdditionalMiB: 65536, MinimumAvailableMiB: 112000}} {
		policy := overcommitPolicy()
		policy.BuildMemoryOvercommit = &extra
		if policy.Validate() == nil {
			t.Fatal("accepted unbounded or unguarded overcommit", extra)
		}
	}
}

func overcommitPolicy() Policy {
	p := hostPolicy()
	p.CPUAdmission = CPUAdmissionSoft
	build := p.Pools[buildPool]
	build.Maximum = 10
	p.Pools[buildPool] = build
	p.BuildMemoryOvercommit = &BuildMemoryOvercommit{AdditionalMiB: 65536, MinimumAvailableMiB: 16384}
	return p
}

func healthyMemory(b *Broker) {
	b.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: 65536, ObservedAt: b.now()}, nil
	}
}

func TestTenBuildersKeepExactChargesAndNonBuildHardAdmission(t *testing.T) {
	policy := overcommitPolicy()
	b := newBroker(t, &policy)
	healthyMemory(b)
	for i := range 10 {
		grant := requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
		if grant.Cost.MemoryMiB != 12288 {
			t.Fatal("overcommit changed the workload hard limit")
		}
	}
	decision, err := b.Admit(&policy, Request{ID: "extra-qa", Pool: "qa"})
	if err != nil || decision.Admitted || decision.Reason != diagnosticBudget {
		t.Fatal("build allowance relaxed non-build admission", decision, err)
	}
	snapshot, err := b.Status(&policy)
	if err != nil || snapshot.Schema != buildMemoryLedgerSchema || len(snapshot.Grants) != 10 {
		t.Fatal("invalid committed allocations", err)
	}
	report := diagnoseSnapshot(&snapshot, snapshot.PolicyDigest, b.now())
	if report.AllocatedMemoryMiB != 122880 || !report.MemoryOvercommitted || report.Remaining.MemoryMiB != 0 || report.CommitmentRemaining.MemoryMiB != 54656 {
		t.Fatal("diagnostics concealed overcommit", report)
	}
	previous := snapshot.Grants["build-0"]
	b.ObserveMemory = func() (MemoryObservation, error) { return MemoryObservation{}, errors.New("unavailable") }
	if replay := requireGrant(t, b, &policy, previous.ID, buildPool); replay != previous {
		t.Fatal("pressure changed an existing grant")
	}
}

func TestOvercommitPressurePreservesPendingAndFences(t *testing.T) {
	for _, mode := range []string{memorySampleLow, memorySampleMissing, "old-sample", "future", memoryHealthy} {
		t.Run(mode, func(t *testing.T) {
			policy := overcommitPolicy()
			b := newBroker(t, &policy)
			healthyMemory(b)
			for i := range 9 {
				requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
			}
			before, err := b.Status(&policy)
			if err != nil {
				t.Fatal(err)
			}
			b.ObserveMemory = func() (MemoryObservation, error) {
				observation := MemoryObservation{AvailableMiB: 16384 + 12288, ObservedAt: b.now()}
				switch mode {
				case memorySampleLow:
					observation.AvailableMiB--
				case memorySampleMissing:
					return MemoryObservation{}, errors.New("unavailable")
				case "old-sample":
					observation.ObservedAt = b.now().Add(-6 * time.Second)
				case "future":
					observation.ObservedAt = b.now().Add(time.Second)
				}
				return observation, nil
			}
			decision, err := b.Admit(&policy, Request{ID: "build-9", Pool: buildPool})
			if err != nil || decision.Admitted != (mode == memoryHealthy) || (!decision.Admitted && decision.Reason != "memory_pressure") {
				t.Fatal("incorrect pressure gate", decision, err)
			}
			after, err := b.Status(&policy)
			if err != nil {
				t.Fatal(err)
			}
			for id, grant := range before.Grants {
				if after.Grants[id] != grant {
					t.Fatal("pressure rewrote a running allocation")
				}
			}
			if mode != memoryHealthy && len(after.Pending) != 1 {
				t.Fatal("pressure discarded demand")
			}
		})
	}
}

func TestOvercommitBoundAndHardDefault(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		policy := overcommitPolicy()
		build := policy.Pools[buildPool]
		build.Maximum = 64
		policy.Pools[buildPool] = build
		if !enabled {
			policy.BuildMemoryOvercommit = nil
		}
		b := newBroker(t, &policy)
		healthyMemory(b)
		for i := range 20 {
			if _, err := b.Admit(&policy, Request{ID: fmt.Sprintf("build-%02d", i), Pool: buildPool}); err != nil {
				t.Fatal(err)
			}
		}
		snapshot, err := b.Status(&policy)
		expected := 9
		if enabled {
			expected = 14
		}
		if err != nil || len(snapshot.Grants) != expected || len(snapshot.Pending) != 20-expected {
			t.Fatal("commitment limit was not enforced", enabled, len(snapshot.Grants), err)
		}
	}
}

func TestLiveBuildAllowancePreservesPolicyAndRejectsMixedChange(t *testing.T) {
	old := overcommitPolicy()
	old.BuildMemoryOvercommit = nil
	build := old.Pools[buildPool]
	build.Maximum = 24
	build.MinimumRequestIDs = []string{"b1", "b2", "b3", "b4"}
	old.Pools[buildPool] = build
	next := overcommitPolicy()
	build.Maximum = 10
	next.Pools[buildPool] = build
	if !IsBuildCapacityIncrease(&old, &next) {
		t.Fatal("additive build allowance needs no QA quiet gate")
	}
	b := newBroker(t, &old)
	grant := requireGrant(t, b, &old, "b1", buildPool)
	if err := b.ReconcilePolicy(&old, &next); err != nil {
		t.Fatal(err)
	}
	snapshot, err := b.Status(&next)
	if err != nil || !reflect.DeepEqual(snapshot.Grants[grant.ID], grant) || snapshot.Schema != buildMemoryLedgerSchema {
		t.Fatal("policy reconciliation changed existing grant", err)
	}
	next.Budget.MemoryMiB++
	if IsBuildCapacityIncrease(&old, &next) {
		t.Fatal("mixed budget change bypassed quiet gate")
	}
}

func TestLiveOvercommitOptInCannotInvalidateExistingBuilders(t *testing.T) {
	previous := overcommitPolicy()
	previous.BuildMemoryOvercommit = nil
	pool := previous.Pools[buildPool]
	pool.Maximum = 24
	pool.MinimumRequestIDs = []string{"b1", "b2", "b3", "b4"}
	previous.Pools[buildPool] = pool
	b := newBroker(t, &previous)
	for i := range 11 {
		r := Request{ID: fmt.Sprintf("b%d", i+1), Pool: buildPool}
		if i >= 4 {
			r.Resources = Resources{MemoryMiB: 4096, VCPUs: 1}
		}
		d, err := b.Admit(&previous, r)
		if err != nil || !d.Admitted {
			t.Fatal(d, err)
		}
	}
	next := overcommitPolicy()
	pool.Maximum = 10
	next.Pools[buildPool] = pool
	if !IsBuildCapacityIncrease(&previous, &next) {
		t.Fatal("first bounded opt-in requires allocation preview")
	}
	if err := b.CheckPolicyChange(&previous, &next); err == nil {
		t.Fatal("lower build cap invalidated active owners")
	}
	snapshot, err := b.Status(&previous)
	if err != nil || len(snapshot.Grants) != 11 {
		t.Fatal("rejected preview changed active allocations", err)
	}
}

func TestNativeMemoryParserRejectsMissingDuplicateAndWrongUnits(t *testing.T) {
	for _, text := range []string{"", "MemAvailable: 100 MB", "MemAvailable: -1 kB", "MemAvailable: 1024 kB\nMemAvailable: 1024 kB"} {
		if _, err := parseAvailableMemory(text); err == nil {
			t.Fatal("accepted invalid native observation", text)
		}
	}
	if available, err := parseAvailableMemory("MemTotal: 123456 kB\nMemAvailable: 16777216 kB\n"); err != nil || available != 16384 {
		t.Fatal(available, err)
	}
}
