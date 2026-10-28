// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestIdleConfigurationReplacementPreservesFloorUntilFencedRemoval(t *testing.T) {
	c, owners, bind, now := pressureFixtureCount(t, 4)
	id := strings.Repeat("1", 64)
	other := strings.Repeat("2", 64)
	owners[id].docker.containers[id].DockerRoot = "/mnt/cache/ci-runner-farm/docker/ci-runner-build-1"
	c.RepairCache = func(context.Context, string, string) error {
		t.Fatal("healthy warm cache was cleared during config replacement")
		return nil
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.ReconcileIdle(context.Background(), "ci-runner-build-1", id, bind); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	held, _ := c.Broker.Status(&c.Policy)
	if held.Grants["build:ci-runner-build-1"] != before.Grants["build:ci-runner-build-1"] {
		t.Fatal("settling owner lost charge")
	}
	*now = now.Add(80 * time.Second)
	if err := c.Rebalance(context.Background(), bind); err != nil {
		t.Fatal(err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if !owners[id].gone || owners[id].docker.containers[id] != nil {
		t.Fatal("idle old owner survived reconciliation")
	}
	if owners[other].gone || after.Grants["build:ci-runner-build-2"] != before.Grants["build:ci-runner-build-2"] {
		t.Fatal("another owner changed")
	}
	if _, ok := after.Grants["build:ci-runner-build-1"]; ok {
		t.Fatal("removed owner remained charged")
	}
	if len(after.Pending) != len(before.Pending) || after.Pending[testPriorityDemand] != before.Pending[testPriorityDemand] {
		t.Fatal("pending age or identity changed")
	}
}

func TestIdleConfigurationReplacementRetainsBusyUnknownAndChangedOwners(t *testing.T) {
	for _, mode := range []string{"busy", "unknown", "changed", "binding"} {
		t.Run(mode, func(t *testing.T) {
			c, owners, bind, _ := pressureFixtureCount(t, 4)
			id := strings.Repeat("1", 64)
			target := id
			switch mode {
			case "busy":
				owners[id].busy = true
			case "unknown":
				owners[id].unknown = true
			case "changed":
				target = strings.Repeat("f", 64)
			case "binding":
				bind = func(context.Context, string, string, int64, string) (OwnerBinding, error) {
					return OwnerBinding{}, errors.New("unavailable")
				}
			}
			before, _ := c.Broker.Status(&c.Policy)
			if err := c.ReconcileIdle(context.Background(), "ci-runner-build-1", target, bind); err == nil {
				t.Fatal("unsafe reconciliation succeeded")
			}
			after, _ := c.Broker.Status(&c.Policy)
			owned, err := c.load("ci-runner-build-1")
			if err != nil || owned.Maintenance || owned.Withdrawal != nil || owners[id].frozen || owners[id].gone || after.Grants["build:ci-runner-build-1"] != before.Grants["build:ci-runner-build-1"] {
				t.Fatal("unsafe owner or grant changed")
			}
		})
	}
}

type configurationPickupOwner struct{ *fakePlanningOwner }

func (o *configurationPickupOwner) Freeze(ctx context.Context) error {
	o.busy = true
	return o.fakePlanningOwner.Freeze(ctx)
}

func TestIdleConfigurationReplacementBusyRaceRetainsGrantAndRecovers(t *testing.T) {
	c, owners, bind, now := pressureFixtureCount(t, 4)
	id := strings.Repeat("1", 64)
	original := bind
	bind = func(ctx context.Context, name, cid string, rid int64, rname string) (OwnerBinding, error) {
		b, err := original(ctx, name, cid, rid, rname)
		if cid == id {
			b.Owner = &configurationPickupOwner{owners[id]}
		}
		return b, err
	}
	before, _ := c.Broker.Status(&c.Policy)
	err := c.ReconcileIdle(context.Background(), "ci-runner-build-1", id, bind)
	if !errors.Is(err, sharedcapacity.ErrWorkloadBusy) || owners[id].frozen || owners[id].gone {
		t.Fatalf("pickup race was not resumed: %v", err)
	}
	after, _ := c.Broker.Status(&c.Policy)
	if after.Grants["build:ci-runner-build-1"] != before.Grants["build:ci-runner-build-1"] {
		t.Fatal("busy race released allocation")
	}
	owners[id].busy = false
	if err := c.Rebalance(context.Background(), original); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	*now = now.Add(80 * time.Second)
	if err := c.Rebalance(context.Background(), original); err != nil {
		t.Fatal(err)
	}
	if !owners[id].gone {
		t.Fatal("persisted maintenance did not recover")
	}
}

func TestIdleConfigurationReplacementDoesNotStackUnsettledOwners(t *testing.T) {
	c, owners, bind, _ := pressureFixtureCount(t, 4)
	id := strings.Repeat("1", 64)
	other, err := c.load("ci-runner-build-2")
	if err != nil {
		t.Fatal(err)
	}
	other.Maintenance = true
	if err := c.save("ci-runner-build-2", other); err != nil {
		t.Fatal(err)
	}
	if err := c.ReconcileIdle(context.Background(), "ci-runner-build-1", id, bind); !errors.Is(err, ErrQueued) {
		t.Fatal("unsettled maintenance permitted another replacement", err)
	}
	target, err := c.load("ci-runner-build-1")
	if err != nil || target.Maintenance || owners[id].frozen || owners[id].gone {
		t.Fatal("another in-flight maintenance changed target")
	}
}

func TestIdleConfigurationReplacementRepairsNewlyPoisonedCache(t *testing.T) {
	c, owners, bind, now := pressureFixtureCount(t, 4)
	id := strings.Repeat("1", 64)
	owners[id].docker.containers[id].DockerRoot = "/mnt/cache/ci-runner-farm/docker/ci-runner-build-1"
	poisoned := false
	c.Poisoned = func(name string, _ string) (bool, error) { return name == "ci-runner-build-1" && poisoned, nil }
	repairs := 0
	c.RepairCache = func(context.Context, string, string) error { repairs++; return nil }
	if err := c.ReconcileIdle(context.Background(), "ci-runner-build-1", id, bind); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	owned, err := c.load("ci-runner-build-1")
	if err != nil || !owned.PreserveCache {
		t.Fatal("warm cache intent was not persisted")
	}
	poisoned = true
	*now = now.Add(80 * time.Second)
	if err := c.Rebalance(context.Background(), bind); err != nil {
		t.Fatal(err)
	}
	if repairs != 1 {
		t.Fatal("late poison evidence did not repair cache")
	}
}

func TestIdleConfigurationReplacementPreservesExistingPoisonIntent(t *testing.T) {
	c, owners, bind, _ := pressureFixtureCount(t, 4)
	id := strings.Repeat("1", 64)
	owned, err := c.load("ci-runner-build-1")
	if err != nil {
		t.Fatal(err)
	}
	owned.Maintenance = true
	if err := c.save("ci-runner-build-1", owned); err != nil {
		t.Fatal(err)
	}
	if err := c.ReconcileIdle(context.Background(), "ci-runner-build-1", id, bind); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	owned, err = c.load("ci-runner-build-1")
	if err != nil || owned.PreserveCache || !owned.Maintenance || owners[id].frozen || owners[id].gone {
		t.Fatal("existing poison maintenance intent changed")
	}
}
