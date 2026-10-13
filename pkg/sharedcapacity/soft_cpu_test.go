package sharedcapacity

import (
	"errors"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"
)

const (
	softCPUQA         = "qa-guest"
	softCPUListener   = "qa-runner"
	softCPUFloorOne   = "build-1"
	softCPUHostBudget = "host_budget"
)

func cpuContendedFleet(t *testing.T) (*Broker, Policy) {
	t.Helper()
	policy := hostPolicy()
	delete(policy.Pools, "qa")
	policy.Pools[buildPool] = Pool{
		Cost: Resources{MemoryMiB: 12288, VCPUs: 4}, MaxCost: Resources{MemoryMiB: 16384, VCPUs: 4}, Minimum: 4, Maximum: 8, Priority: 1,
		MinimumRequestIDs: []string{softCPUFloorOne, "build-2", "build-3", "build-4"},
	}
	policy.Pools[softCPUListener] = Pool{Cost: Resources{MemoryMiB: 2048, VCPUs: 1}, Minimum: 4, Maximum: 8, Priority: 2}
	policy.Pools[softCPUQA] = Pool{Cost: Resources{MemoryMiB: 9216, VCPUs: 4}, Maximum: 8, Priority: 3}
	broker := diagnosticBroker(t, &policy)
	for i := 1; i <= 4; i++ {
		requireGrant(t, broker, &policy, fmt.Sprintf("build-%d", i), buildPool)
	}
	for i := range 8 {
		requireGrant(t, broker, &policy, fmt.Sprintf("listener-%d", i), softCPUListener)
	}
	if d, err := broker.Admit(&policy, Request{ID: "unknown-large", Pool: buildPool, Resources: Resources{MemoryMiB: 16384, VCPUs: 4}}); err != nil || !d.Admitted {
		t.Fatal(d, err)
	}
	return broker, policy
}

func TestSoftCPURemovesCPUOnlyWaitAndDrainWithoutReclaimingOwners(t *testing.T) {
	broker, hard := cpuContendedFleet(t)
	request := Request{ID: "guest", Pool: softCPUQA}
	owner := waitOwner()
	d, err := broker.AdmitOwned(&hard, request, owner)
	if err != nil || d.Admitted || d.Reason != diagnosticBudget {
		t.Fatal("hard CPU control did not reproduce wait", d, err)
	}
	before, err := broker.Status(&hard)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	large := before.Grants["unknown-large"]
	// Even a positively idle burst builder must not yield solely for CPU.
	observations := map[string]Observation{large.ID: {Fence: large.Fence, ObservedAt: now}}
	plan, err := PlanDrain(&before, observations, now)
	if err != nil || len(plan.Grants) != 1 {
		t.Fatal("hard CPU control did not reproduce retirement", plan, err)
	}
	soft := hard
	soft.CPUAdmission = CPUAdmissionSoft
	if err = broker.CheckPolicyChange(&hard, &soft); err != nil {
		t.Fatal(err)
	}
	if err = broker.ReconcilePolicy(&hard, &soft); err != nil {
		t.Fatal(err)
	}
	after, err := broker.Status(&soft)
	if err != nil || after.Schema != softCPULedgerSchema || !reflect.DeepEqual(before.Grants, after.Grants) || !reflect.DeepEqual(before.Pending, after.Pending) {
		t.Fatal("migration changed grants, fences, owners or retry age", err)
	}
	plan, err = PlanDrain(&after, observations, now)
	if err != nil || !plan.Ready || len(plan.Grants) != 0 {
		t.Fatal("CPU contention still retired builders", plan, err)
	}
	report, err := broker.Diagnose(&soft)
	if err != nil || len(report.Pending) != 1 || report.Pending[0].Reason != diagnosticWouldAdmit || report.Remaining.VCPUs != 0 {
		t.Fatal("diagnostics still block CPU", report, err)
	}
	wrong := *owner
	wrong.Incarnation = "other-attempt"
	if _, err = broker.AdmitOwned(&soft, request, &wrong); err == nil {
		t.Fatal("soft CPU bypassed owner fence")
	}
	d, err = broker.AdmitOwned(&soft, request, owner)
	if err != nil || !d.Admitted || d.Grant.Cost != soft.Pools[softCPUQA].Cost {
		t.Fatal("exact owner could not resume at unchanged hardware", d, err)
	}
	assertSoftCPUAccounting(t, broker, &soft, &large)
	if err = broker.Release(&soft, large.ID, "stale-fence", func(Grant) error { t.Fatal("stale fence reached proof"); return nil }); !errors.Is(err, ErrFenceMismatch) {
		t.Fatal("soft admission weakened release fencing", err)
	}
	assertSoftCPURollback(t, broker, &soft, &hard, d.Grant, before.Grants)
}

func assertSoftCPUAccounting(t *testing.T, broker *Broker, soft *Policy, large *Grant) {
	t.Helper()
	report, err := broker.Diagnose(soft)
	if err != nil || report.AllocatedVCPUs != 32 || !report.CPUOvercommitted || report.Remaining.VCPUs != 0 || report.Remaining.MemoryMiB != 20864 {
		t.Fatal("overcommit accounting underflowed or lost charges", report, err)
	}
	after, err := broker.Status(soft)
	if err != nil || after.Schema != softCPULedgerSchema || after.Grants[large.ID] != *large {
		t.Fatal("owned admission downgraded ledger or reclaimed unknown grant", err)
	}
}

func assertSoftCPURollback(t *testing.T, broker *Broker, soft, hard *Policy, guest *Grant, original map[string]Grant) {
	t.Helper()
	var err error
	var after Snapshot
	if err = broker.CheckPolicyChange(soft, hard); err == nil {
		t.Fatal("hard rollback accepted overcommitted CPU")
	}
	if err = broker.ReconcilePolicy(soft, hard); err == nil {
		t.Fatal("hard rollback committed overcommitted CPU")
	}
	releaseGrant(t, broker, soft, guest)
	if err = broker.ReconcilePolicy(soft, hard); err != nil {
		t.Fatal("safe hard rollback failed", err)
	}
	after, err = broker.Status(hard)
	if err != nil || after.Schema != softCPULedgerSchema || !reflect.DeepEqual(original, after.Grants) {
		t.Fatal("rollback downgraded schema or changed existing grants", err)
	}
}

func TestSoftCPUConcurrentAdmissionKeepsMemoryAndPoolLimits(t *testing.T) {
	broker, hard := cpuContendedFleet(t)
	soft := hard
	soft.CPUAdmission = CPUAdmissionSoft
	if err := broker.ReconcilePolicy(&hard, &soft); err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	for i := range 16 {
		workers.Go(func() {
			if _, err := broker.Admit(&soft, Request{ID: fmt.Sprintf("guest-%02d", i), Pool: softCPUQA}); err != nil {
				t.Error(err)
			}
		})
	}
	workers.Wait()
	report, err := broker.Diagnose(&soft)
	if err != nil || len(report.Grants) != 16 || len(report.Pending) != 13 || report.Remaining.MemoryMiB != 2432 || report.AllocatedVCPUs != 40 {
		t.Fatal("concurrent soft admission escaped memory budget", report, err)
	}
	for _, p := range report.Pending {
		if p.Constraint != softCPUHostBudget {
			t.Fatal("memory wait lost its constraint", p)
		}
	}
	if d, admitErr := broker.Admit(&soft, Request{ID: "listener-over-max", Pool: softCPUListener}); admitErr != nil || d.Admitted {
		t.Fatal("soft admission escaped pool maximum", d, admitErr)
	}
}

func TestSoftCPUKeepsMemoryFloorsAndPerWorkloadEnvelope(t *testing.T) {
	policy := hostPolicy()
	policy.CPUAdmission = CPUAdmissionSoft
	policy.Budget.VCPUs = 4 // Four builders and a guest may share these CPUs.
	broker := newBroker(t, &policy)
	for i := range 8 {
		requireGrant(t, broker, &policy, fmt.Sprintf("guest-%d", i), "qa")
	}
	for i := range 4 {
		grant := requireGrant(t, broker, &policy, fmt.Sprintf("build-%d", i), buildPool)
		snapshot, err := broker.Status(&policy)
		if err != nil || !ProtectsMinimum(&snapshot, grant.Request) {
			t.Fatal("soft CPU lost builder floor", err)
		}
	}
	if d, err := broker.Admit(&policy, Request{ID: "burst", Pool: buildPool}); err != nil || d.Admitted {
		t.Fatal("floor memory was not protected", d, err)
	}
	if _, err := broker.Admit(&policy, Request{ID: "oversize", Pool: "qa", Resources: Resources{MemoryMiB: 7168, VCPUs: 4}}); err == nil {
		t.Fatal("soft host admission weakened per-workload CPU envelope")
	}
	policy.CPUAdmission = "typo"
	if err := policy.Validate(); err == nil {
		t.Fatal("unknown CPU admission accepted")
	}
}

func TestSoftCPUSchemaAndSuspendedOwnerCompatibility(t *testing.T) {
	broker, hard := cpuContendedFleet(t)
	d, err := broker.AdmitOwned(&hard, Request{ID: "suspended", Pool: softCPUQA}, waitOwner())
	if err != nil || d.Pending == nil {
		t.Fatal(d, err)
	}
	if err = broker.SuspendPending(&hard, d.Pending, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	before, err := broker.Status(&hard)
	if err != nil {
		t.Fatal(err)
	}
	soft := hard
	soft.CPUAdmission = CPUAdmissionSoft
	if err = broker.ReconcilePolicy(&hard, &soft); err != nil {
		t.Fatal(err)
	}
	after, err := broker.Status(&soft)
	if err != nil || !reflect.DeepEqual(before.Pending, after.Pending) {
		t.Fatal("policy CAS changed suspended owner's age or revision", err)
	}
	for _, schema := range []string{ledgerSchema, ownedWaitLedgerSchema} {
		legacy := after
		legacy.Schema = schema
		if err = validateSnapshot(&legacy); err == nil {
			t.Fatal("soft CPU accepted downlevel ledger", schema)
		}
	}
	plan, err := PlanDrain(&after, nil, time.Now().UTC())
	if err != nil || plan.WaitingID != "" {
		t.Fatal("soft CPU resumed suspended owner", plan, err)
	}
	if err = broker.ReconcilePolicy(&hard, &soft); err != nil {
		t.Fatal("exact destination recovery is not idempotent", err)
	}
}

func TestSoftCPUOSBuilderDemandPreservesSpecializedProfiles(t *testing.T) {
	policy := Policy{Budget: Resources{MemoryMiB: 112000, VCPUs: 28}, AgingSeconds: 600, Pools: map[string]Pool{
		buildPool:       {Cost: Resources{MemoryMiB: 16384, VCPUs: 6}, MaxCost: Resources{MemoryMiB: 16384, VCPUs: 8}, Minimum: 2, Maximum: 24, Priority: 1, MinimumRequestIDs: []string{softCPUFloorOne, "build-2"}},
		softCPUListener: {Cost: Resources{MemoryMiB: 2048, VCPUs: 2}, Minimum: 2, Maximum: 2, Priority: 2},
		softCPUQA:       {Cost: Resources{MemoryMiB: 25600, VCPUs: 6}, Maximum: 2, Priority: 3},
	}}
	broker := diagnosticBroker(t, &policy)
	for i := 1; i <= 4; i++ {
		requireGrant(t, broker, &policy, fmt.Sprintf("build-%d", i), buildPool)
	}
	for i := range 2 {
		requireGrant(t, broker, &policy, fmt.Sprintf("listener-%d", i), softCPUListener)
	}
	request := Request{ID: "build-5", Pool: buildPool}
	if d, err := broker.Admit(&policy, request); err != nil || d.Admitted || d.Reason != diagnosticBudget {
		t.Fatal("OS hard CPU policy did not reproduce queued builder", d, err)
	}
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	soft := policy
	soft.CPUAdmission = CPUAdmissionSoft
	if err = broker.ReconcilePolicy(&policy, &soft); err != nil {
		t.Fatal(err)
	}
	after, err := broker.Status(&soft)
	if err != nil || !reflect.DeepEqual(before.Grants, after.Grants) || !reflect.DeepEqual(before.Pending, after.Pending) || !reflect.DeepEqual(policy.Pools, soft.Pools) {
		t.Fatal("mode change altered owners, queue age or specialized profiles", err)
	}
	for _, id := range []string{"build-5", "build-6"} {
		grant := requireGrant(t, broker, &soft, id, buildPool)
		if grant.Cost.VCPUs != 6 {
			t.Fatal("builder CPU profile changed", grant)
		}
	}
	if d, admitErr := broker.Admit(&soft, Request{ID: "build-7", Pool: buildPool}); admitErr != nil || d.Admitted {
		t.Fatal("growth escaped hard RAM budget", d, admitErr)
	}
	if d, admitErr := broker.Admit(&soft, Request{ID: "listener-extra", Pool: softCPUListener}); admitErr != nil || d.Admitted {
		t.Fatal("builder growth expanded the QA listener pool", d, admitErr)
	}
	if _, admitErr := broker.Admit(&soft, Request{ID: "listener-as-builder", Pool: softCPUListener, Resources: soft.Pools[buildPool].Cost}); admitErr == nil {
		t.Fatal("QA listener accepted builder resources")
	}
}
