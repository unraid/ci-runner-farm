package sharedcapacity

import (
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"reflect"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

const loanFirstBuilder = "loan-builder-0"

func loanFloorPolicy() Policy {
	p := overcommitPolicy()
	pool := p.Pools[buildPool]
	pool.Maximum = 24
	pool.MinimumRequestIDs = []string{loanFirstBuilder, "loan-builder-1", "loan-builder-2", "loan-builder-3"}
	p.Pools[buildPool] = pool
	p.Pools["qa-runner"] = Pool{Cost: Resources{MemoryMiB: 2048, VCPUs: 1}, Minimum: 4, Maximum: 4, Priority: 2}
	return p
}

func TestBorrowedBuildersCannotConsumePhysicalQAFloors(t *testing.T) {
	policy := loanFloorPolicy()
	b := newBroker(t, &policy)
	healthyMemory(b)
	builds := map[string]Grant{}
	for i := range 10 {
		id := fmt.Sprintf("loan-builder-%d", i)
		builds[id] = requireGrant(t, b, &policy, id, buildPool)
	}
	for i := range 4 {
		requireGrant(t, b, &policy, fmt.Sprintf("listener-%d", i), "qa-runner")
	}
	snapshot, err := b.Status(&policy)
	if err != nil || allocatedMemory(&snapshot) != 131072 || physicalMemory(&snapshot) != 112000 || borrowedMemory(&snapshot) != 19072 {
		t.Fatal("QA floors were not backed by physical reserves", snapshot, err)
	}
	for i := range 4 {
		if builds[fmt.Sprintf("loan-builder-%d", i)].BorrowedMemoryMiB != 0 {
			t.Fatal("standard floor borrowed memory")
		}
	}
	old := snapshot.Grants["listener-2"]
	releaseGrant(t, b, &policy, &old)
	listener := requireGrant(t, b, &policy, old.ID, old.Pool)
	if listener.BorrowedMemoryMiB != 0 || listener.Cost != old.Cost || listener.Fence == old.Fence {
		t.Fatal("listener replacement changed hardware or reused its fence")
	}
	after, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	for id, original := range builds {
		if after.Grants[id] != original {
			t.Fatal("restoring QA changed a busy builder", id)
		}
	}
	report := diagnoseSnapshot(&after, after.PolicyDigest, b.now())
	if report.AllocatedMemoryMiB != 131072 || report.PhysicalMemoryMiB != 112000 || report.BorrowedMemoryMiB != 19072 || report.Remaining.MemoryMiB != 0 {
		t.Fatal("diagnostics hid the split accounting", report)
	}
}

func TestDisjointBackfillCannotExtendThePhysicalHeadWait(t *testing.T) {
	policy := overcommitPolicy()
	pool := policy.Pools[buildPool]
	pool.Maximum = 24
	policy.Pools[buildPool] = pool
	b := newBroker(t, &policy)
	now := time.Date(2026, 10, 13, 3, 0, 0, 0, time.UTC)
	b.Now = func() time.Time { return now }
	healthyMemory(b)
	builds := make([]Grant, 8)
	for i := range builds {
		builds[i] = requireGrant(t, b, &policy, fmt.Sprintf("physical-%d", i), buildPool)
	}
	requireGrant(t, b, &policy, "qa-active", "qa")
	head := Request{ID: "qa-waiting", Pool: "qa"}
	decision, err := b.Admit(&policy, head)
	if err != nil || decision.Admitted || decision.Reason != diagnosticBudget {
		t.Fatal("fixture did not reproduce blocked physical head", decision, err)
	}
	queuedAt := decision.Pending.QueuedAt
	for i := range 20 {
		now = now.Add(time.Minute)
		grant := requireGrant(t, b, &policy, fmt.Sprintf("backfill-%d", i), buildPool)
		snapshot, statusErr := b.Status(&policy)
		if statusErr != nil || grant.BorrowedMemoryMiB != grant.Cost.MemoryMiB || physicalMemory(&snapshot) != 105472 ||
			queueHead(&snapshot, now) != head.ID || !snapshot.Pending[head.ID].QueuedAt.Equal(queuedAt) {
			t.Fatal("backfill captured physical headroom or reset fairness", grant, snapshot, statusErr)
		}
		releaseGrant(t, b, &policy, &grant)
	}
	backfill := requireGrant(t, b, &policy, "backfill-still-busy", buildPool)
	releaseGrant(t, b, &policy, &builds[7])
	decision, err = b.Admit(&policy, Request{ID: "late-builder", Pool: buildPool})
	if err != nil || decision.Admitted || decision.Reason != reasonPriority {
		t.Fatal("backfill bypassed the now-admissible head", decision, err)
	}
	qa := requireGrant(t, b, &policy, head.ID, head.Pool)
	snapshot, err := b.Status(&policy)
	if err != nil || qa.BorrowedMemoryMiB != 0 || qa.Cost.MemoryMiB != 7168 || snapshot.Grants[backfill.ID] != backfill {
		t.Fatal("older QA could not start with busy borrowed builders", qa, snapshot, err)
	}
}

func TestBackfillKeepsMemoryAndCPUAdmissionGuards(t *testing.T) {
	for _, mode := range []string{"healthy", "low", "expired-observation", "missing", "hard-cpu"} {
		t.Run(mode, func(t *testing.T) {
			policy := overcommitPolicy()
			if mode == "hard-cpu" {
				policy.CPUAdmission = ""
			}
			b := newBroker(t, &policy)
			healthyMemory(b)
			for i := range 8 {
				requireGrant(t, b, &policy, fmt.Sprintf("physical-%d", i), buildPool)
			}
			requireGrant(t, b, &policy, "qa-active", "qa")
			if _, err := b.Admit(&policy, Request{ID: "qa-waiting", Pool: "qa"}); err != nil {
				t.Fatal(err)
			}
			b.ObserveMemory = func() (MemoryObservation, error) {
				observation := MemoryObservation{AvailableMiB: 65536, ObservedAt: b.now()}
				switch mode {
				case "low":
					observation.AvailableMiB = 16384 + 12288 - 1
				case "expired-observation":
					observation.ObservedAt = b.now().Add(-6 * time.Second)
				case "missing":
					return MemoryObservation{}, errors.New("unavailable")
				}
				return observation, nil
			}
			decision, err := b.Admit(&policy, Request{ID: "backfill", Pool: buildPool})
			if err != nil || decision.Admitted != (mode == "healthy") {
				t.Fatal("backfill bypassed a measured-memory or hard CPU guard", decision, err)
			}
		})
	}
}

func TestLegacyLoanMigrationPreservesOwnersAndCommitsOnce(t *testing.T) {
	policy := loanFloorPolicy()
	b := newBroker(t, &policy)
	healthyMemory(b)
	for i := range 10 {
		requireGrant(t, b, &policy, fmt.Sprintf("loan-builder-%d", i), buildPool)
	}
	legacy, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	legacy.Schema = legacyBuildMemoryLedgerSchema
	for id, grant := range legacy.Grants {
		grant.BorrowedMemoryMiB = 0
		legacy.Grants[id] = grant
	}
	legacy.Pending["qa-pending"] = Pending{Request: Request{ID: "qa-pending", Pool: "qa"}, QueuedAt: b.now().Add(-time.Hour), Owner: waitOwner(), Revision: 3}
	legacy.Pending["parked-qa"] = Pending{Request: Request{ID: "parked-qa", Pool: "qa"}, QueuedAt: b.now().Add(-2 * time.Hour), Owner: waitOwner(), Revision: 5, Suspended: true}
	if validationErr := validateSnapshot(&legacy); validationErr != nil {
		t.Fatal("invalid legacy fixture", validationErr)
	}
	writeLoanFixture(t, b, &legacy)
	before := maps.Clone(legacy.Grants)
	upgraded, err := b.Status(&policy)
	if err != nil || upgraded.Schema != buildMemoryLedgerSchema || borrowedMemory(&upgraded) != 19072 || !reflect.DeepEqual(upgraded.Pending, legacy.Pending) {
		t.Fatal("native migration lost floor reserve or waiting ownership", upgraded, err)
	}
	for id, grant := range upgraded.Grants {
		grant.BorrowedMemoryMiB = 0
		if grant != before[id] {
			t.Fatal("migration changed an immutable workload identity", id)
		}
	}
	restarted := &Broker{Path: b.Path}
	again, err := restarted.Status(&policy)
	if err != nil || !reflect.DeepEqual(again, upgraded) {
		t.Fatal("migration repeated or lost accounting on restart", again, err)
	}
	if err := validateSnapshot(&Snapshot{Schema: legacyBuildMemoryLedgerSchema, Policy: upgraded.Policy, PolicyDigest: upgraded.PolicyDigest, Grants: upgraded.Grants, Pending: upgraded.Pending}); err == nil {
		t.Fatal("older schema accepted borrowed fields")
	}
}

func TestLoanValidationRejectsNonBuildFloorAndExcessBorrowing(t *testing.T) {
	policy := loanFloorPolicy()
	b := newBroker(t, &policy)
	healthyMemory(b)
	for i := range 10 {
		requireGrant(t, b, &policy, fmt.Sprintf("loan-builder-%d", i), buildPool)
	}
	requireGrant(t, b, &policy, "listener", "qa-runner")
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{loanFirstBuilder, "listener", "loan-builder-9"} {
		invalid := snapshot
		invalid.Grants = maps.Clone(snapshot.Grants)
		grant := invalid.Grants[id]
		grant.BorrowedMemoryMiB = 1
		if id == "loan-builder-9" {
			grant.BorrowedMemoryMiB = grant.Cost.MemoryMiB + 1
		}
		invalid.Grants[id] = grant
		if validateSnapshot(&invalid) == nil {
			t.Fatal("accepted invalid borrowed charge", id)
		}
	}
	revised := policy
	revised.BuildMemoryOvercommit = nil
	if policyErr := b.ReconcilePolicy(&policy, &revised); policyErr == nil {
		t.Fatal("removed backing allowance from immutable busy loans")
	}
	after, err := b.Status(&policy)
	if err != nil || !reflect.DeepEqual(after, snapshot) {
		t.Fatal("rejected policy changed existing allocations", after, err)
	}
}

func writeLoanFixture(t *testing.T, b *Broker, snapshot *Snapshot) {
	t.Helper()
	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	db, err := bolt.Open(b.Path, 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.Update(func(tx *bolt.Tx) error { return tx.Bucket([]byte("admission")).Put([]byte("snapshot"), data) }); err != nil {
		t.Fatal(err)
	}
}

func TestLoanedExtraYieldsOnlyWhenIdleToMissingPhysicalFloor(t *testing.T) {
	policy := loanFloorPolicy()
	pool := policy.Pools[buildPool]
	pool.Maximum = 10
	policy.Pools[buildPool] = pool
	b := newBroker(t, &policy)
	healthyMemory(b)
	for i := range 10 {
		requireGrant(t, b, &policy, fmt.Sprintf("loan-builder-%d", i), buildPool)
	}
	legacy, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	// Legacy policies could fill the pool while an identity-bound floor was
	// missing. Migration preserves those owners until native idle withdrawal.
	legacy.Schema = legacyBuildMemoryLedgerSchema
	for id, grant := range legacy.Grants {
		grant.BorrowedMemoryMiB = 0
		legacy.Grants[id] = grant
	}
	extra := legacy.Grants[loanFirstBuilder]
	delete(legacy.Grants, extra.ID)
	extra.ID = "legacy-extra"
	legacy.Grants[extra.ID] = extra
	writeLoanFixture(t, b, &legacy)
	decision, err := b.Admit(&policy, Request{ID: loanFirstBuilder, Pool: buildPool})
	if err != nil || decision.Admitted {
		t.Fatal("full legacy pool unexpectedly restored the missing slot", decision, err)
	}
	snapshot, err := b.Status(&policy)
	if err != nil || minimumCounts(&snapshot)[buildPool] != 3 {
		t.Fatal("migration treated a loaned extra as the physical floor", snapshot, err)
	}
	now := b.now()
	observations := map[string]Observation{}
	var idle Grant
	for id, grant := range snapshot.Grants {
		observations[id] = Observation{Fence: grant.Fence, Busy: true, ObservedAt: now}
		if grant.BorrowedMemoryMiB == grant.Cost.MemoryMiB {
			idle = grant
		}
	}
	if idle.ID == "" {
		t.Fatal("fixture has no entirely borrowed extra")
	}
	for _, observation := range []Observation{
		{Fence: idle.Fence, Busy: true, ObservedAt: now},
		{Fence: idle.Fence, ObservedAt: now.Add(-31 * time.Second)},
		{Fence: idle.Fence, ObservedAt: now.Add(time.Second)},
		{Fence: "different-owner", ObservedAt: now},
		{},
	} {
		observations[idle.ID] = observation
		plan, planErr := PlanDrain(&snapshot, observations, now)
		if planErr != nil || len(plan.Grants) != 0 {
			t.Fatal("busy or unknown loaned extra selected", plan, planErr)
		}
	}
	observations[idle.ID] = Observation{Fence: idle.Fence, ObservedAt: now}
	plan, err := PlanDrain(&snapshot, observations, now)
	if err != nil || len(plan.Grants) != 1 || plan.Grants[0] != idle {
		t.Fatal("idle loaned extra blocked physical floor recovery", plan, err)
	}
	releaseGrant(t, b, &policy, &idle)
	floor := requireGrant(t, b, &policy, loanFirstBuilder, buildPool)
	if floor.BorrowedMemoryMiB != 0 || floor.Cost != pool.Cost {
		t.Fatal("floor restoration borrowed memory or changed hardware", floor)
	}
}

func TestUndersizedGrantDoesNotReplacePhysicalFloor(t *testing.T) {
	policy := overcommitPolicy()
	b := newBroker(t, &policy)
	healthyMemory(b)
	request := Request{ID: "undersized-class", Pool: buildPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 1}}
	decision, err := b.Admit(&policy, request)
	if err != nil || !decision.Admitted {
		t.Fatal(err, decision)
	}
	snapshot, err := b.Status(&policy)
	if err != nil || minimumCounts(&snapshot)[buildPool] != 0 || ProtectsMinimum(&snapshot, request) ||
		missingFloorMemory(&snapshot) != 4*12288 {
		t.Fatal("small-class grant consumed the default-size physical guarantee", snapshot, err)
	}
}

func TestLiveReserveAdjustmentPreservesLoansAndFutureMeasuredAdmission(t *testing.T) {
	policy := loanFloorPolicy()
	b := newBroker(t, &policy)
	healthyMemory(b)
	for i := range 10 {
		requireGrant(t, b, &policy, fmt.Sprintf("loan-builder-%d", i), buildPool)
	}
	before, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	revised := policy
	revised.BuildMemoryOvercommit = &BuildMemoryOvercommit{AdditionalMiB: 65536, MinimumAvailableMiB: 8192}
	if !IsBuildCapacityIncrease(&policy, &revised) {
		t.Fatal("reviewed build-only guard adjustment still requires QA quiet")
	}
	if err = b.ReconcilePolicy(&policy, &revised); err != nil {
		t.Fatal(err)
	}
	after, err := b.Status(&revised)
	if err != nil || !reflect.DeepEqual(after.Grants, before.Grants) || !reflect.DeepEqual(after.Pending, before.Pending) {
		t.Fatal("reserve adjustment changed existing owners", after, err)
	}
	available := uint64(8192 + 12288 - 1)
	b.ObserveMemory = func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: available, ObservedAt: b.now()}, nil
	}
	request := Request{ID: "future-extra", Pool: buildPool}
	decision, err := b.Admit(&revised, request)
	if err != nil || decision.Admitted || decision.Reason != memoryPressure {
		t.Fatal("lower reserve bypassed per-builder expansion headroom", decision, err)
	}
	available++
	decision, err = b.Admit(&revised, request)
	if err != nil || !decision.Admitted || decision.Grant.Cost != revised.Pools[buildPool].Cost {
		t.Fatal("new measured guard did not bound future admission", decision, err)
	}
}

func TestRejectedLoanMigrationLeavesDurableSnapshotUnchanged(t *testing.T) {
	policy := overcommitPolicy()
	pool := policy.Pools["qa"]
	pool.Cost.MemoryMiB = 64000
	policy.Pools["qa"] = pool
	b := newBroker(t, &policy)
	legacy, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	legacy.Schema = legacyBuildMemoryLedgerSchema
	legacy.Grants["physical-qa"] = Grant{
		Request: Request{ID: "physical-qa", Pool: "qa"}, Cost: pool.Cost,
		Fence: "0123456789abcdef0123456789abcdef", GrantedAt: b.now(),
	}
	// A legacy valid nonbuild allocation can still leave too little space for
	// physical build guarantees. No build exists that can safely back the loan.
	legacy.Grants["too-large-qa"] = Grant{
		Request: Request{ID: "too-large-qa", Pool: "qa", Resources: Resources{MemoryMiB: 1024, VCPUs: 1}},
		Cost:    Resources{MemoryMiB: 1024, VCPUs: 1}, Fence: "fedcba9876543210fedcba9876543210", GrantedAt: b.now(),
	}
	if validationErr := validateSnapshot(&legacy); validationErr != nil {
		t.Fatal("migration fixture was not legacy-valid", validationErr)
	}
	writeLoanFixture(t, b, &legacy)
	if _, statusErr := b.Status(&policy); statusErr == nil {
		t.Fatal("migration accepted unbacked physical floors")
	}
	db, err := bolt.Open(b.Path, 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if viewErr := db.View(func(tx *bolt.Tx) error {
		var retained Snapshot
		if decodeErr := json.Unmarshal(tx.Bucket([]byte("admission")).Get([]byte("snapshot")), &retained); decodeErr != nil {
			return decodeErr
		}
		if !reflect.DeepEqual(retained, legacy) {
			t.Fatal("failed migration committed partial accounting", retained)
		}
		return nil
	}); viewErr != nil {
		t.Fatal(viewErr)
	}
}
