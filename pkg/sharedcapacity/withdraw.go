// Package sharedcapacity preserves durable withdrawal phases until exact owners stop.
package sharedcapacity

import (
	"context"
	"errors"
	"time"
)

var (
	// ErrWithdrawalWaiting means admission is closed but pickup must settle.
	ErrWithdrawalWaiting = errors.New("idle withdrawal is waiting for job pickup to settle")
	// ErrWorkloadBusy retains the allocation and resumes its listener.
	ErrWorkloadBusy = errors.New("workload became busy during idle withdrawal")
)

const (
	withdrawFreezeIntent = "freeze_intent"
	withdrawFrozen       = "frozen"
	withdrawRemoteIntent = "withdraw_intent"
	withdrawRemoteGone   = "withdrawn"
	withdrawRemoveIntent = "remove_intent"
	withdrawRemoved      = "removed"
	// GitHub requeues unpicked assignments after 60 seconds. Allow margin after
	// confirmed remote removal; no new assignments can enter that identity.
	pickupSettlement = 75 * time.Second
)

// Withdrawal is persisted by the immutable owner before every uncertain effect.
// The remote identity and grant fence never change during a withdrawal attempt.
type Withdrawal struct {
	ContainerID  string    `json:"containerId"`
	Fence        string    `json:"fence"`
	RunnerID     int64     `json:"runnerId"`
	RunnerName   string    `json:"runnerName"`
	Unregistered bool      `json:"unregistered,omitempty"`
	Phase        string    `json:"phase"`
	WithdrawnAt  time.Time `json:"withdrawnAt,omitzero"`
}

// WithdrawalOwner must bind every operation to the same immutable container and
// attested GitHub registration. FrozenIdle positively proves the container is
// frozen, no Runner.Worker exists, and a Runner.Listener exists; an exact
// positively exited container with PID zero also proves pickup is closed. False means
// busy; errors mean unknown. RemoveFrozen never thaws before removal.
type WithdrawalOwner interface {
	Freeze(context.Context) error
	FrozenIdle(context.Context) (bool, error)
	Resume(context.Context) error
	RemoteIdle(context.Context) (bool, error)
	WithdrawRemote(context.Context) error
	RemoteGone(context.Context) (bool, error)
	RemoveFrozen(context.Context) error
	Removed(context.Context) (bool, error)
}

// AdvanceWithdrawal takes one bounded step while the caller holds its owner
// lifecycle lock. It never frees a grant; the owner releases only after its
// exact container is proven absent. Failures and uncertain effects stay charged.
func AdvanceWithdrawal(ctx context.Context, withdrawal *Withdrawal, owner WithdrawalOwner, now time.Time, save func() error) error {
	if withdrawal == nil || owner == nil || save == nil || withdrawal.ContainerID == "" || withdrawal.Fence == "" || withdrawal.RunnerName == "" || now.IsZero() ||
		!validWithdrawalRegistration(withdrawal) {
		return errors.New("idle withdrawal requires a complete fenced owner identity")
	}
	if withdrawal.Phase == withdrawRemoveIntent {
		done, recoveryErr := recoverRemovedWithdrawal(ctx, withdrawal, owner, save)
		if recoveryErr != nil || done {
			return recoveryErr
		}
		withdrawal.Phase = withdrawRemoteGone
	}
	switch withdrawal.Phase {
	case "", withdrawFreezeIntent:
		withdrawal.Phase = withdrawFreezeIntent
		if err := save(); err != nil {
			return err
		}
		if err := owner.Freeze(ctx); err != nil {
			return err
		}
		withdrawal.Phase = withdrawFrozen
		if err := save(); err != nil {
			return err
		}
	case withdrawFrozen, withdrawRemoteIntent, withdrawRemoteGone:
		// Continue only through positive ownership and local idle proof below.

	case withdrawRemoved:
		return nil
	default:
		return errors.New("unknown idle withdrawal phase")
	}
	if err := requireFrozenIdle(ctx, withdrawal, owner, save); err != nil {
		return err
	}
	if withdrawal.Phase == withdrawFrozen || withdrawal.Phase == withdrawRemoteIntent {
		if err := withdrawRemote(ctx, withdrawal, owner, now, save); err != nil {
			return err
		}
	}
	return finishWithdrawal(ctx, withdrawal, owner, now, save)
}

func finishWithdrawal(ctx context.Context, withdrawal *Withdrawal, owner WithdrawalOwner, now time.Time, save func() error) error {
	if withdrawal.WithdrawnAt.IsZero() || withdrawal.WithdrawnAt.After(now) {
		return errors.New("idle withdrawal settlement time is invalid")
	}
	if now.Sub(withdrawal.WithdrawnAt) < pickupSettlement {
		return ErrWithdrawalWaiting
	}
	if err := requireFrozenIdle(ctx, withdrawal, owner, save); err != nil {
		return err
	}
	gone, err := owner.RemoteGone(ctx)
	if err != nil {
		return err
	}
	if !gone {
		return errors.New("withdrawn GitHub identity reappeared")
	}
	withdrawal.Phase = withdrawRemoveIntent
	if err := save(); err != nil {
		return err
	}
	if err := owner.RemoveFrozen(ctx); err != nil {
		return err
	}
	withdrawal.Phase = withdrawRemoved
	return save()
}

func requireFrozenIdle(ctx context.Context, withdrawal *Withdrawal, owner WithdrawalOwner, save func() error) error {
	idle, err := owner.FrozenIdle(ctx)
	if err != nil {
		return err
	}
	if idle {
		return nil
	}
	// A worker that won the freeze race keeps its grant and continues. A remote
	// identity already withdrawn cannot safely resume, so retain it for recovery.
	if withdrawal.Phase == withdrawRemoteGone || withdrawal.Phase == withdrawRemoteIntent {
		return errors.New("worker found after idle withdrawal intent; preserve frozen owner")
	}
	if err := owner.Resume(ctx); err != nil {
		return err
	}
	withdrawal.Phase = ""
	if err := save(); err != nil {
		return err
	}
	return ErrWorkloadBusy
}

func withdrawRemote(ctx context.Context, withdrawal *Withdrawal, owner WithdrawalOwner, now time.Time, save func() error) error {
	if withdrawal.Phase == withdrawRemoteIntent {
		gone, err := owner.RemoteGone(ctx)
		if err != nil {
			return err
		}
		if gone {
			return recordWithdrawal(withdrawal, now, save)
		}
	}
	idle, err := owner.RemoteIdle(ctx)
	if err != nil {
		return err
	}
	if !idle {
		if withdrawal.Phase == withdrawRemoteIntent {
			return errors.New("remote assignment found after idle withdrawal intent; preserve frozen owner")
		}
		if resumeErr := owner.Resume(ctx); resumeErr != nil {
			return resumeErr
		}
		withdrawal.Phase = ""
		if saveErr := save(); saveErr != nil {
			return saveErr
		}
		return ErrWorkloadBusy
	}
	withdrawal.Phase = withdrawRemoteIntent
	if saveErr := save(); saveErr != nil {
		return saveErr
	}
	if withdrawErr := owner.WithdrawRemote(ctx); withdrawErr != nil {
		return withdrawErr
	}
	gone, err := owner.RemoteGone(ctx)
	if err != nil {
		return err
	}
	if !gone {
		return errors.New("GitHub idle withdrawal was not confirmed")
	}
	return recordWithdrawal(withdrawal, now, save)
}

func recordWithdrawal(withdrawal *Withdrawal, now time.Time, save func() error) error {
	withdrawal.Phase = withdrawRemoteGone
	withdrawal.WithdrawnAt = now
	return save()
}

func recoverRemovedWithdrawal(ctx context.Context, withdrawal *Withdrawal, owner WithdrawalOwner, save func() error) (bool, error) {
	removed, err := owner.Removed(ctx)
	if err != nil {
		return false, err
	}
	if !removed {
		return false, nil
	}
	gone, err := owner.RemoteGone(ctx)
	if err != nil {
		return false, err
	}
	if !gone {
		return false, errors.New("removed owner still has a GitHub registration")
	}
	withdrawal.Phase = withdrawRemoved
	return true, save()
}

func validWithdrawalRegistration(withdrawal *Withdrawal) bool {
	if withdrawal.Unregistered {
		return withdrawal.RunnerID == 0
	}
	return withdrawal.RunnerID > 0
}
