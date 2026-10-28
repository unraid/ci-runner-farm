// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// GitHub registration tokens expire after one hour. Refresh with 15 minutes
// of margin before a never-started container can receive a workload grant.
func (c *Controller) registrationFresh(container *Container) bool {
	issued := time.Unix(container.RegistrationIssuedAt, 0)
	now := c.now()
	return container.RegistrationIssuedAt > 0 && !issued.After(now) && now.Sub(issued) < 45*time.Minute
}

type inertRemover interface {
	RemoveCreated(context.Context, string) error
}

// PrepareQueuedReplacement retains the stable broker request and its age. It
// writes removal intent before deleting only an exact never-started container.
// No charged, stopped-after-start, busy or ambiguous owner can be replaced here.
func (c *Controller) PrepareQueuedReplacement(ctx context.Context, name, id string) error {
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned.ID != id {
		return errors.New("queued replacement owner differs")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	if allowedErr := queuedReplacementAllowed(name, owned, &snapshot); allowedErr != nil {
		return allowedErr
	}
	container, err := c.Docker.Inspect(ctx, id)
	if errors.Is(err, ErrContainerMissing) && owned.ReplacementPrepared {
		return c.oldReplacementAbsent(ctx, name, id)
	}
	if err != nil {
		return err
	}
	if err := c.validate(container, name); err != nil {
		return err
	}
	if container.ID != id || !container.NeverStarted || container.Running {
		return errors.New("queued replacement requires a never-started owner")
	}
	remover, ok := c.Docker.(inertRemover)
	if !ok {
		return errors.New("native inert replacement is unavailable")
	}
	owned.ReplacementPrepared = true
	if err := c.save(name, owned); err != nil {
		return err
	}
	if err := remover.RemoveCreated(ctx, id); err != nil {
		return err
	}
	return c.oldReplacementAbsent(ctx, name, id)
}

func queuedReplacementAllowed(name string, owned *receipt, snapshot *sharedcapacity.Snapshot) error {
	requestID := "build:" + name
	if _, charged := snapshot.Grants[requestID]; charged || owned.Fence != "" || (owned.Withdrawal != nil && owned.Withdrawal.Phase != "") {
		return errors.New("charged or withdrawing build cannot refresh queued credentials")
	}
	pending, exists := snapshot.Pending[requestID]
	if !exists && owned.ReleasePending {
		return nil
	} // Cancellation also recovers an inert create before first admission.
	if !exists || pending.Pool != buildPool {
		return errors.New("replacement requires the exact stable queued request")
	}
	return nil
}

func (c *Controller) oldReplacementAbsent(ctx context.Context, name, id string) error {
	for _, identity := range []string{id, name} {
		_, err := c.Docker.Inspect(ctx, identity)
		if !errors.Is(err, ErrContainerMissing) {
			if err != nil {
				return err
			}
			return errors.New("queued owner or replacement still exists")
		}
	}
	return nil
}

func (c *Controller) finishQueuedReplacement(ctx context.Context, name string, container *Container, owned *receipt, snapshot *sharedcapacity.Snapshot) error {
	if !owned.ReplacementPrepared || !container.NeverStarted || container.Running {
		return errors.New("build receipt belongs to another container")
	}
	if err := queuedReplacementAllowed(name, owned, snapshot); err != nil {
		return err
	}
	_, err := c.Docker.Inspect(ctx, owned.ID)
	if !errors.Is(err, ErrContainerMissing) {
		if err != nil {
			return err
		}
		return errors.New("previous queued owner still exists")
	}
	// The caller already inspected and validated the new immutable ID and stable
	// name under the native fleet lock. Keep broker demand untouched.
	owned.ID = container.ID
	owned.ReplacementPrepared = false
	return c.save(name, owned)
}
