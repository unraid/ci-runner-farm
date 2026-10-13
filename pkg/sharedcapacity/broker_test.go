package sharedcapacity

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"
)

const (
	pendingQAID = "qa-1"
)

func hostPolicy() Policy {
	return Policy{
		Budget: Resources{MemoryMiB: 112000, VCPUs: 28}, AgingSeconds: 60,
		Pools: map[string]Pool{
			buildPool: {Cost: Resources{MemoryMiB: 12288, VCPUs: 1}, Minimum: 4, Maximum: 8, Priority: 1},
			"qa":      {Cost: Resources{MemoryMiB: 7168, VCPUs: 3}, Maximum: 8, Priority: 3},
		},
	}
}

func newBroker(t *testing.T, policy *Policy) *Broker {
	t.Helper()
	b := &Broker{Path: filepath.Join(t.TempDir(), "admission.db")}
	if err := b.Initialize(policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	return b
}

func requireGrant(t *testing.T, b *Broker, policy *Policy, id, pool string) Grant {
	t.Helper()
	decision, err := b.Admit(policy, Request{ID: id, Pool: pool})
	if err != nil || !decision.Admitted || decision.Grant == nil {
		t.Fatalf("admit %s: %+v, %v", id, decision, err)
	}
	return *decision.Grant
}

func releaseGrant(t *testing.T, b *Broker, policy *Policy, grant *Grant) {
	t.Helper()
	if err := b.Release(policy, grant.ID, grant.Fence, func(Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestEightBuildersYieldToEightQAWithoutReducingMemory(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	grants := make([]Grant, 8)
	for i := range grants {
		grants[i] = requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
		if grants[i].Cost.MemoryMiB != 12288 {
			t.Fatal("builder memory changed")
		}
	}
	first := requireGrant(t, b, &policy, "qa-0", "qa")
	decision, err := b.Admit(&policy, Request{ID: pendingQAID, Pool: "qa"})
	if err != nil || decision.Admitted || decision.Reason != "budget" {
		t.Fatalf("QA should wait for idle builders: %+v, %v", decision, err)
	}
	// Busy builders retain their grants. Only owners proving stopped workloads
	// reclaim the four burst grants; no utilization estimate can free them.
	for _, grant := range grants[4:] {
		releaseGrant(t, b, &policy, &grant)
	}
	for i := 1; i < 8; i++ {
		requireGrant(t, b, &policy, fmt.Sprintf("qa-%d", i), "qa")
	}
	snapshot, err := b.Status(&policy)
	if err != nil || len(snapshot.Grants) != 12 || snapshot.Grants[first.ID].Fence != first.Fence {
		t.Fatalf("four builders plus eight QA: %+v, %v", snapshot, err)
	}
}

func TestConcurrentAdmissionNeverOversubscribes(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	var workers sync.WaitGroup
	for i := range 24 {
		workers.Go(func() {
			pool := buildPool
			if i%2 == 0 {
				pool = "qa"
			}
			if _, err := b.Admit(&policy, Request{ID: fmt.Sprintf("work-%d", i), Pool: pool}); err != nil {
				t.Errorf("admission: %v", err)
			}
		})
	}
	workers.Wait()
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if err := validateSnapshot(&snapshot); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Grants) == 0 || len(snapshot.Pending) == 0 {
		t.Fatal("expected both admitted and queued workloads")
	}
}

func TestRestartAndFailedStopRetainFencedAllocation(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	grant := requireGrant(t, b, &policy, "build-1", buildPool)
	restarted := &Broker{Path: b.Path}
	replayed := requireGrant(t, restarted, &policy, "build-1", buildPool)
	if replayed != grant {
		t.Fatal("restart replaced the allocation")
	}
	if err := restarted.Release(&policy, grant.ID, grant.Fence, func(Grant) error { return errors.New("still busy") }); err == nil {
		t.Fatal("failed stop freed allocation")
	}
	if err := restarted.Cancel(&policy, grant.Request); err == nil {
		t.Fatal("cancel freed allocation")
	}
	releaseGrant(t, restarted, &policy, &grant)
	replacement := requireGrant(t, restarted, &policy, "build-1", buildPool)
	if replacement.Fence == grant.Fence {
		t.Fatal("new allocation reused old fence")
	}
	if err := restarted.Release(&policy, grant.ID, grant.Fence, func(Grant) error { return nil }); !errors.Is(err, ErrFenceMismatch) {
		t.Fatalf("stale release: %v", err)
	}
}

func TestPriorityFencesNewBuildersAndAgesOldDemand(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	clock := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	b.Now = func() time.Time { return clock }
	grants := make([]Grant, 8)
	for i := range grants {
		grants[i] = requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
	}
	requireGrant(t, b, &policy, "qa-0", "qa")
	if d, err := b.Admit(&policy, Request{ID: pendingQAID, Pool: "qa"}); err != nil || d.Admitted {
		t.Fatalf("queue QA: %+v, %v", d, err)
	}
	releaseGrant(t, b, &policy, &grants[7])
	if d, err := b.Admit(&policy, Request{ID: "new-build", Pool: buildPool}); err != nil || d.Admitted || d.Reason != reasonPriority {
		t.Fatalf("build bypassed pending QA: %+v, %v", d, err)
	}
	requireGrant(t, b, &policy, pendingQAID, "qa")
	clock = clock.Add(5 * time.Minute)
	if d, err := b.Admit(&policy, Request{ID: "qa-new", Pool: "qa"}); err != nil || d.Admitted || d.Reason != reasonPriority {
		t.Fatalf("fresh QA bypassed aged build: %+v, %v", d, err)
	}
	releaseGrant(t, b, &policy, &grants[6])
	requireGrant(t, b, &policy, "new-build", buildPool)
}

func TestMissingOrChangedLedgerFailsClosed(t *testing.T) {
	policy := hostPolicy()
	b := &Broker{Path: filepath.Join(t.TempDir(), "missing.db")}
	if _, err := b.Admit(&policy, Request{ID: "build-1", Pool: buildPool}); err == nil {
		t.Fatal("missing ledger silently created fresh budget")
	}
	if err := b.Initialize(&policy, func() error { return errors.New("owned workload still running") }); err == nil {
		t.Fatal("initialization ignored running workloads")
	}
	if _, err := b.Admit(&policy, Request{ID: "build-1", Pool: buildPool}); err == nil {
		t.Fatal("failed initialization became usable")
	}
	if err := b.Initialize(&policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	requireGrant(t, b, &policy, "build-1", buildPool)
	policy.Budget.MemoryMiB++
	if _, err := b.Status(&policy); !errors.Is(err, ErrPolicyChanged) {
		t.Fatalf("silent policy replacement: %v", err)
	}
}

func TestPoolMaximumDoesNotBlockOtherPools(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	for i := range 8 {
		requireGrant(t, b, &policy, fmt.Sprintf("qa-%d", i), "qa")
	}
	if d, err := b.Admit(&policy, Request{ID: "qa-9", Pool: "qa"}); err != nil || d.Admitted {
		t.Fatalf("QA limit: %+v, %v", d, err)
	}
	for i := range 4 {
		requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
	}
}

func TestReviewedPolicyChangePreservesExistingGrants(t *testing.T) {
	previous := hostPolicy()
	b := newBroker(t, &previous)
	grant := requireGrant(t, b, &previous, "build-1", buildPool)
	revised := hostPolicy()
	revised.Budget.MemoryMiB = 60000
	if err := b.ReconcilePolicy(&previous, &revised); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Status(&previous); !errors.Is(err, ErrPolicyChanged) {
		t.Fatalf("stale owner changed policy: %v", err)
	}
	replayed := requireGrant(t, b, &revised, grant.ID, buildPool)
	if replayed != grant {
		t.Fatal("policy reconciliation replaced the live grant")
	}
	invalid := hostPolicy()
	pool := invalid.Pools[buildPool]
	pool.Cost.MemoryMiB = 16384
	invalid.Pools[buildPool] = pool
	if err := b.ReconcilePolicy(&revised, &invalid); err == nil {
		t.Fatal("policy reconciliation changed running workload's cost")
	}
	replayed = requireGrant(t, b, &revised, grant.ID, buildPool)
	if replayed != grant {
		t.Fatal("failed reconciliation changed the ledger")
	}
}

func TestVariableRequestsPersistExactCostsAndImmutableIntent(t *testing.T) {
	policy := hostPolicy()
	pool := policy.Pools["qa"]
	pool.Cost = Resources{MemoryMiB: 17408, VCPUs: 4}
	policy.Pools["qa"] = pool
	b := newBroker(t, &policy)
	requests := []Request{
		{ID: "small", Pool: "qa", Resources: Resources{MemoryMiB: 5120, VCPUs: 2}},
		{ID: "medium", Pool: "qa", Resources: Resources{MemoryMiB: 9216, VCPUs: 4}},
		{ID: "large", Pool: "qa", Resources: Resources{MemoryMiB: 17408, VCPUs: 4}},
	}
	for _, request := range requests {
		decision, err := b.Admit(&policy, request)
		if err != nil || !decision.Admitted || decision.Grant.Cost != request.Resources {
			t.Fatal("variable allocation mismatch", decision, err)
		}
		// A fresh process must recover the identical charge and release fence.
		restarted := &Broker{Path: b.Path}
		replayed, err := restarted.Admit(&policy, request)
		if err != nil || *replayed.Grant != *decision.Grant {
			t.Fatal("restart changed allocation", err)
		}
		changed := request
		changed.Resources.MemoryMiB--
		if _, resizeErr := b.Admit(&policy, changed); resizeErr == nil {
			t.Fatal("retry silently resized an active allocation")
		}
		releaseGrant(t, b, &policy, decision.Grant)
	}
	for _, resources := range []Resources{{MemoryMiB: 17409, VCPUs: 4}, {MemoryMiB: 5120, VCPUs: 5}, {MemoryMiB: 5120}, {VCPUs: 2}} {
		if _, err := b.Admit(&policy, Request{ID: "invalid", Pool: "qa", Resources: resources}); err == nil {
			t.Fatal("unbounded or partial resource request accepted", resources)
		}
	}
	snapshot, err := b.Status(&policy)
	if err != nil || len(snapshot.Grants) != 0 || len(snapshot.Pending) != 0 {
		t.Fatal("invalid request entered durable demand or release leaked resources", err)
	}
}

func TestVariableConcurrentRequestsRespectBothBudgets(t *testing.T) {
	policy := hostPolicy()
	pool := policy.Pools["qa"]
	pool.Cost = Resources{MemoryMiB: 17408, VCPUs: 4}
	policy.Pools["qa"] = pool
	b := newBroker(t, &policy)
	var workers sync.WaitGroup
	for index := range 24 {
		workers.Go(func() {
			cost := Resources{MemoryMiB: 5120, VCPUs: 2}
			if index%2 == 0 {
				cost = pool.Cost
			}
			if _, err := b.Admit(&policy, Request{ID: fmt.Sprintf("variable-%02d", index), Pool: "qa", Resources: cost}); err != nil {
				t.Error(err)
			}
		})
	}
	workers.Wait()
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if err := validateSnapshot(&snapshot); err != nil {
		t.Fatal("concurrent requests overallocated", err)
	}
	if len(snapshot.Grants) == 0 || len(snapshot.Pending) == 0 {
		t.Fatal("expected admitted and queued mixed-size work")
	}
}

func TestVariableQueuedRequestKeepsSizeAgeAndPolicyBound(t *testing.T) {
	policy := hostPolicy()
	pool := policy.Pools["qa"]
	pool.Cost = Resources{MemoryMiB: 17408, VCPUs: 4}
	policy.Pools["qa"] = pool
	b := newBroker(t, &policy)
	for index := range 8 {
		requireGrant(t, b, &policy, fmt.Sprintf("build-%d", index), buildPool)
	}
	request := Request{ID: "large", Pool: "qa", Resources: pool.Cost}
	if decision, err := b.Admit(&policy, request); err != nil || decision.Admitted {
		t.Fatal("large request should wait", err)
	}
	before, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	b = &Broker{Path: b.Path}
	changed := request
	changed.Resources.MemoryMiB = 5120
	if _, resizeErr := b.Admit(&policy, changed); resizeErr == nil {
		t.Fatal("queued retry resized its intent")
	}
	if _, replayErr := b.Admit(&policy, request); replayErr != nil {
		t.Fatal(replayErr)
	}
	after, err := b.Status(&policy)
	if err != nil || after.Pending[request.ID] != before.Pending[request.ID] {
		t.Fatal("restart or rejected resize changed queue age", err)
	}
	pool.Cost.MemoryMiB--
	revised := hostPolicy()
	revised.Pools["qa"] = pool
	if err := b.ReconcilePolicy(&policy, &revised); err == nil {
		t.Fatal("policy shrink invalidated pending hardware")
	}
}

func TestBuildRequestCeilingDoesNotChangeDefaultFloorOrLegacyPolicyDigest(t *testing.T) {
	policy := hostPolicy()
	before, err := policyDigest(&policy)
	if err != nil {
		t.Fatal(err)
	}
	pool := policy.Pools[buildPool]
	pool.MaxCost = Resources{MemoryMiB: 16384, VCPUs: 4}
	policy.Pools[buildPool] = pool
	if checkErr := policy.Validate(); checkErr != nil {
		t.Fatal(checkErr)
	}
	defaultCost, err := RequestCost(&policy, Request{Pool: buildPool})
	if err != nil || defaultCost != pool.Cost {
		t.Fatal("default allocation changed")
	}
	cost, err := RequestCost(&policy, Request{Pool: buildPool, Resources: pool.MaxCost})
	if err != nil || cost != pool.MaxCost {
		t.Fatal("explicit ceiling unavailable")
	}
	for _, bad := range []Resources{{MemoryMiB: 16385, VCPUs: 4}, {MemoryMiB: 4096}, {VCPUs: 1}} {
		if _, checkErr := RequestCost(&policy, Request{Pool: buildPool, Resources: bad}); checkErr == nil {
			t.Fatal("invalid explicit request accepted")
		}
	}
	pool.MaxCost = Resources{}
	policy.Pools[buildPool] = pool
	after, err := policyDigest(&policy)
	if err != nil || before != after {
		t.Fatal("zero ceiling changed legacy policy digest")
	}
	pool.MaxCost = Resources{MemoryMiB: 4096, VCPUs: 1}
	policy.Pools[buildPool] = pool
	if checkErr := policy.Validate(); checkErr == nil {
		t.Fatal("ceiling below default accepted")
	}
}

func TestConcurrentMixedSizesKeepHostBudgetAndExactCharges(t *testing.T) {
	policy := hostPolicy()
	pool := policy.Pools[buildPool]
	pool.MaxCost = Resources{MemoryMiB: 16384, VCPUs: 4}
	policy.Pools[buildPool] = pool
	b := newBroker(t, &policy)
	var workers sync.WaitGroup
	for i := range 24 {
		workers.Go(func() {
			request := Request{ID: fmt.Sprintf("mixed-%d", i), Pool: buildPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 1}}
			switch i % 3 {
			case 0:
				request.Resources = pool.MaxCost
			case 1:
				request.Pool = "qa"
				request.Resources = Resources{MemoryMiB: 5120, VCPUs: 2}
			}
			if _, admitErr := b.Admit(&policy, request); admitErr != nil {
				t.Errorf("mixed admission: %v", admitErr)
			}
		})
	}
	workers.Wait()
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	remaining := policy.Budget
	for _, grant := range snapshot.Grants {
		if grant.Cost != grant.Resources || !fits(remaining, grant.Cost) {
			t.Fatal("mixed requests undercharged or exceeded host budget")
		}
		remaining = subtract(remaining, grant.Cost)
	}
	if len(snapshot.Grants) == 0 || len(snapshot.Pending) == 0 {
		t.Fatal("pressure did not preserve both grants and pending demand")
	}
	restarted := Broker{Path: b.Path}
	after, err := restarted.Status(&policy)
	if err != nil || len(after.Grants) != len(snapshot.Grants) || len(after.Pending) != len(snapshot.Pending) {
		t.Fatal("mixed ownership not durable", err)
	}
}

const hostReserveRouterID = "qa-guest:router"

func TestHostReserveClassificationPreservesOtherAccountingAndReplays(t *testing.T) {
	policy := hostPolicy()
	pool := policy.Pools["qa"]
	policy.Pools[hostReserveGuestPool] = pool
	delete(policy.Pools, "qa")
	b := diagnosticBroker(t, &policy)
	targetRequest := Request{ID: hostReserveRouterID, Pool: hostReserveGuestPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 2}}
	target, err := b.Admit(&policy, targetRequest)
	if err != nil || target.Grant == nil {
		t.Fatal(err)
	}
	requireGrant(t, b, &policy, "other-builder", buildPool)
	requireGrant(t, b, &policy, "other-guest", hostReserveGuestPool)
	owner := &WaitOwner{PrincipalID: "owner", ReservationID: "reservation", CapacityID: "capacity", OperationID: "operation", RequestKey: "key", Generation: 2, Incarnation: "incarnation"}
	if updateErr := b.update(&policy, false, func(s *Snapshot) error {
		s.Schema = ownedWaitLedgerSchema
		s.Pending["classification-pending"] = Pending{Request: Request{ID: "classification-pending", Pool: hostReserveGuestPool}, QueuedAt: b.now(), Owner: owner, Suspended: true, Revision: 7}
		return nil
	}); updateErr != nil {
		t.Fatal(updateErr)
	}
	hash := sha256.Sum256([]byte(target.Grant.Fence))
	expected := GrantDiagnostic{Request: target.Grant.Request, Cost: target.Grant.Cost, FenceSHA256: hex.EncodeToString(hash[:]), GrantedAt: target.Grant.GrantedAt}
	// Unrelated activity after preview must survive, rather than restoring the
	// earlier snapshot during classification.
	requireGrant(t, b, &policy, "new-builder", buildPool)
	before, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	proofs := 0
	changed, err := b.ReclassifyHostReserve(&policy, &expected, func(g Grant) error {
		proofs++
		if g != *target.Grant {
			t.Fatal("raw incarnation changed")
		}
		return nil
	})
	if err != nil || !changed || proofs != 1 {
		t.Fatalf("classification: %v %v", changed, err)
	}
	delete(before.Grants, targetRequest.ID)
	after, err := b.Status(&policy)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("unrelated accounting changed", err)
	}
	replayBefore, err := os.ReadFile(b.Path)
	if err != nil {
		t.Fatal(err)
	}
	changed, err = b.ReclassifyHostReserve(&policy, &expected, func(Grant) error { t.Fatal("absent grant required stopped proof"); return nil })
	if err != nil || changed {
		t.Fatal("lost-response replay was not idempotent", err)
	}
	replayAfter, err := os.ReadFile(b.Path)
	if err != nil || !reflect.DeepEqual(replayBefore, replayAfter) {
		t.Fatal("absent replay wrote accounting", err)
	}
	// A later incarnation never matches the old preview.
	replacement, err := b.Admit(&policy, targetRequest)
	if err != nil || replacement.Grant == nil {
		t.Fatal(err)
	}
	if _, err := b.ReclassifyHostReserve(&policy, &expected, func(Grant) error { t.Fatal("stale pin reached proof"); return nil }); !errors.Is(err, ErrFenceMismatch) {
		t.Fatal("replacement accepted", err)
	}
}

func TestHostReserveClassificationRejectsStaleAndFailedProofWithoutWrites(t *testing.T) {
	for _, field := range []string{"id", "pool", "resources", "cost", "fence", "time", "proof", "policy"} {
		t.Run(field, func(t *testing.T) {
			policy := hostPolicy()
			policy.Pools[hostReserveGuestPool] = policy.Pools["qa"]
			delete(policy.Pools, "qa")
			b := diagnosticBroker(t, &policy)
			decision, err := b.Admit(&policy, Request{ID: hostReserveRouterID, Pool: hostReserveGuestPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 2}})
			if err != nil || decision.Grant == nil {
				t.Fatal(err)
			}
			g := decision.Grant
			hash := sha256.Sum256([]byte(g.Fence))
			expected := GrantDiagnostic{Request: g.Request, Cost: g.Cost, FenceSHA256: hex.EncodeToString(hash[:]), GrantedAt: g.GrantedAt}
			before, err := os.ReadFile(b.Path)
			if err != nil {
				t.Fatal(err)
			}
			switch field {
			case "id":
				expected.ID = "" // cannot classify an unspecified workload
			case "pool":
				expected.Pool = buildPool
			case "resources":
				expected.Resources.MemoryMiB++
			case "cost":
				expected.Cost.MemoryMiB++
			case "fence":
				expected.FenceSHA256 = "stale"
			case "time":
				expected.GrantedAt = expected.GrantedAt.Add(time.Second)
			case "policy":
				policy.Budget.MemoryMiB++
			}
			changed, err := b.ReclassifyHostReserve(&policy, &expected, func(Grant) error { return errors.New("proof unavailable") })
			if err == nil || changed {
				t.Fatal("unsafe classification accepted")
			}
			after, err := os.ReadFile(b.Path)
			if err != nil || !reflect.DeepEqual(before, after) {
				t.Fatal("failed transaction wrote ledger", err)
			}
		})
	}
	b := &Broker{Path: filepath.Join(t.TempDir(), "absent.bolt")}
	policy := hostPolicy()
	_, err := b.ReclassifyHostReserve(&policy, &GrantDiagnostic{Request: Request{ID: hostReserveRouterID, Pool: hostReserveGuestPool, Resources: Resources{MemoryMiB: 4096, VCPUs: 2}}, Cost: Resources{MemoryMiB: 4096, VCPUs: 2}}, func(Grant) error { return nil })
	if err == nil {
		t.Fatal("missing ledger initialized")
	}
	if _, err := os.Stat(b.Path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("ledger was created", err)
	}
}
