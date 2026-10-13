// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"maps"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const (
	smallClassName = "ci-runner-build-small-1"
	smallClassPool = "build-small"
)

func TestSmallBuildClassChargesExactHardLimitsAndReleases(t *testing.T) {
	c, d, id := fixture(t)
	name := smallClassName
	item := d.containers[id]
	item.Name = name
	item.Pool = smallClassPool
	item.MemoryBytes = 4096 * 1024 * 1024
	if checkErr := c.Start(context.Background(), name, id); checkErr != nil {
		t.Fatal(checkErr)
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	grant := snapshot.Grants["build:"+name]
	if grant.Cost.MemoryMiB != 4096 || grant.Cost.VCPUs != 1 {
		t.Fatalf("actual build limits not charged: %+v", grant.Cost)
	}
	delete(d.containers, id)
	if checkErr := c.Release(context.Background(), name, id); checkErr != nil {
		t.Fatal(checkErr)
	}
}

func TestLargeBuildQueuesAndPreservesExactSizeAcrossRetryAndRelease(t *testing.T) {
	c, d, id := fixture(t)
	previous := c.Policy
	previous.Pools = maps.Clone(c.Policy.Pools)
	pool := c.Policy.Pools[buildPool]
	pool.MaxCost = sharedcapacity.Resources{MemoryMiB: 16384, VCPUs: 4}
	c.Policy.Pools[buildPool] = pool
	c.Policy.Budget = sharedcapacity.Resources{MemoryMiB: 16384, VCPUs: 4}
	if checkErr := c.Broker.ReconcilePolicy(&previous, &c.Policy); checkErr != nil {
		t.Fatal(checkErr)
	}
	name := "ci-runner-build-large-1"
	item := d.containers[id]
	item.Name = name
	item.Pool = largeClassForRoutingTest
	item.MemoryBytes = 16384 * 1024 * 1024
	item.NanoCPUs = 4_000_000_000
	blocker, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: "blocker", Pool: buildPool})
	if err != nil || !blocker.Admitted {
		t.Fatal(err)
	}
	if checkErr := c.Start(context.Background(), name, id); !errors.Is(checkErr, ErrQueued) {
		t.Fatalf("large request not queued: %v", checkErr)
	}
	first, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if checkErr := c.Start(context.Background(), name, id); !errors.Is(checkErr, ErrQueued) {
		t.Fatal(checkErr)
	}
	second, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if first.Pending["build:"+name] != second.Pending["build:"+name] || first.Pending["build:"+name].Resources.MemoryMiB != 16384 {
		t.Fatal("queued size or age changed")
	}
	if checkErr := c.Broker.Release(&c.Policy, "blocker", blocker.Grant.Fence, func(sharedcapacity.Grant) error { return nil }); checkErr != nil {
		t.Fatal(checkErr)
	}
	if checkErr := c.Start(context.Background(), name, id); checkErr != nil {
		t.Fatal(checkErr)
	}
	adopted, err := c.AdoptionRequests([]Container{*item})
	if err != nil {
		t.Fatal(err)
	}
	if checkErr := c.Broker.Adopt(&c.Policy, adopted, func() error { return nil }); checkErr != nil {
		t.Fatal(checkErr)
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	grant := snapshot.Grants["build:"+name]
	if grant.Cost.VCPUs != 4 || grant.Cost.MemoryMiB != 16384 {
		t.Fatal("large charge differs")
	}
	item.MemoryBytes = 4096 * 1024 * 1024
	if checkErr := c.Start(context.Background(), name, id); checkErr == nil {
		t.Fatal("running limits drift reused a grant")
	}
	if _, checkErr := c.AdoptionRequests([]Container{*item}); checkErr == nil {
		t.Fatal("adoption accepted running resource drift")
	}
	item.MemoryBytes = 16384 * 1024 * 1024
	delete(d.containers, id)
	if checkErr := c.Release(context.Background(), name, id); checkErr != nil {
		t.Fatal(checkErr)
	}
}

func TestQueuedSmallBuildCancellationUsesExactRequest(t *testing.T) {
	c, d, id := fixture(t)
	previous := c.Policy
	previous.Pools = maps.Clone(c.Policy.Pools)
	pool := c.Policy.Pools[buildPool]
	pool.Maximum = 2
	c.Policy.Pools[buildPool] = pool
	if checkErr := c.Broker.ReconcilePolicy(&previous, &c.Policy); checkErr != nil {
		t.Fatal(checkErr)
	}
	if _, checkErr := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: "busy", Pool: buildPool}); checkErr != nil {
		t.Fatal(checkErr)
	}
	name := smallClassName
	item := d.containers[id]
	item.Name = name
	item.Pool = smallClassPool
	item.MemoryBytes = 4096 * 1024 * 1024
	if checkErr := c.Start(context.Background(), name, id); !errors.Is(checkErr, ErrQueued) {
		t.Fatal(checkErr)
	}
	delete(d.containers, id)
	if checkErr := c.Release(context.Background(), name, id); checkErr != nil {
		t.Fatal(checkErr)
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Pending) != 0 {
		t.Fatal("exact queued request not canceled", err)
	}
}

func TestBuildClassIdentityAndUnboundedLimitsRejectBeforeStart(t *testing.T) {
	for _, mode := range []string{"foreign-slot", "pool", "unlimited", "fractional", "oversize"} {
		t.Run(mode, func(t *testing.T) {
			c, d, id := fixture(t)
			item := d.containers[id]
			item.Name = smallClassName
			item.Pool = smallClassPool
			switch mode {
			case "foreign-slot":
				item.Name = "ci-runner-other-1"
			case "pool":
				item.Pool = largeClassForRoutingTest
			case "unlimited":
				item.MemoryBytes = 0
			case "fractional":
				item.NanoCPUs = 500_000_000
			case "oversize":
				item.MemoryBytes = 32768 * 1024 * 1024
			}
			if checkErr := c.Start(context.Background(), item.Name, id); checkErr == nil {
				t.Fatal("invalid owner started")
			}
			if d.starts != 0 {
				t.Fatal("Docker start reached")
			}
		})
	}
}

func TestVariableBuildDefaultGrantSurvivesPolicyEnvelopeGrowth(t *testing.T) {
	c, d, id := fixture(t)
	if checkErr := c.Start(context.Background(), testName, id); checkErr != nil {
		t.Fatal(checkErr)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	previous := c.Policy
	previous.Pools = maps.Clone(c.Policy.Pools)
	pool := c.Policy.Pools[buildPool]
	pool.MaxCost = sharedcapacity.Resources{MemoryMiB: 16384, VCPUs: 4}
	c.Policy.Pools[buildPool] = pool
	c.Policy.Budget = pool.MaxCost
	if checkErr := c.Broker.ReconcilePolicy(&previous, &c.Policy); checkErr != nil {
		t.Fatal(checkErr)
	}
	requests, err := c.AdoptionRequests([]Container{*d.containers[id]})
	if err != nil {
		t.Fatal(err)
	}
	if checkErr := c.Broker.Adopt(&c.Policy, requests, func() error { return nil }); checkErr != nil {
		t.Fatal(checkErr)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || before.Grants["build:"+testName] != after.Grants["build:"+testName] {
		t.Fatal("default live allocation changed", err)
	}
	if checkErr := c.Start(context.Background(), testName, id); checkErr != nil {
		t.Fatal(checkErr)
	}
}
