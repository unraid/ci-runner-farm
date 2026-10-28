// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const (
	collisionCacheError      = "cache-error"
	collisionCompleted       = "completed"
	collisionPaused          = "pause-observed"
	collisionRemoteReappears = "remote-reappears"
	collisionRunningRace     = "running-race"
)

type collisionOwner struct {
	*fakePlanningOwner
	nameGone bool
	proofErr error
}

func (o *collisionOwner) RegistrationNameGone(context.Context) (bool, error) {
	return o.nameGone, o.proofErr
}

type collisionDocker struct {
	*fakeDocker
	removes   int
	onRemove  func()
	removeErr error
}

func (d *collisionDocker) RemoveCreated(ctx context.Context, id string) error {
	d.removes++
	if d.onRemove != nil {
		d.onRemove()
	}
	if d.removeErr != nil {
		return d.removeErr
	}
	return d.fakeDocker.RemoveCreated(ctx, id)
}

func collisionFixture(t *testing.T, phase string) (controller *Controller, nativeDocker *collisionDocker, planningOwner *collisionOwner, oldIdentity, newIdentity string) {
	t.Helper()
	c, docker, oldID := fixture(t)
	if err := c.Start(context.Background(), testName, oldID); err != nil {
		t.Fatal(err)
	}
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	owned.CacheCaptured = true
	owned.Withdrawal = &sharedcapacity.Withdrawal{ContainerID: oldID, Fence: owned.Fence, RunnerID: 123, RunnerName: startupRunnerName, Phase: phase, WithdrawnAt: time.Now().Add(-time.Minute * 2)}
	if err = c.save(testName, owned); err != nil {
		t.Fatal(err)
	}
	delete(docker.containers, oldID)
	newID := strings.Repeat("b", 64)
	docker.containers[newID] = &Container{ID: newID, Name: testName, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationName: startupRunnerName, RegistrationIssuedAt: time.Now().Unix()}
	native := &collisionDocker{fakeDocker: docker}
	c.Docker = native
	owner := &collisionOwner{fakePlanningOwner: &fakePlanningOwner{docker: docker, id: oldID, gone: true}, nameGone: true}
	return c, native, owner, oldID, newID
}

func collisionBind(owner *collisionOwner) BindOwner {
	return func(context.Context, string, string, int64, string) (OwnerBinding, error) {
		return OwnerBinding{Owner: owner, RunnerID: 123, RunnerName: startupRunnerName}, nil
	}
}

func TestInertCollisionRemoveIntentWithReleasePendingUsesCanonicalWithdrawal(t *testing.T) {
	c, docker, owner, _, _ := collisionFixture(t, withdrawalRemoveIntentPhase)
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	owned.ReleasePending = true
	if err = c.save(testName, owned); err != nil {
		t.Fatal(err)
	}
	if err = c.Rebalance(context.Background(), collisionBind(owner)); err != nil {
		t.Fatal(err)
	}
	if docker.removes != 1 {
		t.Fatal("collision not removed")
	}
	requireStartupGrants(t, c, 0)
}

func TestInertCollisionRequiresScopedNameProofCapability(t *testing.T) {
	c, docker, owner, oldID, newID := collisionFixture(t, withdrawalRemovedPhase)
	// Keep the existing withdrawal contract while withholding the scope proof.
	unproved := struct{ sharedcapacity.WithdrawalOwner }{owner}
	if err := c.Withdraw(context.Background(), testName, oldID, unproved, 123, startupRunnerName, time.Now()); err == nil {
		t.Fatal("missing name proof accepted")
	}
	if docker.removes != 0 || docker.containers[newID] == nil {
		t.Fatal("unproved replacement removed")
	}
	requireStartupGrants(t, c, 1)
}

func TestInertCollisionRecoveryReleasesOldFenceAndAllowsFreshAdmission(t *testing.T) {
	for _, phase := range []string{withdrawalRemovedPhase, withdrawalRemoveIntentPhase} {
		t.Run(phase, func(t *testing.T) {
			c, docker, owner, _, newID := collisionFixture(t, phase)
			before, err := c.Broker.Status(&c.Policy)
			if err != nil {
				t.Fatal(err)
			}
			if err = c.Rebalance(context.Background(), collisionBind(owner)); err != nil {
				t.Fatal(err)
			}
			if docker.removes != 1 || docker.containers[newID] != nil {
				t.Fatal("inert collision remains")
			}
			requireStartupGrants(t, c, 0)
			if _, err = c.load(testName); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("old receipt remains", err)
			}
			if err = c.Rebalance(context.Background(), collisionBind(owner)); err != nil {
				t.Fatal("repeat recovery", err)
			}
			docker.containers[newID] = &Container{ID: newID, Name: testName, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: time.Now().Unix()}
			if err = c.Start(context.Background(), testName, newID); err != nil {
				t.Fatal(err)
			}
			after, err := c.Broker.Status(&c.Policy)
			if err != nil || after.Grants["build:"+testName].Fence == before.Grants["build:"+testName].Fence || !docker.containers[newID].Running {
				t.Fatal("fresh admission reused old ownership", err)
			}
		})
	}
}

func TestInertCollisionRecoveryRejectsUnprovedOwnershipBeforeRemoval(t *testing.T) {
	for _, mode := range []string{"running", collisionPaused, "previous-start", "previous-exit", "missing-gate", "foreign-managed", "wrong-pool", "wrong-name", "wrong-limits", "old-present", "docker-error", "remote-present", "remote-error", "name-present", "fence", "withdrawal-id", "withdrawal-fence", "registration-mode", "future-time"} {
		t.Run(mode, func(t *testing.T) {
			c, docker, owner, oldID, newID := collisionFixture(t, withdrawalRemovedPhase)
			owned, err := c.load(testName)
			if err != nil {
				t.Fatal(err)
			}
			mutateCollision(mode, docker, owner, owned, oldID, newID)
			if err = c.save(testName, owned); err != nil {
				t.Fatal(err)
			}
			if err = c.Rebalance(context.Background(), collisionBind(owner)); err == nil {
				t.Fatal("unproved owner recovered")
			}
			if docker.removes != 0 || docker.containers[newID] == nil {
				t.Fatal("unproved replacement removed")
			}
			requireStartupGrants(t, c, 1)
		})
	}
}

func TestInertCollisionRecoveryRetainsFenceOnUncertainEffectsAndRetries(t *testing.T) {
	for _, mode := range []string{"remove-error", collisionRunningRace, "removed-uncertain", collisionCacheError, collisionRemoteReappears} {
		t.Run(mode, func(t *testing.T) {
			c, docker, owner, _, newID := collisionFixture(t, withdrawalRemovedPhase)
			before, err := c.Broker.Status(&c.Policy)
			if err != nil {
				t.Fatal(err)
			}
			prepareCollisionFailure(t, mode, c, docker, owner, newID)
			if err = c.Rebalance(context.Background(), collisionBind(owner)); err == nil {
				t.Fatal("uncertain effect released allocation")
			}
			after, err := c.Broker.Status(&c.Policy)
			if err != nil || after.Grants["build:"+testName].Fence != before.Grants["build:"+testName].Fence {
				t.Fatal("uncertain effect changed fence", err)
			}
			if _, err = c.load(testName); err != nil {
				t.Fatal("lost durable recovery", err)
			}
			if mode == collisionRunningRace {
				return
			}
			docker.removeErr, docker.onRemove = nil, nil
			if mode == collisionRemoteReappears {
				if err = c.Rebalance(context.Background(), collisionBind(owner)); err == nil {
					t.Fatal("remote reappearance bypassed replay proof")
				}
				requireStartupGrants(t, c, 1)
			}
			owner.nameGone = true
			c.RepairCache = func(context.Context, string, string) error { return nil }
			if mode == collisionCacheError {
				docker.containers[newID] = &Container{ID: newID, Name: testName, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationName: startupRunnerName}
			}
			if err = c.Rebalance(context.Background(), collisionBind(owner)); err != nil {
				t.Fatal("recovery retry", err)
			}
			requireStartupGrants(t, c, 0)
		})
	}
}

func TestInertCollisionReleasedReceiptNeverDeletesNewOwnership(t *testing.T) {
	for _, mode := range []string{collisionCompleted, "new-grant", "new-pending"} {
		t.Run(mode, func(t *testing.T) {
			c, docker, owner, _, newID := collisionFixture(t, withdrawalRemovedPhase)
			releaseCollisionGrant(t, c)

			if mode == "new-pending" {
				admitCollisionRequest(t, c, "other")
			}
			if mode != collisionCompleted {
				admitCollisionRequest(t, c, "build:"+testName)
			}
			err := c.Rebalance(context.Background(), collisionBind(owner))
			if mode == collisionCompleted {
				if err != nil || docker.removes != 1 {
					t.Fatal("completed release not recovered", err)
				}
			} else if err == nil || docker.removes != 0 || docker.containers[newID] == nil {
				t.Fatal("stale receipt removed new ownership", err)
			}
		})
	}
}

func mutateCollision(mode string, docker *collisionDocker, owner *collisionOwner, owned *receipt, oldID, newID string) {
	switch mode {
	case "running":
		docker.containers[newID].Running = true
	case collisionPaused:
		docker.containers[newID].Paused = true
	case "previous-start":
		docker.containers[newID].NeverStarted = false
	case "previous-exit":
		docker.containers[newID].Exited = true
	case "missing-gate":
		docker.containers[newID].RoutingGated = false
	case "foreign-managed":
		docker.containers[newID].Managed = false
	case "wrong-pool":
		docker.containers[newID].Pool = "build-small"
	case "wrong-name":
		docker.containers[newID].RegistrationName = "other-" + testName
	case "wrong-limits":
		docker.containers[newID].NanoCPUs *= 2
	case "old-present":
		docker.containers[oldID] = &Container{ID: oldID, Name: "old", Running: true}
	case "docker-error":
		docker.inspectErr = errors.New("unavailable")
	case "remote-present":
		owner.gone = false
	case "remote-error":
		owner.proofErr = errors.New("unavailable")
	case "name-present":
		owner.nameGone = false
	case "fence":
		owned.Fence = "stale"
	case "withdrawal-id":
		owned.Withdrawal.ContainerID = newID
	case "withdrawal-fence":
		owned.Withdrawal.Fence = "stale"
	case "registration-mode":
		owned.Withdrawal.Unregistered = true
	case "future-time":
		owned.Withdrawal.WithdrawnAt = time.Now().Add(time.Hour)
	}
}

func prepareCollisionFailure(t *testing.T, mode string, c *Controller, docker *collisionDocker, owner *collisionOwner, newID string) {
	t.Helper()
	switch mode {
	case "remove-error":
		docker.removeErr = errors.New("unknown removal")
	case collisionRunningRace:
		docker.onRemove = func() { docker.containers[newID].Running = true }
	case "removed-uncertain":
		docker.onRemove = func() { delete(docker.containers, newID) }
		docker.removeErr = errors.New("unknown removal")
	case collisionCacheError:
		owned, loadErr := c.load(testName)
		if loadErr != nil {
			t.Fatal(loadErr)
		}
		owned.DockerRoot = "/mnt/cache/docker/" + testName
		if saveErr := c.save(testName, owned); saveErr != nil {
			t.Fatal(saveErr)
		}
		c.RepairCache = func(context.Context, string, string) error { return errors.New("cache unavailable") }
	case collisionRemoteReappears:
		docker.onRemove = func() { owner.nameGone = false }
	}
}

func releaseCollisionGrant(t *testing.T, c *Controller) {
	t.Helper()
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if err = c.Broker.Release(&c.Policy, "build:"+testName, snapshot.Grants["build:"+testName].Fence, func(sharedcapacity.Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func admitCollisionRequest(t *testing.T, c *Controller, id string) {
	t.Helper()
	if _, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: id, Pool: buildPool}); err != nil {
		t.Fatal(err)
	}
}
