// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func demandFixture(t *testing.T) (*Controller, map[string]*fakePlanningOwner, BindOwner, *time.Time) {
	t.Helper()
	c, owners, bind, now := pressureFixtureCount(t, 5)
	if checkErr := c.Broker.Cancel(&c.Policy, sharedcapacity.Request{ID: testPriorityDemand, Pool: "qa"}); checkErr != nil {
		t.Fatal(checkErr)
	}
	return c, owners, bind, now
}

func TestDemandRetiresIdleExtraAndKeepsWarmStandardFloor(t *testing.T) {
	c, owners, bind, now := demandFixture(t)
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8}}
	starts, err := c.DemandStarts(context.Background(), pools, map[string]int{buildPool: 0}, bind)
	if err != nil || len(starts[buildPool]) != 0 {
		t.Fatal(starts, err)
	}
	frozen := 0
	for _, owner := range owners {
		if owner.frozen {
			frozen++
		}
	}
	if frozen != 1 {
		t.Fatalf("frozen=%d", frozen)
	}
	*now = now.Add(80 * time.Second)
	if checkErr := c.Rebalance(context.Background(), bind); checkErr != nil {
		t.Fatal(checkErr)
	}
	status, err := c.Broker.Status(&c.Policy)
	if err != nil || len(status.Grants) != 4 {
		t.Fatal(status, err)
	}
}

func TestDemandDrainsIdleOwnerAboveLoweredCeiling(t *testing.T) {
	c, owners, bind, _ := demandFixture(t)
	// Five owners exist; the ceiling was lowered to four, with a full warm
	// buffer, so only the owner above the ceiling may be withdrawn.
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 4, Idle: 4}}
	starts, err := c.DemandStarts(context.Background(), pools, map[string]int{buildPool: 0}, bind)
	if err != nil || len(starts[buildPool]) != 0 {
		t.Fatal(starts, err)
	}
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture owner differs")
	}
	for id, owner := range owners {
		surplus := strings.HasSuffix(docker.containers[id].Name, "-5")
		if owner.frozen != surplus {
			t.Fatalf("%s frozen=%v surplus=%v", docker.containers[id].Name, owner.frozen, surplus)
		}
	}
}

func TestDemandBusyOwnerAboveLoweredCeilingCountsAgainstIt(t *testing.T) {
	c, owners, bind, _ := demandFixture(t)
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture owner differs")
	}
	for id, item := range docker.containers {
		switch {
		case strings.HasSuffix(item.Name, "-5"):
			owners[id].busy = true
		case strings.HasSuffix(item.Name, "-4"):
			delete(docker.containers, id)
			owned, err := c.load(item.Name)
			if err != nil {
				t.Fatal(err)
			}
			if checkErr := c.Broker.Release(&c.Policy, "build:"+item.Name, owned.Fence, func(sharedcapacity.Grant) error { return nil }); checkErr != nil {
				t.Fatal(checkErr)
			}
		}
	}
	// Slot 4 is free, but the busy owner above the ceiling already fills it.
	pools := []DemandPool{{ID: buildPool, Minimum: 3, Maximum: 4}}
	starts, err := c.DemandStarts(context.Background(), pools, map[string]int{buildPool: 999}, bind)
	if err != nil || len(starts[buildPool]) != 0 {
		t.Fatal(starts, err)
	}
	for _, owner := range owners {
		if owner.busy && owner.frozen {
			t.Fatal("busy surplus owner frozen")
		}
	}
}

func TestDemandSparseBusyOwnerDoesNotImposeIndexFloor(t *testing.T) {
	c, owners, bind, _ := demandFixture(t)
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture owner differs")
	}
	for id, item := range docker.containers {
		if strings.HasSuffix(item.Name, "-5") {
			owners[id].busy = true
			continue
		}
		delete(docker.containers, id)
		owned, err := c.load(item.Name)
		if err != nil {
			t.Fatal(err)
		}
		if checkErr := c.Broker.Release(&c.Policy, "build:"+item.Name, owned.Fence, func(sharedcapacity.Grant) error { return nil }); checkErr != nil {
			t.Fatal(checkErr)
		}
	}
	starts, err := c.DemandStarts(context.Background(), []DemandPool{{ID: buildPool, Minimum: 2, Maximum: 8}}, map[string]int{buildPool: 999}, bind)
	if err != nil || !slices.Equal(starts[buildPool], []int{1}) {
		t.Fatal(starts, err)
	}
	for _, owner := range owners {
		if owner.busy && owner.frozen {
			t.Fatal("busy high index frozen")
		}
	}
}

func TestDemandZeroSpecializedAndUnknownOwnersStayCharged(t *testing.T) {
	c, owners, bind, _ := demandFixture(t)
	for _, owner := range owners {
		owner.unknown = true
	}
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8}, {ID: smallClassPool, Maximum: 8}, {ID: largeClassForRoutingTest, Maximum: 8}}
	starts, err := c.DemandStarts(context.Background(), pools, map[string]int{buildPool: 0, smallClassPool: 0, largeClassForRoutingTest: 0}, bind)
	if err != nil || len(starts[buildPool]) != 0 || len(starts[smallClassPool]) != 0 || len(starts[largeClassForRoutingTest]) != 0 {
		t.Fatal(starts, err)
	}
	for _, owner := range owners {
		if owner.frozen {
			t.Fatal("unknown owner frozen")
		}
	}
	starts, err = c.DemandStarts(context.Background(), pools, map[string]int{buildPool: 0, smallClassPool: 100, largeClassForRoutingTest: 100}, bind)
	if err != nil || !slices.Equal(starts[smallClassPool], []int{1}) || !slices.Equal(starts[largeClassForRoutingTest], []int{1}) {
		t.Fatal(starts, err)
	}
	if _, err = c.DemandStarts(context.Background(), pools, map[string]int{buildPool: 0}, bind); err == nil {
		t.Fatal("partial snapshot accepted")
	}
}

func TestDemandPickupRaceCannotRemoveOwner(t *testing.T) {
	c, owners, bind, _ := demandFixture(t)
	calls := 0
	racing := func(ctx context.Context, name, id string, rid int64, rname string) (OwnerBinding, error) {
		binding, err := bind(ctx, name, id, rid, rname)
		calls++
		if calls == 5 {
			binding.Owner = &pickupPlanningOwner{fakePlanningOwner: owners[id]}
		}
		return binding, err
	}
	_, err := c.DemandStarts(context.Background(), []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8}}, map[string]int{buildPool: 0}, racing)
	if err != nil {
		t.Fatal(err)
	}
	for _, owner := range owners {
		if owner.busy && (owner.frozen || owner.gone) {
			t.Fatal("pickup race removed worker")
		}
	}
}

type pickupPlanningOwner struct{ *fakePlanningOwner }

func (o *pickupPlanningOwner) FrozenIdle(context.Context) (bool, error) {
	o.busy = true
	return false, nil
}

func TestDemandParseProtectsFloorAndPolicyCeiling(t *testing.T) {
	c, _, _, _ := demandFixture(t)
	text := "v3|build|os-build|unraid,build|5|4|8|0|1|12g|builtin;v3|build-small|build-small|self-hosted,linux,x64|1|0|8|0|1|4g|builtin"
	pools, err := ParseDemandPools(text, &c.Policy)
	if err != nil || len(pools) != 2 || pools[0].ID != smallClassPool {
		t.Fatal(pools, err)
	}
	for _, invalid := range []string{strings.Replace(text, "|4|8|", "|3|8|", 1), strings.Replace(text, "|0|8|", "|0|9|", 1)} {
		if _, err := ParseDemandPools(invalid, &c.Policy); err == nil {
			t.Fatal("unsafe pool accepted")
		}
	}
}

func TestDemandCancellationRecoversRemoval(t *testing.T) {
	c, _, _, now := pressureFixture(t)
	d, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture owner differs")
	}
	id := strings.Repeat("e", 64)
	name := demandSlotName(buildPool, 6)
	d.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix()}
	if err := c.Start(context.Background(), name, id); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	owned, err := c.load(name)
	if err != nil {
		t.Fatal(err)
	}
	owned.ReleasePending = true
	if checkErr := c.save(name, owned); checkErr != nil {
		t.Fatal(checkErr)
	}
	if checkErr := c.PrepareQueuedReplacement(context.Background(), name, id); checkErr != nil {
		t.Fatal(checkErr)
	}
	if _, inspectErr := d.Inspect(context.Background(), id); !errors.Is(inspectErr, ErrContainerMissing) {
		t.Fatal("owner remains")
	}
	if checkErr := c.recoverReleasedOwners(context.Background(), &before, nil); checkErr != nil {
		t.Fatal(checkErr)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := after.Pending["build:"+name]; exists {
		t.Fatal("stale demand remains")
	}
}

func TestDemandExistingLargeReachesZeroAfterSettlement(t *testing.T) {
	c, d, id := fixture(t)
	item := d.containers[id]
	item.Name = demandSlotName(largeClassForRoutingTest, 1)
	item.Pool = largeClassForRoutingTest
	now := time.Now().UTC()
	c.Broker.Now = func() time.Time { return now }
	if checkErr := c.Start(context.Background(), item.Name, id); checkErr != nil {
		t.Fatal(checkErr)
	}
	owner := &fakePlanningOwner{docker: d, id: id}
	bind := func(_ context.Context, name, _ string, _ int64, _ string) (OwnerBinding, error) {
		return OwnerBinding{Owner: owner, RunnerID: 123, RunnerName: name}, nil
	}
	starts, err := c.DemandStarts(context.Background(), []DemandPool{{ID: largeClassForRoutingTest, Maximum: 1}}, map[string]int{largeClassForRoutingTest: 0}, bind)
	if err != nil || len(starts[largeClassForRoutingTest]) != 0 || !owner.frozen {
		t.Fatal(starts, err)
	}
	now = now.Add(80 * time.Second)
	if checkErr := c.Rebalance(context.Background(), bind); checkErr != nil {
		t.Fatal(checkErr)
	}
	status, err := c.Broker.Status(&c.Policy)
	if err != nil || len(status.Grants) != 0 || len(d.containers) != 0 {
		t.Fatal(status, err)
	}
}

func TestDemandRestoresDesignatedFloorAlongsideSparseBusySlot(t *testing.T) {
	c, owners, bind, _ := demandFixture(t)
	d, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture owner differs")
	}
	for id, item := range d.containers {
		if strings.HasSuffix(item.Name, "-5") {
			owners[id].busy = true
			continue
		}
		owned, err := c.load(item.Name)
		if err != nil {
			t.Fatal(err)
		}
		delete(d.containers, id)
		if releaseErr := c.Broker.Release(&c.Policy, "build:"+item.Name, owned.Fence, func(sharedcapacity.Grant) error { return nil }); releaseErr != nil {
			t.Fatal(releaseErr)
		}
	}
	policy := c.Policy.Pools[buildPool]
	policy.Minimum = 2
	policy.MinimumRequestIDs = []string{"build:ci-runner-build-1", "build:ci-runner-build-2"}
	c.Policy.Pools[buildPool] = policy
	starts, err := c.DemandStarts(context.Background(), []DemandPool{{ID: buildPool, Minimum: 2, Maximum: 8}}, map[string]int{buildPool: 0}, bind)
	if err != nil || !slices.Equal(starts[buildPool], []int{1, 2}) {
		t.Fatal(starts, err)
	}
}

func TestDemandRecoversInertCreateBeforeReceipt(t *testing.T) {
	for _, queued := range []int{0, 1} {
		c, d, id := fixture(t)
		item := d.containers[id]
		item.Name = demandSlotName(largeClassForRoutingTest, 1)
		item.Pool = largeClassForRoutingTest
		item.NeverStarted = true
		item.RoutingGated = true
		starts, err := c.DemandStarts(context.Background(), []DemandPool{{ID: largeClassForRoutingTest, Maximum: 1}}, map[string]int{largeClassForRoutingTest: queued}, nil)
		if err != nil {
			t.Fatal(err)
		}
		if queued == 0 && len(d.containers) != 0 {
			t.Fatal("unneeded inert owner remained")
		}
		if queued == 1 && !slices.Equal(starts[largeClassForRoutingTest], []int{1}) {
			t.Fatal(starts)
		}
	}
}

func TestDemandCancellationRecoversAfterBrokerCancelBeforeReceiptRemoval(t *testing.T) {
	c, d, id := fixture(t)
	item := d.containers[id]
	item.NeverStarted = true
	item.RoutingGated = true
	owned := &receipt{ID: id, ReleasePending: true, ReplacementPrepared: true}
	if err := c.save(testName, owned); err != nil {
		t.Fatal(err)
	}
	delete(d.containers, id)
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if recoveryErr := c.recoverReleasedOwners(context.Background(), &snapshot, nil); recoveryErr != nil {
		t.Fatal(recoveryErr)
	}
	if _, loadErr := c.load(testName); !errors.Is(loadErr, os.ErrNotExist) {
		t.Fatal("completed cancellation receipt remained", loadErr)
	}
}
