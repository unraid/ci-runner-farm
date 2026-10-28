// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"os"
	"strings"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const withdrawalRemoveIntentPhase = "remove_intent"

// A crash after broker release can leave its removed receipt. Recover only
// that exact completed effect, never a missing or uncertain allocation.
func (c *Controller) recoverReleasedOwners(ctx context.Context, snapshot *sharedcapacity.Snapshot, bind BindOwner) error {
	entries, err := os.ReadDir(c.ReceiptRoot)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var problems []error
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		name := strings.TrimSuffix(entry.Name(), ".json")
		owned, err := c.load(name)
		if err != nil {
			problems = append(problems, err)
			continue
		}
		if !owned.ReleasePending && (owned.Withdrawal == nil || owned.Withdrawal.Phase != withdrawalRemovedPhase) {
			continue
		}
		if _, charged := snapshot.Grants["build:"+name]; charged && (!owned.ReleasePending || (owned.Withdrawal != nil && owned.Withdrawal.Phase == withdrawalRemoveIntentPhase)) {
			continue
		}
		if owned.ReleasePending && owned.Fence == "" {
			problems = append(problems, c.CancelQueued(ctx, name, owned.ID))
			continue
		}
		// A charged inert replacement only follows a proved failed start.
		if owned.ReleasePending && owned.ReplacementPrepared {
			problems = append(problems, c.finishFailedStart(ctx, name, owned))
			continue
		}
		binding, err := c.bindWithdrawalOwner(ctx, name, owned, bind)
		if err != nil {
			problems = append(problems, err)
			continue
		}
		problems = append(problems, c.recoverReleasedOwner(ctx, name, owned, binding.Owner))
	}
	return errors.Join(problems...)
}

func (c *Controller) recoverReleasedOwner(ctx context.Context, name string, owned *receipt, owner PlanningOwner) error {
	if err := c.recoverInertReplacement(ctx, name, owned, owner); err != nil {
		return err
	}
	removed, err := owner.Removed(ctx)
	if err != nil {
		return err
	}
	if !removed {
		return errors.New("released native owner or replacement remains")
	}
	gone, err := owner.RemoteGone(ctx)
	if err != nil {
		return err
	}
	if !gone {
		return errors.New("released native registration remains")
	}
	return c.Release(ctx, name, owned.ID)
}

// A failed final release can leave a removed owner behind a newly created
// native container. Its existing withdrawal intent permits only inert cleanup;
// running or uncertain replacements retain both ownership and allocation.
func (c *Controller) recoverInertReplacement(ctx context.Context, name string, owned *receipt, owner sharedcapacity.WithdrawalOwner) error {
	w := owned.Withdrawal
	if w == nil || (w.Phase != withdrawalRemovedPhase && w.Phase != withdrawalRemoveIntentPhase) {
		return nil
	}
	if _, err := c.Docker.Inspect(ctx, owned.ID); !errors.Is(err, ErrContainerMissing) {
		return err // A present old owner continues through normal withdrawal.
	}
	absence, ok := owner.(interface {
		RegistrationNameGone(context.Context) (bool, error)
	})
	if !ok {
		return errors.New("inert recovery requires scoped registration name absence")
	}
	prove := func() error {
		gone, err := owner.RemoteGone(ctx)
		if err != nil {
			return err
		}
		nameGone, err := absence.RegistrationNameGone(ctx)
		if err != nil {
			return err
		}
		if !gone || !nameGone {
			return errors.New("inert recovery registration remains")
		}
		return nil
	}
	item, err := c.Docker.Inspect(ctx, name)
	if errors.Is(err, ErrContainerMissing) {
		return prove()
	}
	if err != nil {
		return err
	}
	if validationErr := c.validateInertReplacement(name, owned, item); validationErr != nil {
		return validationErr
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	if grant, charged := snapshot.Grants["build:"+name]; charged {
		if grant.Fence != owned.Fence {
			return sharedcapacity.ErrFenceMismatch
		}
	} else if !completedRelease("build:"+name, owned, &snapshot) {
		return errors.New("inert recovery lost its completed allocation")
	}
	if _, err := c.containerRequest(item, &snapshot); err != nil {
		return err
	}

	if err := prove(); err != nil {
		return err
	}
	remover, ok := c.Docker.(inertRemover)
	if !ok {
		return errors.New("native inert removal is unavailable")
	}
	if err := remover.RemoveCreated(ctx, item.ID); err != nil {
		return err
	}
	if err := c.oldReplacementAbsent(ctx, name, owned.ID); err != nil {
		return err
	}
	return prove()
}

func (c *Controller) validateInertReplacement(name string, owned *receipt, item *Container) error {
	w := owned.Withdrawal
	if owned.Fence == "" || !matchesWithdrawalIdentity(w, owned.ID, owned.Fence, w.RunnerID, w.RunnerName) || w.RunnerID < 0 || w.WithdrawnAt.IsZero() || w.WithdrawnAt.After(c.now()) {
		return errors.New("inert recovery requires a complete removed owner identity")
	}
	if err := c.validate(item, name); err != nil {
		return err
	}
	if item.ID == owned.ID || !item.NeverStarted || item.Running || item.Paused || item.Exited || !item.RoutingGated || item.RegistrationName != w.RunnerName || !unregisteredName(name, item.RegistrationName) {
		return errors.New("replacement is not an exact gated never-started native owner")
	}
	return nil
}
