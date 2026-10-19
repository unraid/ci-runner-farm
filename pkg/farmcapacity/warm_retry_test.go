package farmcapacity

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// warmRetryFixture leaves four running build owners and one inert owner whose
// pending request became the admissible queue head after a grant was released,
// as happens when pre-restart owners settle after Docker restarts.
func warmRetryFixture(t *testing.T) (*Controller, *fakeDocker, string) {
	t.Helper()
	c, _, _, now := demandFixture(t)
	canonicalWarmTestPath(t, c)
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker differs")
	}
	name := demandSlotName(buildPool, 6)
	id := fmt.Sprintf("%064x", 106)
	docker.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix()}
	if err := c.save(name, &receipt{ID: id}); err != nil {
		t.Fatal(err)
	}
	// The physical budget is full, so the request waits with its age.
	decision, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: "build:" + name, Pool: buildPool})
	if err != nil || decision.Admitted {
		t.Fatal(decision, err)
	}
	for running, item := range docker.containers {
		if !strings.HasSuffix(item.Name, "-5") {
			continue
		}
		owned, loadErr := c.load(item.Name)
		if loadErr != nil {
			t.Fatal(loadErr)
		}
		delete(docker.containers, running)
		if releaseErr := c.Broker.Release(&c.Policy, "build:"+item.Name, owned.Fence, func(sharedcapacity.Grant) error { return nil }); releaseErr != nil {
			t.Fatal(releaseErr)
		}
	}
	diagnostic, err := c.Broker.Diagnose(&c.Policy)
	if err != nil || diagnostic.QueueHead != "build:"+name {
		t.Fatal("inert owner is not the queue head", diagnostic.QueueHead, err)
	}
	return c, docker, id
}

func TestWarmRecoveryRetriesAdmissibleQueueHeadAboveWarmTarget(t *testing.T) {
	c, docker, id := warmRetryFixture(t)
	// Four running owners already satisfy the warm target. The queued head
	// must still be handed back to native admission on every warm pass.
	starts, err := c.WarmStarts(t.Context(), []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8, Idle: 4}}, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 4}})
	if err != nil || !slices.Equal(starts[buildPool], []int{6}) {
		t.Fatal("admissible queue head was not retried", starts, err)
	}
	if err := c.Start(t.Context(), demandSlotName(buildPool, 6), id); err != nil {
		t.Fatal(err)
	}
	if !docker.containers[id].Running {
		t.Fatal("queue head did not start")
	}
}

func TestWarmRecoveryDoesNotRetryNonHeadQueuedOwnersAboveWarmTarget(t *testing.T) {
	c, docker, _ := warmRetryFixture(t)
	now := c.now()
	name := demandSlotName(buildPool, 7)
	id := fmt.Sprintf("%064x", 107)
	docker.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix()}
	if err := c.save(name, &receipt{ID: id}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: "build:" + name, Pool: buildPool}); err != nil {
		t.Fatal(err)
	}
	// Only the head can be admitted next; later owners keep their age and wait.
	starts, err := c.WarmStarts(t.Context(), []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8, Idle: 4}}, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 4}})
	if err != nil || !slices.Equal(starts[buildPool], []int{6}) {
		t.Fatal("warm retry exceeded the queue head", starts, err)
	}
}

func TestWarmRecoveryRetriesGrantedOwnerThatNeverStarted(t *testing.T) {
	c, _, _, _ := demandFixture(t)
	canonicalWarmTestPath(t, c)
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker differs")
	}
	var id string
	for candidate, item := range docker.containers {
		if strings.HasSuffix(item.Name, "-5") {
			id = candidate
		}
	}
	// A charged start whose Docker start failed before a Docker restart stays
	// Created. Its grant and start reservation remain until it is retried.
	item := docker.containers[id]
	item.Running, item.NeverStarted, item.RoutingGated, item.RegistrationIssuedAt = false, true, true, c.now().Unix()
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8, Idle: 4}}
	starts, err := c.WarmStarts(t.Context(), pools, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 4}})
	if err != nil || !slices.Equal(starts[buildPool], []int{5}) {
		t.Fatal("granted never-started owner was not retried", starts, err)
	}
	// The retried owner already counts toward the warm total.
	pools[0].Idle = 6
	starts, err = c.WarmStarts(t.Context(), pools, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 6}})
	if err != nil || !slices.Equal(starts[buildPool], []int{5, 6}) {
		t.Fatal("granted retry was not counted toward the warm target", starts, err)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Start(t.Context(), item.Name, id); err != nil || !item.Running {
		t.Fatal("granted owner did not start on retry", err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || after.Grants["build:"+item.Name].Fence != before.Grants["build:"+item.Name].Fence {
		t.Fatal("retry changed the existing grant", err)
	}
}
