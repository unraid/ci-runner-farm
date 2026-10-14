package sharedcapacity

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

func sharedHeadroomPolicy(t *testing.T) Policy {
	t.Helper()
	p := loanFloorPolicy()
	// These tests isolate resident start reservations. Guaranteed-floor funding
	// has separate coverage with the actual host floor policy.
	for name, pool := range p.Pools {
		pool.Minimum, pool.MinimumRequestIDs = 0, nil
		p.Pools[name] = pool
	}
	qa := p.Pools["qa"]
	qa.Cost = Resources{MemoryMiB: 5120, VCPUs: 2}
	p.Pools["qa"] = qa
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	document["sharedMemoryHeadroom"] = true
	raw, err = json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestSharedHeadroomRejectsUnprovedMemoryForQA(t *testing.T) {
	for _, mode := range []string{"low", "missing", "stale", "future"} {
		t.Run(mode, func(t *testing.T) {
			p := sharedHeadroomPolicy(t)
			b := newBroker(t, &p)
			b.ObserveMemory = func() (MemoryObservation, error) {
				sample := MemoryObservation{AvailableMiB: 74936, ObservedAt: b.now()}
				switch mode {
				case "low":
					sample.AvailableMiB = p.BuildMemoryOvercommit.MinimumAvailableMiB + 5119
				case "missing":
					return MemoryObservation{}, errors.New("no observation")
				case "stale":
					sample.ObservedAt = sample.ObservedAt.Add(-6 * time.Second)
				case "future":
					sample.ObservedAt = sample.ObservedAt.Add(time.Second)
				}
				return sample, nil
			}
			d, err := b.Admit(&p, Request{ID: "qa-headroom", Pool: "qa"})
			if err != nil || d.Admitted || d.Reason != memoryPressure {
				t.Fatalf("QA reached start without proven headroom: %+v %v", d, err)
			}
		})
	}
}

func TestSharedHeadroomParallelDelayedStartsSpendSampleOnce(t *testing.T) {
	p := sharedHeadroomPolicy(t)
	b := newBroker(t, &p)
	b.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: p.BuildMemoryOvercommit.MinimumAvailableMiB + 5120, ObservedAt: b.now()}, nil
	}
	var wait sync.WaitGroup
	decisions := make(chan Decision, 2)
	errs := make(chan error, 2)
	for i := range 2 {
		wait.Go(func() {
			d, err := b.Admit(&p, Request{ID: fmt.Sprintf("qa-start-%d", i), Pool: "qa"})
			decisions <- d
			errs <- err
		})
	}
	wait.Wait()
	close(decisions)
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	granted := 0
	for d := range decisions {
		if d.Admitted {
			granted++
		}
	}
	if granted != 1 {
		t.Fatalf("one physical sample funded %d delayed starts", granted)
	}
	// Restarting the allocator or retrying queued demand does not expire the charge.
	b.Now = func() time.Time { return time.Now().UTC().Add(time.Hour) }
	for i := range 2 {
		if _, err := b.Admit(&p, Request{ID: fmt.Sprintf("qa-start-%d", i), Pool: "qa"}); err != nil {
			t.Fatal(err)
		}
	}
	snapshot, err := b.Status(&p)
	if err != nil || len(snapshot.Grants) != 1 {
		t.Fatal("retry or elapsed time spent reserved memory twice", err, len(snapshot.Grants))
	}
}

func TestSharedHeadroomMigratesExistingOwnersAndAdmitsFittingQA(t *testing.T) {
	old := loanFloorPolicy()
	build := old.Pools[buildPool]
	build.Maximum = 26
	build.MaxCost = Resources{MemoryMiB: 16384, VCPUs: 4}
	old.Pools[buildPool] = build
	qa := old.Pools["qa"]
	qa.Cost = Resources{MemoryMiB: 5120, VCPUs: 2}
	old.Pools["qa"] = qa
	b := newBroker(t, &old)
	b.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: 74936, ObservedAt: b.now()}, nil
	}
	for i := range 4 {
		requireGrant(t, b, &old, fmt.Sprintf("listener-%d", i), "qa-runner")
	}
	for i := range 13 {
		requireGrant(t, b, &old, fmt.Sprintf("loan-builder-%d", i), buildPool)
	}
	d, err := b.Admit(&old, Request{ID: "small-builder", Pool: buildPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 2}})
	if err != nil || !d.Admitted {
		t.Fatal(d, err)
	}
	now := time.Now().UTC()
	b.Now = func() time.Time { return now.Add(-time.Hour) }
	if d, err = b.Admit(&old, Request{ID: "older-head", Pool: buildPool}); err != nil || d.Admitted {
		t.Fatal("unfundable old head fixture", d, err)
	}
	b.Now = func() time.Time { return now }
	before, err := b.Status(&old)
	if err != nil || allocatedMemory(&before) != 172032 {
		t.Fatal("wrong live commitment fixture", err, allocatedMemory(&before))
	}
	revised := old
	revised.SharedMemoryHeadroom = true
	if err := b.ReconcilePolicy(&old, &revised); err != nil {
		t.Fatal(err)
	}
	migrated, err := b.Status(&revised)
	if err != nil {
		t.Fatal(err)
	}
	if len(migrated.Starts) != len(before.Grants) || pendingStartMemory(&migrated, "") != 172032 {
		t.Fatal("migration guessed existing owners had started")
	}
	for id, grant := range before.Grants {
		if migrated.Grants[id] != grant {
			t.Fatal("migration changed an existing grant", id)
		}
		if err := b.ConfirmStarted(&revised, id, migrated.Starts[id], func(g Grant) error {
			if g != grant {
				t.Fatal("wrong owner proof")
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	// The older builder is blocked by actual resident memory, not by its legacy
	// allowance. A smaller QA request may use the same measured headroom.
	b.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: revised.BuildMemoryOvercommit.MinimumAvailableMiB + 5120, ObservedAt: b.now()}, nil
	}
	d, err = b.Admit(&revised, Request{ID: "qa-headroom-request", Pool: "qa"})
	if err != nil || !d.Admitted {
		t.Fatalf("fitting QA denied behind unfundable build despite fresh headroom: %+v %v", d, err)
	}
	after, err := b.Status(&revised)
	if err != nil {
		t.Fatal(err)
	}
	for id, grant := range before.Grants {
		if after.Grants[id] != grant {
			t.Fatal("QA admission changed existing grant", id)
		}
	}
	if after.Pending["older-head"] != before.Pending["older-head"] {
		t.Fatal("backfill changed old pending age or identity")
	}
	if borrowedMemory(&after) > revised.BuildMemoryOvercommit.AdditionalMiB {
		t.Fatal("shared borrowing exceeded its original bound")
	}
	if err := b.ReconcilePolicy(&revised, &old); err == nil {
		t.Fatal("v6 ownership silently downgraded")
	}
}

func TestSharedHeadroomStartProofsAndRestartFences(t *testing.T) {
	p := sharedHeadroomPolicy(t)
	b := newBroker(t, &p)
	available := uint64(74936)
	b.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: available, ObservedAt: b.now()}, nil
	}
	d, err := b.Admit(&p, Request{ID: "qa-start", Pool: "qa"})
	if err != nil || !d.Admitted || d.Start == nil {
		t.Fatal(d, err)
	}
	available = p.BuildMemoryOvercommit.MinimumAvailableMiB + 5119
	if _, err := b.ReserveStart(&p, d.Grant.ID, d.Grant.Fence); !errors.Is(err, ErrMemoryHeadroom) {
		t.Fatal("delayed dispatch used its obsolete memory sample", err)
	}
	available = 74936
	start, err := b.ReserveStart(&p, d.Grant.ID, d.Grant.Fence)
	if err != nil || start != *d.Start {
		t.Fatal("unproved retry replaced reservation", start, err)
	}
	if err := b.ConfirmStarted(&p, d.Grant.ID, start, func(Grant) error { return errors.New("unknown running owner") }); err == nil {
		t.Fatal("unknown proof dropped reservation")
	}
	if err := b.ConfirmStarted(&p, d.Grant.ID, start, func(Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
	snapshot, err := b.Status(&p)
	if err != nil || pendingStartMemory(&snapshot, "") != 0 {
		t.Fatal("attested committed start retained shadow", err)
	}
	restart, err := b.ReserveStart(&p, d.Grant.ID, d.Grant.Fence)
	if err != nil || restart.Nonce == start.Nonce {
		t.Fatal("restart reused previous start nonce", err)
	}
	if err := b.ConfirmStarted(&p, d.Grant.ID, start, func(Grant) error { return nil }); !errors.Is(err, ErrFenceMismatch) {
		t.Fatal("old acknowledgement cleared new restart charge", err)
	}
	if err := b.Release(&p, d.Grant.ID, d.Grant.Fence, func(Grant) error { return errors.New("still running") }); err == nil {
		t.Fatal("unknown stopped proof cleared grant")
	}
	snapshot, err = b.Status(&p)
	if err != nil || pendingStartMemory(&snapshot, "") != 5120 {
		t.Fatal("failed proof lost reservation", err)
	}
	if err := b.Release(&p, d.Grant.ID, d.Grant.Fence, func(Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
	snapshot, err = b.Status(&p)
	if err != nil || len(snapshot.Starts) != 0 || len(snapshot.Grants) != 0 {
		t.Fatal("exact stopped release retained phantom charge", err)
	}
}

func TestSharedHeadroomFittingQABackfillsMemoryBlockedBuild(t *testing.T) {
	for _, available := range []uint64{21504, 74936} {
		t.Run(fmt.Sprint(available), func(t *testing.T) {
			p := sharedHeadroomPolicy(t)
			b := newBroker(t, &p)
			now := time.Now().UTC()
			b.Now = func() time.Time { return now.Add(-time.Hour) }
			b.ObserveMemory = func() (MemoryObservation, error) {
				return MemoryObservation{AvailableMiB: 21504, ObservedAt: b.now()}, nil
			}
			d, err := b.Admit(&p, Request{ID: "old-large-build", Pool: buildPool})
			if err != nil || d.Admitted {
				t.Fatal("old request fixture", d, err)
			}
			before, _ := b.Status(&p)
			b.Now = func() time.Time { return now }
			observations := 0
			b.ObserveMemory = func() (MemoryObservation, error) {
				observations++
				return MemoryObservation{AvailableMiB: available, ObservedAt: b.now()}, nil
			}
			d, err = b.Admit(&p, Request{ID: "qa-fitting", Pool: "qa"})
			if err != nil || d.Admitted != (available == 21504) {
				t.Fatal("head readiness ignored", d, err)
			}
			if observations != 1 {
				t.Fatal("head and follower used different memory samples", observations)
			}
			after, err := b.Status(&p)
			if err != nil || after.Pending["old-large-build"] != before.Pending["old-large-build"] {
				t.Fatal("backfill lost queue age", err)
			}
		})
	}
}

func TestSharedHeadroomDiagnosticsUseReservedMemoryWithoutCapabilities(t *testing.T) {
	p := sharedHeadroomPolicy(t)
	b := diagnosticBroker(t, &p)
	b.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: p.BuildMemoryOvercommit.MinimumAvailableMiB + 5120, ObservedAt: b.now()}, nil
	}
	first, err := b.Admit(&p, Request{ID: "first", Pool: "qa"})
	if err != nil || !first.Admitted {
		t.Fatal(first, err)
	}
	if _, err := b.Admit(&p, Request{ID: "second", Pool: "qa"}); err != nil {
		t.Fatal(err)
	}
	report, err := b.Diagnose(&p)
	if err != nil || report.BuildMemory == nil || report.BuildMemory.PendingStartMiB != 5120 || len(report.Pending) != 1 || report.Pending[0].Reason != memoryPressure {
		t.Fatal("diagnostic differs from actual start guard", report, err)
	}
	raw, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), first.Grant.Fence) || strings.Contains(string(raw), first.Start.Nonce) {
		t.Fatal("diagnostic exposed release or start capabilities")
	}
}

func TestSharedHeadroomCorruptStartInventoryCannotBeRecreated(t *testing.T) {
	for _, missing := range []string{"map", "entry"} {
		t.Run(missing, func(t *testing.T) {
			p := sharedHeadroomPolicy(t)
			b := newBroker(t, &p)
			b.ObserveMemory = func() (MemoryObservation, error) {
				return MemoryObservation{AvailableMiB: 74936, ObservedAt: b.now()}, nil
			}
			grant := requireGrant(t, b, &p, "existing", "qa")
			snapshot, err := b.Status(&p)
			if err != nil {
				t.Fatal(err)
			}
			if missing == "map" {
				snapshot.Starts = nil
			} else {
				delete(snapshot.Starts, grant.ID)
			}
			writeLoanFixture(t, b, &snapshot)
			if _, err := b.ReserveStart(&p, grant.ID, grant.Fence); err == nil {
				t.Fatal("damaged start accounting was silently recreated")
			}
		})
	}
}

func TestStandaloneAdmissionDoesNotRequireQAOrSharedHeadroom(t *testing.T) {
	p := hostPolicy()
	delete(p.Pools, "qa")
	b := newBroker(t, &p)
	b.ObserveMemory = func() (MemoryObservation, error) {
		t.Fatal("standalone policy unexpectedly requested shared headroom")
		return MemoryObservation{}, errors.New("no shared observer")
	}
	grant := requireGrant(t, b, &p, "standalone-build", buildPool)
	if grant.Cost != p.Pools[buildPool].Cost {
		t.Fatal("standalone allocation changed", grant)
	}
	snapshot, err := b.Status(&p)
	if err != nil || snapshot.Schema == sharedMemoryLedgerSchema || len(snapshot.Starts) != 0 {
		t.Fatal("standalone mode activated shared accounting", snapshot, err)
	}
}
