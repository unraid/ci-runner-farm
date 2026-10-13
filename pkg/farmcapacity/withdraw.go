// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// Withdraw uses a native, frozen owner and persists each effect boundary. The
// caller holds fleet.lock across planning, withdrawal, exact removal and release.
func (c *Controller) Withdraw(ctx context.Context, name, id string, owner sharedcapacity.WithdrawalOwner, runnerID int64, runnerName string, now time.Time) error {
	return c.withdraw(ctx, name, id, owner, runnerID, runnerName, now, false)
}

func (c *Controller) withdraw(ctx context.Context, name, id string, owner sharedcapacity.WithdrawalOwner, runnerID int64, runnerName string, now time.Time, retirement bool) error {
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned.ID != id || owned.Fence == "" {
		return errors.New("idle withdrawal owner receipt differs")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	grant, exists := snapshot.Grants["build:"+name]
	if !exists || grant.Fence != owned.Fence {
		return sharedcapacity.ErrFenceMismatch
	}
	if (!retirement || !owned.Retiring) && !owned.Maintenance && sharedcapacity.ProtectsMinimum(&snapshot, grant.Request) && (owned.Withdrawal == nil || owned.Withdrawal.Phase == "") {
		item, inspectErr := c.Docker.Inspect(ctx, id)
		if inspectErr != nil {
			return inspectErr
		}
		if item.ID != id || !item.Exited || item.Running {
			return errors.New("idle withdrawal would cross the build guarantee")
		}
	}
	if captureErr := c.captureDockerRoot(ctx, name, owned); captureErr != nil {
		return captureErr
	}
	if owned.Withdrawal == nil {
		owned.Withdrawal = &sharedcapacity.Withdrawal{ContainerID: id, Fence: owned.Fence, RunnerID: runnerID, RunnerName: runnerName, Unregistered: runnerID == 0}
	}
	withdrawal := owned.Withdrawal
	if !matchesWithdrawalIdentity(withdrawal, id, grant.Fence, runnerID, runnerName) {
		return errors.New("idle withdrawal identity changed")
	}
	if err := c.recoverInertReplacement(ctx, name, owned, owner); err != nil {
		return err
	}
	if err := sharedcapacity.AdvanceWithdrawal(ctx, withdrawal, owner, now, func() error { return c.save(name, owned) }); err != nil {
		return err
	}
	// A saved removed phase can replay after cache repair or release failed.
	// Repeat absence on that path too, immediately before fenced release.
	if withdrawal.Unregistered {
		if proofErr := requireUnregisteredGone(ctx, owner); proofErr != nil {
			return proofErr
		}
	}
	return c.Release(ctx, name, id)
}

func (c *Controller) captureDockerRoot(ctx context.Context, name string, owned *receipt) error {
	if owned.CacheCaptured || owned.DockerRoot != "" {
		return nil
	}
	item, err := c.Docker.Inspect(ctx, owned.ID)
	if err != nil {
		return err
	}
	if validateErr := c.validate(item, name); validateErr != nil {
		return validateErr
	}
	owned.DockerRoot = item.DockerRoot
	owned.CacheCaptured = true
	return nil
}

func requireUnregisteredGone(ctx context.Context, owner sharedcapacity.WithdrawalOwner) error {
	gone, err := owner.RemoteGone(ctx)
	if err != nil {
		return err
	}
	if !gone {
		return errors.New("unregistered native name appeared before release")
	}
	return nil
}

func matchesWithdrawalIdentity(withdrawal *sharedcapacity.Withdrawal, id, fence string, runnerID int64, runnerName string) bool {
	return withdrawal.ContainerID == id && withdrawal.Fence == fence && withdrawal.RunnerID == runnerID && withdrawal.RunnerName == runnerName && withdrawal.Unregistered == (runnerID == 0)
}
