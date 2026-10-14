// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"strings"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// ReconcileIdle replaces one exact idle owner through the existing durable
// withdrawal protocol. The native caller holds fleet.lock and a Farm lease and
// has compared the immutable container's configuration generation. Busy races
// resume execution and retain the allocation; Rebalance recovers saved intent.
func (c *Controller) ReconcileIdle(ctx context.Context, name, id string, bind BindOwner) error {
	if !namePattern.MatchString(name) || !idPattern.MatchString(id) || bind == nil {
		return errors.New("invalid configuration reconciliation owner")
	}
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned == nil || owned.ID != id || owned.Retiring || owned.ReleasePending {
		return errors.New("configuration reconciliation receipt differs")
	}
	if owned.Maintenance || (owned.Withdrawal != nil && owned.Withdrawal.Phase != "") {
		return ErrQueued
	}
	if err := c.configurationReconciliationAvailable(name); err != nil {
		return err
	}
	item, err := c.observeNativeOwner(ctx, name, owned)
	if err != nil {
		return err
	}
	if err := c.validateRetirementOwner(item, name, owned); err != nil {
		return err
	}
	if !item.Running || item.Paused {
		return errors.New("configuration reconciliation requires a running owner")
	}
	binding, err := c.bindWithdrawalOwner(ctx, name, owned, bind)
	if err != nil {
		return err
	}
	if binding.Owner == nil || binding.RunnerID == 0 || binding.RunnerName == "" {
		return errors.New("configuration reconciliation requires an attested registration")
	}
	idle, err := binding.Owner.Idle(ctx)
	if err != nil {
		return err
	}
	if !idle {
		return sharedcapacity.ErrWorkloadBusy
	}
	if err := c.rememberRegistration(name, owned, &binding); err != nil {
		return err
	}
	owned, err = c.load(name)
	if err != nil {
		return err
	}
	owned.Maintenance = true
	owned.PreserveCache = true
	if err := c.save(name, owned); err != nil {
		return err
	}
	return c.Withdraw(ctx, name, id, binding.Owner, binding.RunnerID, binding.RunnerName, c.now())
}

// Avoid stacking replacements while a previous maintenance owner is still
// charged, frozen, or waiting for an uncertain effect to settle.
func (c *Controller) configurationReconciliationAvailable(target string) error {
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	for id, grant := range snapshot.Grants {
		if grant.Pool != buildPool {
			continue
		}
		name := strings.TrimPrefix(id, "build:")
		if name == target {
			continue
		}
		owned, err := c.load(name)
		if err != nil {
			return err
		}
		if owned == nil || owned.Fence != grant.Fence {
			return errors.New("configuration reconciliation inventory differs")
		}
		if owned.Maintenance || owned.Retiring || owned.ReleasePending || (owned.Withdrawal != nil && owned.Withdrawal.Phase != "") {
			return ErrQueued
		}
	}
	return nil
}

// Configuration replacement retains healthy warm caches. A later poison
// observation still requires the existing native repair before release.
func (c *Controller) repairReleasedCache(ctx context.Context, name string, owned *receipt) error {
	if owned.DockerRoot == "" {
		return nil
	}
	if owned.PreserveCache {
		poisoned := false
		if c.Poisoned != nil {
			observed, err := c.Poisoned(name, owned.ID)
			if err != nil {
				return err
			}
			poisoned = observed
		}
		if !poisoned {
			return nil
		}
	}
	if c.RepairCache == nil {
		return errors.New("native cache repair capability is required")
	}
	return c.RepairCache(ctx, name, owned.DockerRoot)
}
