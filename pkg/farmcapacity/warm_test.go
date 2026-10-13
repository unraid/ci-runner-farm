package farmcapacity

import (
	"errors"
	"fmt"
	"maps"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestWarmRecoveryIsAdditiveAndDoesNotNeedRemoteOwnerEvidence(t *testing.T) {
	c, owners, _, _ := demandFixture(t)
	canonicalWarmTestPath(t, c)
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	for _, owner := range owners {
		owner.unknown = true
	}
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8, Idle: 8}}
	starts, err := c.WarmStarts(t.Context(), pools, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 8}})
	if err != nil || !slices.Equal(starts[buildPool], []int{6, 7, 8}) {
		t.Fatal(starts, err)
	}
	// Lower warm totals retain even positively idle excesses. Unknown queue
	// evidence never authorizes retirement, cancellation or repeated expansion.
	pools[0].Idle = 4
	starts, err = c.WarmStarts(t.Context(), pools, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 4}})
	if err != nil || len(starts[buildPool]) != 0 {
		t.Fatal(starts, err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("warm planning changed charges, fences or pending intent", err)
	}
	for _, owner := range owners {
		if owner.frozen || owner.gone {
			t.Fatal("warm recovery retired an owner")
		}
	}
}

func TestWarmRecoverySelectsOldPendingBeforeNewIndicesWithoutResettingAge(t *testing.T) {
	c, _, _, now := demandFixture(t)
	canonicalWarmTestPath(t, c)
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker differs")
	}
	for _, index := range []int{8, 6} {
		name := demandSlotName(buildPool, index)
		id := fmt.Sprintf("%064x", index+100)
		docker.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true}
		if err := c.save(name, &receipt{ID: id}); err != nil {
			t.Fatal(err)
		}
		// Fill the physical budget so both exact requests remain pending.
		decision, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: "build:" + name, Pool: buildPool})
		if err != nil || decision.Admitted {
			t.Fatal(decision, err)
		}
		*now = now.Add(2 * time.Minute)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	starts, err := c.WarmStarts(t.Context(), []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8, Idle: 6}}, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 6}})
	if err != nil || !slices.Equal(starts[buildPool], []int{8}) {
		t.Fatal("old pending owner was bypassed", starts, err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("pending age or owner changed", err)
	}
}

func TestWarmRecoveryRejectsUnprotectedTargetsAndKeepsNativeAdmission(t *testing.T) {
	c, docker, id := fixture(t)
	canonicalWarmTestPath(t, c)
	docker.containers[id].NeverStarted = true
	docker.containers[id].RoutingGated = true
	docker.containers[id].RegistrationIssuedAt = time.Now().Unix()
	policy := c.Policy
	policy.BuildMemoryOvercommit = &sharedcapacity.BuildMemoryOvercommit{AdditionalMiB: 12288, MinimumAvailableMiB: 8192}
	if err := c.Broker.ReconcilePolicy(&c.Policy, &policy); err != nil {
		t.Fatal(err)
	}
	c.Policy = policy
	c.Broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: 1, ObservedAt: time.Now()}, nil
	}
	pools := []DemandPool{{ID: buildPool, Maximum: 1, Idle: 1}}
	for _, request := range []*WarmTargets{nil, {Schema: 2, Targets: map[string]int{buildPool: 1}}, {Schema: 1, Targets: map[string]int{buildPool: 0}}, {Schema: 1, Targets: map[string]int{buildPool: 2}}, {Schema: 1, Targets: map[string]int{"other": 1}}} {
		if _, err := c.WarmStarts(t.Context(), pools, request); err == nil {
			t.Fatal("unsafe warm target accepted")
		}
	}
	starts, err := c.WarmStarts(t.Context(), pools, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 1}})
	if err != nil || !slices.Equal(starts[buildPool], []int{1}) {
		t.Fatal(starts, err)
	}
	if err := c.Start(t.Context(), testName, id); !errors.Is(err, ErrQueued) || docker.starts != 0 {
		t.Fatal("warm start bypassed measured memory admission", err)
	}
}

func TestWarmRecoveryRestoresPhysicalFloorAlongsideSparseBusyOwner(t *testing.T) {
	c, owners, _, _ := demandFixture(t)
	canonicalWarmTestPath(t, c)
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker differs")
	}
	for id, item := range docker.containers {
		if strings.HasSuffix(item.Name, "-5") {
			owners[id].busy = true
			continue
		}
		owned, err := c.load(item.Name)
		if err != nil {
			t.Fatal(err)
		}
		delete(docker.containers, id)
		if err := c.Broker.Release(&c.Policy, "build:"+item.Name, owned.Fence, func(sharedcapacity.Grant) error { return nil }); err != nil {
			t.Fatal(err)
		}
	}
	policy := c.Policy
	policy.Pools = maps.Clone(policy.Pools)
	pool := policy.Pools[buildPool]
	pool.Minimum = 2
	pool.MinimumRequestIDs = []string{"build:" + testName, "build:" + demandSlotName(buildPool, 2)}
	policy.Pools[buildPool] = pool
	if err := c.Broker.ReconcilePolicy(&c.Policy, &policy); err != nil {
		t.Fatal(err)
	}
	c.Policy = policy
	starts, err := c.WarmStarts(t.Context(), []DemandPool{{ID: buildPool, Minimum: 2, Maximum: 8, Idle: 2}}, &WarmTargets{Schema: 1, Targets: map[string]int{buildPool: 2}})
	if err != nil || !slices.Equal(starts[buildPool], []int{1, 2}) {
		t.Fatal("sparse busy slot consumed floor identities", starts, err)
	}
	for _, owner := range owners {
		if owner.frozen || owner.gone {
			t.Fatal("warm floor recovery interrupted owner")
		}
	}
}

func canonicalWarmTestPath(t *testing.T, c *Controller) {
	t.Helper()
	path, err := filepath.EvalSymlinks(c.Broker.Path)
	if err != nil {
		t.Fatal(err)
	}
	c.Broker.Path = path
}
