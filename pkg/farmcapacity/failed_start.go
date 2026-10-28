// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"fmt"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// failedStartProved re-inspects the same immutable owner after Docker refused
// its start. A start cut short by this command's own deadline may still finish
// inside Docker, so only a live, exact never-started observation is proof.
func (c *Controller) failedStartProved(ctx context.Context, name string, before *Container) bool {
	if _, removable := c.Docker.(inertRemover); !removable || !before.NeverStarted || ctx.Err() != nil {
		return false
	}
	item, err := c.Docker.Inspect(ctx, before.ID)
	return err == nil && item.ID == before.ID && c.inertOwner(item, name)
}

func (c *Controller) inertOwner(item *Container, name string) bool {
	return c.validate(item, name) == nil && item.NeverStarted && !item.Running && !item.Paused && !item.Exited && item.RoutingGated
}

// replaceFailedStart gives a charged owner whose start provably failed a way
// out. Retrying the same container repeats a container-scoped Docker failure,
// while its grant and shadow charge can hold every other start below headroom.
// Removal intent is durable before the exact inert container is deleted, and
// release stays fenced behind ID and name absence. Nothing ran there, so the
// persistent cache is kept. The native owner then recreates the slot.
func (c *Controller) replaceFailedStart(ctx context.Context, name string, owned *receipt, cause error) error {
	if err := c.captureDockerRoot(ctx, name, owned); err != nil {
		return errors.Join(cause, err)
	}
	owned.ReleasePending, owned.ReplacementPrepared, owned.PreserveCache = true, true, true
	if err := c.save(name, owned); err != nil {
		return errors.Join(cause, err)
	}
	if err := c.finishFailedStart(ctx, name, owned); err != nil {
		return errors.Join(cause, err)
	}
	return fmt.Errorf("%w: %w", ErrStartReplaced, cause)
}

// finishFailedStart replays saved charged replacement intent. It removes only
// the receipt's exact inert container, or an inert container created under the
// same name before release finished. A started, foreign, unknown or refenced
// owner retains the allocation.
func (c *Controller) finishFailedStart(ctx context.Context, name string, owned *receipt) error {
	remover, ok := c.Docker.(inertRemover)
	if !ok {
		return errors.New("native inert removal is unavailable")
	}
	requestID := "build:" + name
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	grant, charged := snapshot.Grants[requestID]
	if owned.Fence == "" || (charged && grant.Fence != owned.Fence) {
		return sharedcapacity.ErrFenceMismatch
	}
	if !charged && !completedRelease(requestID, owned, &snapshot) {
		return errors.New("failed start allocation disappeared before release")
	}
	for _, identity := range []string{owned.ID, name} {
		item, inspectErr := c.Docker.Inspect(ctx, identity)
		if errors.Is(inspectErr, ErrContainerMissing) {
			continue
		}
		if inspectErr != nil {
			return inspectErr
		}
		if (identity == owned.ID && item.ID != owned.ID) || !c.inertOwner(item, name) {
			return errors.New("failed start replacement is not an exact never-started native owner")
		}
		if removeErr := remover.RemoveCreated(ctx, item.ID); removeErr != nil {
			return removeErr
		}
	}
	return c.Release(ctx, name, owned.ID)
}
