package farmcapacity

import (
	"errors"
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

// grantedNeverStartedFixture leaves slot 5 as a charged owner whose Docker start
// failed before a Docker restart: it stays Created with its grant and start
// reservation until it is retried.
func grantedNeverStartedFixture(t *testing.T) (*Controller, *fakeDocker, *Container, string) {
	t.Helper()
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
	item := docker.containers[id]
	item.Running, item.NeverStarted, item.RoutingGated, item.RegistrationIssuedAt = false, true, true, c.now().Unix()
	return c, docker, item, id
}

func TestWarmRecoveryRetriesGrantedOwnerThatNeverStarted(t *testing.T) {
	c, _, item, id := grantedNeverStartedFixture(t)
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

func TestRetainedGrantStartFailureDefersWithoutLosingGrant(t *testing.T) {
	c, docker, item, id := grantedNeverStartedFixture(t)
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	// A start whose outcome cannot be re-attested must defer like a queued
	// start instead of failing the tick, while keeping its grant for a retry.
	docker.startErr = errors.New("bind source path does not exist")
	docker.onFailedStart = func() { docker.inspectErr = errors.New("daemon unavailable") }
	err = c.Start(t.Context(), item.Name, id)
	if !errors.Is(err, ErrQueued) || !strings.Contains(err.Error(), "bind source path does not exist") {
		t.Fatal("retained grant start failure was not deferred with its cause", err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || after.Grants["build:"+item.Name].Fence != before.Grants["build:"+item.Name].Fence || docker.containers[id] == nil {
		t.Fatal("deferred start changed the retained grant or owner", err)
	}
	docker.startErr, docker.inspectErr = nil, nil
	if err := c.Start(t.Context(), item.Name, id); err != nil || !item.Running {
		t.Fatal("deferred owner did not start once Docker recovered", err)
	}
}

func TestFreshAdmissionStartFailureIsNotDeferred(t *testing.T) {
	c, docker, id := warmRetryFixture(t)
	// Only an owner that already held its grant is deferred; an unproved start
	// failure right after a new admission keeps failing the tick as before.
	docker.startErr = errors.New("unknown Docker start outcome")
	docker.onFailedStart = func() { docker.inspectErr = errors.New("daemon unavailable") }
	err := c.Start(t.Context(), demandSlotName(buildPool, 6), id)
	if err == nil || errors.Is(err, ErrQueued) || errors.Is(err, ErrStartReplaced) {
		t.Fatal("fresh admission start failure was deferred", err)
	}
}

func TestWarmRecoveryDoesNotRetryGrantedOwnersUnderRecovery(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*receipt, *Container)
	}{
		{"release pending", func(r *receipt, _ *Container) { r.ReleasePending = true }},
		{"retiring", func(r *receipt, _ *Container) { r.Retiring = true }},
		{"withdrawing", func(r *receipt, _ *Container) { r.Withdrawal = &sharedcapacity.Withdrawal{Phase: "prepared"} }},
		{"paused", func(_ *receipt, item *Container) { item.Paused = true }},
		{"fence differs from grant", func(r *receipt, _ *Container) { r.Fence = "stale-fence" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, _, item, _ := grantedNeverStartedFixture(t)
			owned, err := c.load(item.Name)
			if err != nil || owned == nil {
				t.Fatal("granted receipt missing", err)
			}
			tc.mutate(owned, item)
			if err := c.save(item.Name, owned); err != nil {
				t.Fatal(err)
			}
			starts, err := c.WarmStarts(t.Context(), []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8, Idle: 4}}, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 4}})
			if err != nil || slices.Contains(starts[buildPool], 5) {
				t.Fatal("granted owner under recovery was retried", starts, err)
			}
		})
	}
}
