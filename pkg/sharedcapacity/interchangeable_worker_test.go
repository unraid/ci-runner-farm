package sharedcapacity

import (
	"errors"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"
)

// The worker envelope includes its job-owned guest. These tests exercise the
// existing broker, not a proposed mode scheduler or a real Docker/KVM caller.
func interchangeablePolicy() Policy {
	return Policy{
		Budget: Resources{MemoryMiB: 49152, VCPUs: 16}, AgingSeconds: 60,
		Pools: map[string]Pool{
			"worker": {Cost: Resources{MemoryMiB: 12288, VCPUs: 4}, Maximum: 8},
		},
	}
}

func TestInterchangeableWorkerMixedContentionHasOneBudget(t *testing.T) {
	policy := interchangeablePolicy()
	broker := newBroker(t, &policy)
	var attempts sync.WaitGroup
	for index := range 32 {
		attempts.Go(func() {
			kind := "build"
			if index%2 == 0 {
				kind = "guest"
			}
			_, err := broker.Admit(&policy, Request{ID: fmt.Sprintf("%s-%d", kind, index), Pool: "worker"})
			if err != nil {
				t.Errorf("admission: %v", err)
			}
		})
	}
	attempts.Wait()
	snapshot, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Grants) != 4 || len(snapshot.Pending) != 28 {
		t.Fatalf("mixed requests escaped one envelope budget: grants=%d pending=%d", len(snapshot.Grants), len(snapshot.Pending))
	}
	var memory uint64
	var cpus uint32
	for _, grant := range snapshot.Grants {
		memory += grant.Cost.MemoryMiB
		cpus += grant.Cost.VCPUs
	}
	if memory != policy.Budget.MemoryMiB || cpus != policy.Budget.VCPUs {
		t.Fatalf("charges changed: memory=%d cpus=%d", memory, cpus)
	}
}

func TestInterchangeableWorkerEnvelopeDoesNotAddASecondGuestCharge(t *testing.T) {
	policy := interchangeablePolicy()
	broker := newBroker(t, &policy)
	guest := requireGrant(t, broker, &policy, "job-owned-guest", "worker")
	// A retry is the same container envelope, even when another controller opens
	// the ledger. A separate guest pool is deliberately not configured here.
	restarted := &Broker{Path: broker.Path}
	retry := requireGrant(t, restarted, &policy, guest.ID, "worker")
	if retry != guest {
		t.Fatal("retry changed the inclusive worker allocation")
	}
	if _, err := restarted.Admit(&policy, Request{ID: "nested-guest", Pool: "qa-guest"}); err == nil {
		t.Fatal("undeclared second guest allocation was accepted")
	}
	snapshot, err := restarted.Status(&policy)
	if err != nil || len(snapshot.Grants) != 1 || snapshot.Grants[guest.ID].Cost != policy.Pools["worker"].Cost {
		t.Fatal("guest envelope was charged twice", snapshot, err)
	}
}

func TestInterchangeableWorkerCancellationAndTimeDoNotReleaseOwner(t *testing.T) {
	policy := interchangeablePolicy()
	broker := newBroker(t, &policy)
	grant := requireGrant(t, broker, &policy, "live-listener", "worker")
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	broker.Now = func() time.Time { return grant.GrantedAt.Add(30 * 24 * time.Hour) }
	if err := broker.Cancel(&policy, grant.Request); err == nil {
		t.Fatal("canceling a job freed its surviving worker")
	}
	if err := broker.Release(&policy, grant.ID, grant.Fence, func(Grant) error {
		return errors.New("job child exited but listener is still alive")
	}); err == nil {
		t.Fatal("child exit freed surviving listener allocation")
	}
	after, err := broker.Status(&policy)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("time or failed stop changed the durable owner", err)
	}
}

func TestInterchangeableWorkerUnknownAndDelayedReleaseCannotAffectReplacement(t *testing.T) {
	policy := interchangeablePolicy()
	broker := newBroker(t, &policy)
	old := requireGrant(t, broker, &policy, "same-slot", "worker")
	called := false
	if err := broker.Release(&policy, old.ID, "unknown-fence", func(Grant) error {
		called = true
		return nil
	}); !errors.Is(err, ErrFenceMismatch) || called {
		t.Fatal("unknown owner reached stop proof", err)
	}
	releaseGrant(t, broker, &policy, &old)
	current := requireGrant(t, broker, &policy, old.ID, "worker")
	if current.Fence == old.Fence {
		t.Fatal("replacement reused retired fence")
	}
	if err := broker.Release(&policy, old.ID, old.Fence, func(Grant) error {
		t.Fatal("delayed release reached replacement stop proof")
		return nil
	}); !errors.Is(err, ErrFenceMismatch) {
		t.Fatal(err)
	}
}

func TestInterchangeableWorkerChangedEnvelopeFailsBeforeMutation(t *testing.T) {
	policy := interchangeablePolicy()
	broker := newBroker(t, &policy)
	grant := requireGrant(t, broker, &policy, "guest-job", "worker")
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	for _, cost := range []Resources{{MemoryMiB: 8192, VCPUs: 4}, {MemoryMiB: 12288, VCPUs: 2}} {
		if _, err := broker.Admit(&policy, Request{ID: grant.ID, Pool: grant.Pool, Resources: cost}); err == nil {
			t.Fatal("retry changed an active envelope", cost)
		}
	}
	after, err := broker.Status(&policy)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("rejected envelope change mutated owner", err)
	}
}

func TestInterchangeableWorkerUncertainStartKeepsReserveAcrossRestart(t *testing.T) {
	policy := sharedHeadroomPolicy(t)
	broker := newBroker(t, &policy)
	cost := policy.Pools["qa"].Cost.MemoryMiB
	available := policy.BuildMemoryOvercommit.MinimumAvailableMiB + cost
	observe := func() (MemoryObservation, error) {
		return MemoryObservation{AvailableMiB: available, ObservedAt: broker.now()}, nil
	}
	broker.ObserveMemory = observe
	grant := requireGrant(t, broker, &policy, "pending-guest", "qa")
	start, err := broker.ReserveStart(&policy, grant.ID, grant.Fence)
	if err != nil {
		t.Fatal(err)
	}
	if err := broker.ConfirmStarted(&policy, grant.ID, start, func(Grant) error {
		return errors.New("create returned but execution was not observed")
	}); err == nil {
		t.Fatal("uncertain start discarded physical reservation")
	}
	restarted := &Broker{Path: broker.Path, ObserveMemory: observe}
	decision, err := restarted.Admit(&policy, Request{ID: "second-guest", Pool: "qa"})
	if err != nil || decision.Admitted || decision.Reason != memoryPressure {
		t.Fatal("restart spent the uncertain start's RAM again", decision, err)
	}
	snapshot, err := restarted.Status(&policy)
	if err != nil || snapshot.Starts[grant.ID] != start || pendingStartMemory(&snapshot, "") != cost {
		t.Fatal("restart lost exact start reservation", err)
	}
	if err := restarted.ConfirmStarted(&policy, grant.ID, start, func(Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
	// Once execution is proved, the host observation includes the real resident
	// charge. Only the shadow reservation is removed, never the durable grant.
	available -= cost
	decision, err = restarted.Admit(&policy, Request{ID: "second-guest", Pool: "qa"})
	if err != nil || decision.Admitted {
		t.Fatal("running guest consumed the host reserve", decision, err)
	}
	snapshot, err = restarted.Status(&policy)
	if err != nil || snapshot.Grants[grant.ID] != grant || snapshot.Starts[grant.ID].MemoryMiB != 0 || !snapshot.Starts[grant.ID].Started {
		t.Fatal("started confirmation changed durable grant or kept duplicate shadow charge", err)
	}
}

func TestInterchangeableWorkerDrainRetainsBusyAndUnknownOwners(t *testing.T) {
	policy := hostPolicy()
	broker := newBroker(t, &policy)
	var builders []Grant
	for i := range 8 {
		builders = append(builders, requireGrant(t, broker, &policy, fmt.Sprintf("mixed-worker-%d", i), buildPool))
	}
	requireGrant(t, broker, &policy, "guest-existing", "qa")
	decision, err := broker.Admit(&policy, Request{ID: "guest-waiting", Pool: "qa"})
	if err != nil || decision.Admitted {
		t.Fatal(decision, err)
	}
	snapshot, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	now := broker.now()
	observed := map[string]Observation{}
	for _, grant := range builders {
		observed[grant.ID] = Observation{Fence: grant.Fence, Busy: true, ObservedAt: now}
	}
	for _, mode := range []string{"busy", "missing", "stale", "wrong-fence"} {
		t.Run(mode, func(t *testing.T) {
			candidate := builders[7]
			o := Observation{Fence: candidate.Fence, Busy: true, ObservedAt: now}
			switch mode {
			case "missing":
				delete(observed, candidate.ID)
			case "stale":
				o.Busy, o.ObservedAt = false, now.Add(-time.Minute)
			case "wrong-fence":
				o.Busy, o.Fence = false, "retired-fence"
			}
			if mode != "missing" {
				observed[candidate.ID] = o
			}
			plan, err := PlanDrain(&snapshot, observed, now)
			if err != nil || len(plan.Grants) != 0 {
				t.Fatal("busy or unknown worker selected for drain", plan, err)
			}
		})
	}
	idle := builders[7]
	observed[idle.ID] = Observation{Fence: idle.Fence, ObservedAt: now}
	plan, err := PlanDrain(&snapshot, observed, now)
	if err != nil || len(plan.Grants) != 1 || plan.Grants[0] != idle {
		t.Fatal("fresh idle worker did not produce exact drain proposal", plan, err)
	}
	after, err := broker.Status(&policy)
	if err != nil || !reflect.DeepEqual(snapshot, after) {
		t.Fatal("drain proposal released a worker before owner settlement", err)
	}
}
