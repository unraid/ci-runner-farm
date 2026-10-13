// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type retirementRoutingOwner interface {
	WithdrawRetirementRouting(context.Context) error
}

// Retire drains every charged builder, including the floor, on an explicitly
// closed host. The native caller holds fleet.lock and a configuration lease.
// Busy workers lose custom routing but keep running and retain their grants.
// Policy, QA ownership, and queued demand are never changed here.
func (c *Controller) Retire(ctx context.Context, bind BindOwner) error {
	if bind == nil {
		return errors.New("native retirement binding is required")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	problems := []error{c.recoverReleasedOwners(ctx, &snapshot, bind)}
	ids := make([]string, 0, len(snapshot.Grants))
	for id, grant := range snapshot.Grants {
		if grant.Pool == buildPool {
			ids = append(ids, id)
		}
	}
	slices.Sort(ids)
	for _, id := range ids {
		grant := snapshot.Grants[id]
		name := strings.TrimPrefix(id, "build:")
		owned, loadErr := c.load(name)
		if loadErr != nil || owned.Fence != grant.Fence {
			problems = append(problems, fmt.Errorf("retirement owner %s is unavailable", name))
			continue
		}
		problems = append(problems, c.retireOwner(ctx, name, owned, bind))
	}
	return errors.Join(problems...)
}

func (c *Controller) retireOwner(ctx context.Context, name string, owned *receipt, bind BindOwner) error {
	item, err := c.observeNativeOwner(ctx, name, owned)
	if err != nil {
		return err
	}
	if owned.Withdrawal == nil || owned.Withdrawal.Phase == "" {
		if validationErr := c.validateRetirementOwner(item, name, owned); validationErr != nil {
			return validationErr
		}
	}
	binding, err := c.bindWithdrawalOwner(ctx, name, owned, bind)
	if err != nil {
		return err
	}
	if binding.Owner == nil {
		return errors.New("native retirement owner is unavailable")
	}
	if binding.RunnerID != 0 {
		if registrationErr := c.RecordRegistration(name, owned.ID, binding.RunnerID, binding.RunnerName); registrationErr != nil {
			return registrationErr
		}
	}
	owned, err = c.load(name)
	if err != nil {
		return err
	}
	if !owned.Retiring {
		owned.Retiring = true
		if err := c.save(name, owned); err != nil {
			return err
		}
	}
	if owned.Withdrawal == nil || owned.Withdrawal.Phase == "" {
		if binding.RunnerID == 0 {
			if err := requireUnregisteredGone(ctx, binding.Owner); err != nil {
				return err
			}
		} else {
			routing, ok := binding.Owner.(retirementRoutingOwner)
			if !ok {
				return errors.New("native retirement routing capability is required")
			}
			if err := routing.WithdrawRetirementRouting(ctx); err != nil {
				return err
			}
		}
		idle, err := binding.Owner.Idle(ctx)
		if err != nil {
			return err
		}
		if !idle {
			return sharedcapacity.ErrWorkloadBusy
		}
	}
	return c.withdraw(ctx, name, owned.ID, binding.Owner, binding.RunnerID, binding.RunnerName, c.now(), true)
}

func (c *Controller) validateRetirementOwner(item *Container, name string, owned *receipt) error {
	if item == nil || item.ID != owned.ID {
		return errors.New("retirement native immutable identity changed")
	}
	if err := c.validate(item, name); err != nil {
		return err
	}
	resources, err := containerResources(item)
	if err != nil {
		return err
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	if grant, ok := snapshot.Grants["build:"+name]; !ok || grant.Fence != owned.Fence || grant.Cost != resources {
		return errors.New("retirement allocation differs from native limits")
	}
	return nil
}
