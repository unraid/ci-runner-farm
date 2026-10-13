// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// PlanningOwner supplies positive idle evidence, then closes admission and
// rechecks that evidence before the coordinator crosses any effect boundary.
type PlanningOwner interface {
	sharedcapacity.WithdrawalOwner
	Idle(context.Context) (bool, error)
}

// closedRegistrationOwner exposes positive terminal-registration evidence.
type closedRegistrationOwner interface {
	RegistrationGone(context.Context) (bool, error)
}

// OwnerBinding binds one attested remote registration to a native owner.
type OwnerBinding struct {
	Owner      PlanningOwner
	RunnerID   int64
	RunnerName string
}

// BindOwner recovers saved registration IDs without executing inside a frozen
// container. A missing or ambiguous identity must fail closed.
type BindOwner func(context.Context, string, string, int64, string) (OwnerBinding, error)

func (c *Controller) now() time.Time {
	if c.Broker.Now != nil {
		return c.Broker.Now().UTC()
	}
	return time.Now().UTC()
}

// Rebalance finishes durable withdrawals, then proposes only a complete idle
// subset that can satisfy the oldest highest-priority waiting allocation.
func (c *Controller) Rebalance(ctx context.Context, bind BindOwner) error {
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	if bind == nil {
		return errors.New("native owner binding is required")
	}
	recoveryErr := c.recoverReleasedOwners(ctx, &snapshot, bind)
	observations, bindings, problems, withdrawalInFlight := c.observeOwners(ctx, &snapshot, bind)
	problems = append(problems, recoveryErr)
	// Settling withdrawals remain charged. Do not select another subset on
	// every daemon tick while the same demand waits for those allocations.
	if withdrawalInFlight {
		return errors.Join(problems...)
	}
	current, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return errors.Join(append(problems, err)...)
	}
	plan, err := sharedcapacity.PlanMemoryDrain(&current, observations, c.Broker.BuildMemoryStatus(&c.Policy), c.now())
	if err == nil && len(plan.Grants) == 0 {
		plan, err = sharedcapacity.PlanDrain(&current, observations, c.now())
	}
	if err != nil {
		return errors.Join(append(problems, err)...)
	}
	for _, grant := range plan.Grants {
		binding, exists := bindings[grant.ID]
		if !exists {
			continue
		}
		name := strings.TrimPrefix(grant.ID, "build:")
		owned, readErr := c.load(name)
		if readErr != nil {
			problems = append(problems, readErr)
			continue
		}
		problems = append(problems, c.Withdraw(ctx, name, owned.ID, binding.Owner, binding.RunnerID, binding.RunnerName, c.now()))
	}
	return errors.Join(problems...)
}

func (c *Controller) bindWithdrawalOwner(ctx context.Context, name string, owned *receipt, bind BindOwner) (OwnerBinding, error) {
	runnerID := int64(0)
	runnerName := ""
	if owned.Withdrawal != nil {
		if owned.Withdrawal.Unregistered != (owned.Withdrawal.RunnerID == 0) {
			return OwnerBinding{}, errors.New("native withdrawal registration mode differs")
		}
		runnerID = owned.Withdrawal.RunnerID
		runnerName = owned.Withdrawal.RunnerName
	}
	return bind(ctx, name, owned.ID, runnerID, runnerName)
}

func (c *Controller) observeOwners(ctx context.Context, snapshot *sharedcapacity.Snapshot, bind BindOwner) (observations map[string]sharedcapacity.Observation, bindings map[string]OwnerBinding, problems []error, withdrawalInFlight bool) {
	observations = map[string]sharedcapacity.Observation{}
	bindings = map[string]OwnerBinding{}
	ids := make([]string, 0, len(snapshot.Grants))
	for id := range snapshot.Grants {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	for _, id := range ids {
		grant := snapshot.Grants[id]
		if grant.Pool != buildPool {
			continue
		}
		name := strings.TrimPrefix(id, "build:")
		owned, readErr := c.load(name)
		if readErr != nil || owned.Fence != grant.Fence {
			problems = append(problems, fmt.Errorf("build owner %s is unavailable", name))
			continue
		}
		item, inspectErr := c.observeNativeOwner(ctx, name, owned)
		if inspectErr != nil {
			problems = append(problems, inspectErr)
			continue
		}

		if !item.Running && !item.Exited && (owned.Withdrawal == nil || owned.Withdrawal.Phase == "") {
			continue
		}

		binding, bindErr := c.bindWithdrawalOwner(ctx, name, owned, bind)
		if bindErr != nil {
			problems = append(problems, bindErr)
			continue
		}
		if poisonErr := c.rememberOwnerMaintenance(ctx, name, owned, binding.Owner); poisonErr != nil {
			problems = append(problems, poisonErr)
			continue
		}
		if owned.Maintenance || item.Exited || (owned.Withdrawal != nil && owned.Withdrawal.Phase != "") {
			withdrawErr := c.Withdraw(ctx, name, owned.ID, binding.Owner, binding.RunnerID, binding.RunnerName, c.now())
			problems = append(problems, withdrawErr)
			withdrawalInFlight = withdrawalInFlight || withdrawErr != nil
			continue
		}
		if saveErr := c.rememberRegistration(name, owned, &binding); saveErr != nil {
			problems = append(problems, saveErr)
			continue
		}
		if !needsIdleObservation(snapshot) {
			continue
		}
		idle, idleErr := binding.Owner.Idle(ctx)
		if idleErr != nil {
			problems = append(problems, idleErr)
			continue
		}
		if idle {
			observations[id] = sharedcapacity.Observation{Fence: grant.Fence, ObservedAt: c.now()}
			bindings[id] = binding
		}
	}
	return observations, bindings, problems, withdrawalInFlight
}

func (c *Controller) observeNativeOwner(ctx context.Context, name string, owned *receipt) (*Container, error) {
	item, err := c.Docker.Inspect(ctx, owned.ID)
	if errors.Is(err, ErrContainerMissing) && owned.Withdrawal != nil && owned.Withdrawal.Phase != "" {
		return &Container{ID: owned.ID, Name: name}, nil
	}
	return item, err
}

func (c *Controller) rememberRegistration(name string, owned *receipt, binding *OwnerBinding) error {
	if owned.Withdrawal != nil {
		return nil
	}
	return c.RecordRegistration(name, owned.ID, binding.RunnerID, binding.RunnerName)
}

func (c *Controller) rememberMaintenance(name string, owned *receipt) error {
	if owned.Maintenance || c.Poisoned == nil {
		return nil
	}
	poisoned, err := c.Poisoned(name, owned.ID)
	if err != nil || !poisoned {
		return err
	}
	owned.Maintenance = true
	return c.save(name, owned)
}

// A lost remote registration is terminal only after native idle and scope-bound
// absence proof. Persist repair intent before freezing, so a crash cannot revive
// an unusable listener or forget its charged allocation.
func (c *Controller) rememberClosedRegistration(ctx context.Context, name string, owned *receipt, owner PlanningOwner) error {
	if owned.Maintenance {
		return nil
	}
	terminal, ok := owner.(closedRegistrationOwner)
	if !ok {
		return nil
	}
	gone, err := terminal.RegistrationGone(ctx)
	if err != nil || !gone {
		return err
	}
	owned.Maintenance = true
	return c.save(name, owned)
}

func (c *Controller) rememberOwnerMaintenance(ctx context.Context, name string, owned *receipt, owner PlanningOwner) error {
	if owned.Withdrawal != nil && owned.Withdrawal.Phase != "" {
		return nil // Durable withdrawal owns recovery, including uncertain removal.
	}
	if err := c.rememberClosedRegistration(ctx, name, owned, owner); err != nil {
		return err
	}
	return c.rememberMaintenance(name, owned)
}

func needsIdleObservation(snapshot *sharedcapacity.Snapshot) bool {
	return len(snapshot.Pending) > 0 || snapshot.Policy.BuildMemoryOvercommit != nil
}
