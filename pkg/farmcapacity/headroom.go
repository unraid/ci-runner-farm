// Package farmcapacity preserves exact builder start charges through registration.
package farmcapacity

import (
	"context"
	"errors"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// ConfirmStarted follows durable registration and routing publication while
// the native fleet and policy leases are still held. It never acknowledges an
// unknown, paused, retiring or withdrawing execution.
func (c *Controller) ConfirmStarted(ctx context.Context, name, id string) error {
	if !c.Policy.SharedMemoryHeadroom {
		return nil
	}
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned != nil && (owned.Retiring || owned.ReleasePending || (owned.Withdrawal != nil && owned.Withdrawal.Phase != "")) {
		return nil
	}
	if owned == nil || owned.ID != id || owned.Fence == "" || owned.Retiring || owned.ReleasePending || owned.Withdrawal == nil || owned.Withdrawal.Phase != "" || owned.Withdrawal.RunnerID <= 0 || owned.Withdrawal.RunnerName == "" || owned.Withdrawal.ContainerID != id || owned.Withdrawal.Fence != owned.Fence {
		return errors.New("builder start requires a durable active registration receipt")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	grant, found := snapshot.Grants["build:"+name]
	start, exists := snapshot.Starts[grant.ID]
	if !found || !exists || grant.Fence != owned.Fence {
		return sharedcapacity.ErrFenceMismatch
	}
	if owned.Start == nil {
		owned.Start = &start
		if err := c.save(name, owned); err != nil {
			return err
		}
	}
	return c.Broker.ConfirmStarted(&c.Policy, grant.ID, *owned.Start, func(current sharedcapacity.Grant) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		container, err := c.Docker.Inspect(ctx, id)
		if err != nil {
			return err
		}
		if err := c.validate(container, name); err != nil {
			return err
		}
		resources, err := containerResources(container)
		if err != nil || container.ID != id || !container.Running || container.Paused || container.Terminated || resources != current.Cost {
			return errors.New("builder execution differs from the admitted running owner")
		}
		return nil
	})
}
