// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const (
	testMemoryPressureReason = "memory_pressure"
	testBurstRequest         = "burst-next"
)

func TestPressureRebalanceWithoutDemandSettlesBeforeReuse(t *testing.T) {
	c, owners, bind, now := demandFixture(t)
	policy := c.Policy
	policy.BuildMemoryOvercommit = &sharedcapacity.BuildMemoryOvercommit{AdditionalMiB: 12288, MinimumAvailableMiB: 16384}
	if err := c.Broker.ReconcilePolicy(&c.Policy, &policy); err != nil {
		t.Fatal(err)
	}
	c.Policy = policy
	c.Broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: 100, ObservedAt: *now}, nil
	}
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker differs")
	}
	for id, item := range docker.containers {
		if !strings.HasSuffix(item.Name, "-5") {
			owners[id].busy = true
		}
	}
	if err := c.Rebalance(context.Background(), bind); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 5, Idle: 1}}
	starts, err := c.DemandStarts(context.Background(), pools, map[string]int{buildPool: 99}, bind)
	if err != nil || len(starts[buildPool]) != 0 {
		t.Fatal("settling owner reused", starts, err)
	}
	for range 2 {
		if rebalanceErr := c.Rebalance(context.Background(), bind); !errors.Is(rebalanceErr, sharedcapacity.ErrWithdrawalWaiting) {
			t.Fatal(rebalanceErr)
		}
	}
	*now = now.Add(80 * time.Second)
	if rebalanceErr := c.Rebalance(context.Background(), bind); rebalanceErr != nil {
		t.Fatal(rebalanceErr)
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 4 {
		t.Fatal(snapshot, err)
	}
	decision, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: "build:ci-runner-build-5", Pool: buildPool})
	if err != nil || decision.Admitted || decision.Reason != testMemoryPressureReason {
		t.Fatal("low-memory replacement admitted", decision, err)
	}
	c.Broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: 16384 + 12288, ObservedAt: *now}, nil
	}
	decision, err = c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: "build:ci-runner-build-5", Pool: buildPool})
	if err != nil || !decision.Admitted {
		t.Fatal("recovered headroom did not restore capacity", decision, err)
	}
}

type pickupOnFreezeOwner struct{ *fakePlanningOwner }

func (o *pickupOnFreezeOwner) Freeze(ctx context.Context) error {
	o.busy = true
	return o.fakePlanningOwner.Freeze(ctx)
}

func TestPressurePickupRaceResumesAndRetainsGrant(t *testing.T) {
	c, owners, bind, now := demandFixture(t)
	policy := c.Policy
	policy.BuildMemoryOvercommit = &sharedcapacity.BuildMemoryOvercommit{AdditionalMiB: 12288, MinimumAvailableMiB: 16384}
	if err := c.Broker.ReconcilePolicy(&c.Policy, &policy); err != nil {
		t.Fatal(err)
	}
	c.Policy = policy
	c.Broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: 100, ObservedAt: *now}, nil
	}
	raceBind := func(ctx context.Context, name, id string, runnerID int64, runnerName string) (OwnerBinding, error) {
		binding, err := bind(ctx, name, id, runnerID, runnerName)
		if err != nil {
			return binding, err
		}
		binding.Owner = &pickupOnFreezeOwner{owners[id]}
		return binding, nil
	}
	if err := c.Rebalance(context.Background(), raceBind); err == nil {
		t.Fatal("pickup race not reported")
	}
	for _, owner := range owners {
		if owner.frozen || owner.gone {
			t.Fatal("assigned job withdrawn")
		}
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 5 {
		t.Fatal("pickup lost grant", err)
	}
}

func TestQueueBurstAboveTenStillRespectsMeasuredReserve(t *testing.T) {
	c, _, bind, now := demandFixture(t)
	policy := c.Policy
	policy.Pools = maps.Clone(policy.Pools)
	policy.Budget = sharedcapacity.Resources{MemoryMiB: 112000, VCPUs: 28}
	policy.CPUAdmission = sharedcapacity.CPUAdmissionSoft
	policy.BuildMemoryOvercommit = &sharedcapacity.BuildMemoryOvercommit{AdditionalMiB: 65536, MinimumAvailableMiB: 8192}
	pool := policy.Pools[buildPool]
	pool.Maximum = 24
	policy.Pools[buildPool] = pool
	if err := c.Broker.ReconcilePolicy(&c.Policy, &policy); err != nil {
		t.Fatal(err)
	}
	c.Policy = policy
	available := uint64(8192 + 12288)
	c.Broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: available, ObservedAt: *now}, nil
	}
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 24, Idle: 10}}
	observation, err := c.ObserveDemand(t.Context(), pools, "queue-burst", bind)
	if err != nil {
		t.Fatal(err)
	}
	request := DemandTargets{Schema: 1, PolicyDigest: observation.PolicyDigest, PoolsDigest: observation.PoolsDigest, ObservedAt: now.Unix(), QueueStartedAt: now.Unix(), Targets: map[string]int{buildPool: 11}}
	starts, err := c.ApplyDemandTargets(t.Context(), pools, "queue-burst", &request, bind)
	if err != nil || len(starts[buildPool]) != 6 {
		t.Fatal(starts, err)
	}
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker differs")
	}
	for _, index := range starts[buildPool] {
		name := fmt.Sprintf("ci-runner-build-%d", index)
		id := fmt.Sprintf("%064x", index)
		docker.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000}
		if startErr := c.Start(t.Context(), name, id); startErr != nil {
			t.Fatal(startErr)
		}
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 11 {
		t.Fatal("burst did not cross former ten-builder cap", err)
	}
	available = 8191
	decision, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: testBurstRequest, Pool: buildPool})
	if err != nil || decision.Admitted || decision.Reason != testMemoryPressureReason {
		t.Fatal("queue bypassed reserve", decision, err)
	}
	available = 8192 + 12288 - 1
	decision, err = c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: testBurstRequest, Pool: buildPool})
	if err != nil || decision.Admitted {
		t.Fatal("expansion gap bypassed", decision, err)
	}
	available++
	decision, err = c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: testBurstRequest, Pool: buildPool})
	if err != nil || !decision.Admitted {
		t.Fatal("recovered headroom did not admit", decision, err)
	}
}
