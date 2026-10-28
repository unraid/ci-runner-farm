// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"maps"
	"strings"
	"testing"
)

func TestQueuedDefaultCPUUpgradeUsesFencedRefreshAndKeepsAge(t *testing.T) {
	c, owners, _, now := pressureFixture(t)
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker owner differs")
	}
	id, name := strings.Repeat("e", 64), queuedBuilderSix
	docker.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix()}
	ctx := context.Background()
	if err := c.Start(ctx, name, id); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	previous := c.Policy
	c.Policy.Budget.VCPUs = 28
	c.Policy.Pools = maps.Clone(previous.Pools)
	pool := c.Policy.Pools[buildPool]
	pool.Cost.VCPUs = 4
	c.Policy.Pools[buildPool] = pool
	if err = c.Broker.ReconcilePolicy(&previous, &c.Policy); err != nil {
		t.Fatal(err)
	}
	inventory, err := c.Inventory(ctx)
	if err != nil {
		t.Fatal(err)
	}
	requests, err := c.AdoptionRequests(inventory)
	if err != nil {
		t.Fatal(err)
	}
	if err = c.Broker.Adopt(&c.Policy, requests, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	if err = c.Start(ctx, name, id); !errors.Is(err, ErrCredentialsExpired) {
		t.Fatal("old inert CPU allocation must refresh", err)
	}
	if err = c.PrepareQueuedReplacement(ctx, name, id); err != nil {
		t.Fatal(err)
	}
	replacement := strings.Repeat("f", 64)
	docker.containers[replacement] = &Container{ID: replacement, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 4_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix()}
	if err = c.Start(ctx, name, replacement); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || before.Pending["build:"+name].QueuedAt != after.Pending["build:"+name].QueuedAt {
		t.Fatal("CPU refresh changed retry age", err)
	}
	if len(after.Grants) != len(owners) || docker.starts != len(owners) {
		t.Fatal("CPU refresh started or resized a charged owner")
	}
}
