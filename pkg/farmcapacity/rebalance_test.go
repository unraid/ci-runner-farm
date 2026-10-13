// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const testPriorityDemand = "qa-demand"

type fakePlanningOwner struct {
	docker  *fakeDocker
	id      string
	frozen  bool
	busy    bool
	gone    bool
	unknown bool
}

func (o *fakePlanningOwner) Idle(context.Context) (bool, error) {
	if o.unknown {
		return false, errors.New("unknown owner")
	}
	return !o.busy, nil
}
func (o *fakePlanningOwner) Freeze(context.Context) error { o.frozen = true; return nil }
func (o *fakePlanningOwner) FrozenIdle(ctx context.Context) (bool, error) {
	if !o.frozen {
		return false, errors.New("not frozen")
	}
	return o.Idle(ctx)
}
func (o *fakePlanningOwner) Resume(context.Context) error                       { o.frozen = false; return nil }
func (o *fakePlanningOwner) RemoteIdle(ctx context.Context) (bool, error)       { return o.Idle(ctx) }
func (o *fakePlanningOwner) WithdrawRemote(context.Context) error               { o.gone = true; return nil }
func (o *fakePlanningOwner) RemoteGone(context.Context) (bool, error)           { return o.gone, nil }
func (o *fakePlanningOwner) RegistrationNameGone(context.Context) (bool, error) { return o.gone, nil }
func (o *fakePlanningOwner) RemoveFrozen(context.Context) error {
	if !o.frozen || o.busy || !o.gone {
		return errors.New("unsafe remove")
	}
	delete(o.docker.containers, o.id)
	return nil
}

func (o *fakePlanningOwner) Removed(context.Context) (bool, error) {
	return o.docker.containers[o.id] == nil, nil
}

func pressureFixture(t *testing.T) (*Controller, map[string]*fakePlanningOwner, BindOwner, *time.Time) {
	t.Helper()
	return pressureFixtureCount(t, 5)
}

func pressureFixtureCount(t *testing.T, count uint32) (*Controller, map[string]*fakePlanningOwner, BindOwner, *time.Time) {
	t.Helper()
	root := t.TempDir()
	now := time.Now().UTC()
	docker := &fakeDocker{containers: map[string]*Container{}}
	controller := &Controller{
		Broker: sharedcapacity.Broker{Path: filepath.Join(root, "ledger.bolt"), Now: func() time.Time { return now }},
		Policy: sharedcapacity.Policy{
			Budget: sharedcapacity.Resources{MemoryMiB: uint64(count) * 12288, VCPUs: count}, AgingSeconds: 600,
			Pools: map[string]sharedcapacity.Pool{buildPool: {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 1}, Minimum: 4, Maximum: 8, Priority: 1}, "qa": {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 1}, Maximum: 8, Priority: 3}},
		},
		ReceiptRoot: filepath.Join(root, "owners"), Docker: docker,
	}
	if err := controller.Broker.Initialize(&controller.Policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	owners := map[string]*fakePlanningOwner{}
	for index := uint32(1); index <= count; index++ {
		id := strings.Repeat(strconv.FormatUint(uint64(index), 16), 64)
		name := fmt.Sprintf("ci-runner-build-%d", index)
		docker.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000}
		if err := controller.Start(context.Background(), name, id); err != nil {
			t.Fatal(err)
		}
		owners[id] = &fakePlanningOwner{docker: docker, id: id}
	}
	decision, err := controller.Broker.Admit(&controller.Policy, sharedcapacity.Request{ID: testPriorityDemand, Pool: "qa"})
	if err != nil || decision.Admitted {
		t.Fatalf("pressure fixture: %v", err)
	}
	bind := func(_ context.Context, name, id string, _ int64, _ string) (OwnerBinding, error) {
		return OwnerBinding{Owner: owners[id], RunnerID: 123, RunnerName: name}, nil
	}
	return controller, owners, bind, &now
}

func TestNativeRebalanceWithdrawsOnlyNeededIdleExtraAndPreservesFloor(t *testing.T) {
	c, owners, bind, now := pressureFixture(t)
	if err := c.Rebalance(context.Background(), bind); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	frozen := 0
	for _, owner := range owners {
		if owner.frozen {
			frozen++
		}
	}
	if frozen != 1 {
		t.Fatalf("drained %d instead of the one allocation needed", frozen)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil || len(before.Grants) != 5 {
		t.Fatal("withdrawal released before pickup settled")
	}
	if retryErr := c.Rebalance(context.Background(), bind); !errors.Is(retryErr, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(retryErr)
	}
	for _, owner := range owners {
		if owner.frozen && !owner.gone {
			t.Fatal("settling withdrawal repeated a remote effect")
		}
	}
	*now = now.Add(80 * time.Second)
	if rebalanceErr := c.Rebalance(context.Background(), bind); rebalanceErr != nil {
		t.Fatal(rebalanceErr)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || len(after.Grants) != 4 {
		t.Fatal("build guarantee changed")
	}
	decision, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: testPriorityDemand, Pool: "qa"})
	if err != nil || !decision.Admitted {
		t.Fatal("priority QA demand was not admitted after exact idle release")
	}
}

func TestNativeRebalanceNeverWithdrawsBusyOrUnknownBuilds(t *testing.T) {
	for _, unknown := range []bool{false, true} {
		c, owners, bind, _ := pressureFixture(t)
		for _, owner := range owners {
			owner.busy = !unknown
			owner.unknown = unknown
		}
		err := c.Rebalance(context.Background(), bind)
		if unknown && err == nil {
			t.Fatal("unknown state was not reported")
		}
		for _, owner := range owners {
			if owner.frozen || owner.gone {
				t.Fatal("busy or unknown owner withdrawn")
			}
		}
		snapshot, statusErr := c.Broker.Status(&c.Policy)
		if statusErr != nil || len(snapshot.Grants) != 5 {
			t.Fatal("busy or unknown allocation lost")
		}
	}
}

func TestNativeRebalanceDoesNotOverWithdrawOnSettlementRetries(t *testing.T) {
	c, owners, bind, _ := pressureFixtureCount(t, 6)
	for range 3 {
		if err := c.Rebalance(context.Background(), bind); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
			t.Fatal(err)
		}
		frozen := 0
		for _, owner := range owners {
			if owner.frozen {
				frozen++
			}
		}
		if frozen != 1 {
			t.Fatalf("settling demand froze %d builders instead of one", frozen)
		}
	}
}

func TestExitedFloorOwnerRetiresWithoutRestartingAndRetainsBusyRegistration(t *testing.T) {
	for _, busy := range []bool{false, true} {
		c, owners, bind, now := pressureFixtureCount(t, 4)
		docker, ok := c.Docker.(*fakeDocker)
		if !ok {
			t.Fatal("fixture owner differs")
		}
		name := "ci-runner-build-1"
		id := strings.Repeat("1", 64)
		item := docker.containers[id]
		item.Running = false
		item.Exited = true
		owners[id].busy = busy
		beforeStarts := docker.starts
		if err := c.Start(context.Background(), name, id); !errors.Is(err, ErrQueued) {
			t.Fatal("exited credentials restarted", err)
		}
		err := c.Rebalance(context.Background(), bind)
		if busy {
			if err == nil || owners[id].gone || docker.starts != beforeStarts {
				t.Fatal("busy registration retired or restarted", err)
			}
			return
		}
		if !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
			t.Fatal(err)
		}
		if docker.containers[id] == nil {
			t.Fatal("exited owner removed before settlement")
		}
		*now = now.Add(80 * time.Second)
		if rebalanceErr := c.Rebalance(context.Background(), bind); rebalanceErr != nil {
			t.Fatal(rebalanceErr)
		}
		if docker.containers[id] != nil || docker.starts != beforeStarts {
			t.Fatal("completed owner was restarted")
		}
		snapshot, err := c.Broker.Status(&c.Policy)
		if err != nil || len(snapshot.Grants) != 3 {
			t.Fatal("exact completed allocation did not release", err)
		}
		// The guaranteed floor remains reserved for a fresh replacement, rather
		// than admitting higher-priority demand into its resource guarantee.
		decision, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: testPriorityDemand, Pool: "qa"})
		if err != nil || decision.Admitted {
			t.Fatal("QA stole a missing guaranteed build slot", err)
		}
	}
}

type registrationGonePlanningOwner struct {
	*fakePlanningOwner
	registrationGone bool
}

func (o *registrationGonePlanningOwner) RegistrationGone(ctx context.Context) (bool, error) {
	idle, err := o.Idle(ctx)
	return o.registrationGone && idle, err
}

func TestLostRegistrationRecoversOnlyIdleOwnerAndPreservesFloorUntilSettlement(t *testing.T) {
	for _, busy := range []bool{false, true} {
		c, owners, original, now := pressureFixtureCount(t, 4)
		id := strings.Repeat("1", 64)
		owners[id].busy = busy
		owners[id].gone = true
		bind := func(ctx context.Context, name, id string, runnerID int64, runnerName string) (OwnerBinding, error) {
			binding, err := original(ctx, name, id, runnerID, runnerName)
			binding.Owner = &registrationGonePlanningOwner{fakePlanningOwner: owners[id], registrationGone: id == strings.Repeat("1", 64)}
			return binding, err
		}
		err := c.Rebalance(context.Background(), bind)
		owned, readErr := c.load(testName)
		if readErr != nil {
			t.Fatal(readErr)
		}
		if busy {
			if err != nil || owned.Maintenance || owners[id].frozen {
				t.Fatal("busy owner was frozen or marked terminal", err)
			}
			continue
		}
		if !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) || !owned.Maintenance || !owners[id].frozen {
			t.Fatal("missing frozen recovery intent", err)
		}
		snapshot, err := c.Broker.Status(&c.Policy)
		if err != nil || len(snapshot.Grants) != 4 {
			t.Fatal("unsettled owner was released", err)
		}
		*now = now.Add(80 * time.Second)
		if rebalanceErr := c.Rebalance(context.Background(), bind); rebalanceErr != nil {
			t.Fatal(rebalanceErr)
		}
		snapshot, err = c.Broker.Status(&c.Policy)
		if err != nil || len(snapshot.Grants) != 3 {
			t.Fatal("settled owner not released", err)
		}
	}
}

func TestPreparedNativeReleaseSurvivesRemovalAndFailedRelease(t *testing.T) {
	c, owners, bind, _ := pressureFixture(t)
	ctx := context.Background()
	name := testName
	id := strings.Repeat("1", 64)
	if err := c.PrepareRelease(ctx, name, id); err != nil {
		t.Fatal(err)
	}
	if err := c.Start(ctx, name, id); err == nil {
		t.Fatal("removal intent allowed restart")
	}
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker type differs")
	}
	delete(docker.containers, id)
	owned, loadErr := c.load(name)
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	owned.DockerRoot = "/mnt/cache/docker/" + name
	if saveErr := c.save(name, owned); saveErr != nil {
		t.Fatal(saveErr)
	}
	c.RepairCache = func(context.Context, string, string) error { return errors.New("repair unavailable") }
	if releaseErr := c.Release(ctx, name, id); releaseErr == nil {
		t.Fatal("failed repair released allocation")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	restarted := *c
	restarted.RepairCache = func(context.Context, string, string) error { return nil }
	if recoverErr := restarted.recoverReleasedOwners(ctx, &snapshot, bind); recoverErr == nil {
		t.Fatal("unknown remote removal released grant")
	}
	owners[id].gone = true
	if recoverErr := restarted.recoverReleasedOwners(ctx, &snapshot, bind); recoverErr != nil {
		t.Fatal(recoverErr)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := after.Grants["build:"+name]; exists {
		t.Fatal("durable release was not retried")
	}
}

func TestNativeWithdrawalProtectsSelectedStandardSlotAmongExtras(t *testing.T) {
	c, owners, _, now := pressureFixture(t)
	previous := c.Policy
	revised := c.Policy
	revised.Pools = maps.Clone(previous.Pools)
	pool := revised.Pools[buildPool]
	pool.MinimumRequestIDs = []string{"build:ci-runner-build-1", "build:ci-runner-build-2", "build:ci-runner-build-3", "build:ci-runner-build-4"}
	revised.Pools[buildPool] = pool
	if err := c.Broker.ReconcilePolicy(&previous, &revised); err != nil {
		t.Fatal(err)
	}
	c.Policy = revised
	id := strings.Repeat("1", 64)
	err := c.Withdraw(context.Background(), "ci-runner-build-1", id, owners[id], 123, "ci-runner-build-1", *now)
	if err == nil || owners[id].frozen || owners[id].gone {
		t.Fatal("designated standard floor was withdrawn among extras", err)
	}
	extra := strings.Repeat("5", 64)
	if err = c.Withdraw(context.Background(), "ci-runner-build-5", extra, owners[extra], 123, "ci-runner-build-5", *now); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal("nonselected extra could not withdraw", err)
	}
	*now = now.Add(80 * time.Second)
	if err = c.Withdraw(context.Background(), "ci-runner-build-5", extra, owners[extra], 123, "ci-runner-build-5", *now); err != nil {
		t.Fatal(err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || len(after.Grants) != 4 {
		t.Fatal("fenced settlement changed the selected floor", err)
	}
}
