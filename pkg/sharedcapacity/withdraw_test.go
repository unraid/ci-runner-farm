package sharedcapacity

import (
	"context"
	"errors"
	"testing"
	"time"
)

type fakeWithdrawalOwner struct {
	frozen          bool
	localBusy       bool
	remoteBusy      bool
	remoteMissing   bool
	removed         bool
	unknown         bool
	removeUncertain bool
	resumes         int
	deletes         int
}

func (o *fakeWithdrawalOwner) Freeze(context.Context) error { o.frozen = true; return nil }
func (o *fakeWithdrawalOwner) FrozenIdle(context.Context) (bool, error) {
	if o.unknown || !o.frozen {
		return false, errors.New("unknown")
	}
	return !o.localBusy, nil
}

func (o *fakeWithdrawalOwner) Resume(context.Context) error {
	o.frozen = false
	o.resumes++
	return nil
}

func (o *fakeWithdrawalOwner) RemoteIdle(context.Context) (bool, error) {
	if o.unknown {
		return false, errors.New("unknown")
	}
	return !o.remoteBusy, nil
}

func (o *fakeWithdrawalOwner) WithdrawRemote(context.Context) error {
	o.remoteMissing = true
	o.deletes++
	return nil
}

func (o *fakeWithdrawalOwner) RemoteGone(context.Context) (bool, error) {
	if o.unknown {
		return false, errors.New("unknown")
	}
	return o.remoteMissing, nil
}

func (o *fakeWithdrawalOwner) RemoveFrozen(context.Context) error {
	if !o.frozen || o.localBusy || !o.remoteMissing {
		return errors.New("unsafe remove")
	}
	o.removed = true
	if o.removeUncertain {
		return errors.New("timeout after remove")
	}
	return nil
}
func (o *fakeWithdrawalOwner) Removed(context.Context) (bool, error) { return o.removed, nil }

func withdrawalFixture() Withdrawal {
	return Withdrawal{ContainerID: "owned-container", Fence: "owned-fence", RunnerID: 123, RunnerName: "owned-runner"}
}

func TestWithdrawalRejectsConflictingRegistrationModes(t *testing.T) {
	for _, unregistered := range []bool{false, true} {
		withdrawal := withdrawalFixture()
		withdrawal.Unregistered = unregistered
		if !unregistered {
			withdrawal.RunnerID = 0
		}
		owner := &fakeWithdrawalOwner{}
		if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, time.Now(), func() error { return nil }); err == nil || owner.frozen {
			t.Fatal("conflicting registration mode authorized effects")
		}
	}
}

func TestWithdrawalBusyRaceResumesWithoutDeletingOrReleasing(t *testing.T) {
	for _, local := range []bool{true, false} {
		owner := &fakeWithdrawalOwner{localBusy: local, remoteBusy: !local}
		withdrawal := withdrawalFixture()
		err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, time.Now(), func() error { return nil })
		if !errors.Is(err, ErrWorkloadBusy) || owner.frozen || owner.resumes != 1 || owner.deletes != 0 || owner.removed {
			t.Fatalf("busy workload changed: %+v %v", owner, err)
		}
	}
}

func TestWithdrawalPersistsBeforeEffectsAndWaitsAfterRemoteRemoval(t *testing.T) {
	owner := &fakeWithdrawalOwner{}
	withdrawal := withdrawalFixture()
	now := time.Now().UTC()
	phases := []string{}
	save := func() error { phases = append(phases, withdrawal.Phase); return nil }
	if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, now, save); !errors.Is(err, ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	if len(phases) != 4 || phases[0] != withdrawFreezeIntent || phases[2] != withdrawRemoteIntent || !owner.remoteMissing || owner.removed {
		t.Fatalf("effect boundary differs: %v", phases)
	}
	if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, now.Add(60*time.Second), save); !errors.Is(err, ErrWithdrawalWaiting) {
		t.Fatal("pickup margin bypassed")
	}
	if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, now.Add(75*time.Second), save); err != nil {
		t.Fatal(err)
	}
	if !owner.removed || owner.deletes != 1 || owner.resumes != 0 {
		t.Fatal("withdrawal repeated or thawed listener")
	}
}

func TestWithdrawalUnknownAndCrashRecoveryRetainOwnership(t *testing.T) {
	owner := &fakeWithdrawalOwner{}
	withdrawal := withdrawalFixture()
	now := time.Now().UTC()
	save := func() error { return nil }
	if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, now, save); !errors.Is(err, ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	owner.unknown = true
	if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, now.Add(time.Minute*2), save); err == nil || owner.removed || owner.resumes != 0 {
		t.Fatal("unknown owner released")
	}
	owner.unknown = false
	owner.removeUncertain = true
	if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, now.Add(time.Minute*2), save); err == nil {
		t.Fatal("uncertain removal accepted")
	}
	if withdrawal.Phase != withdrawRemoveIntent {
		t.Fatal("removal intent lost")
	}
	if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, now.Add(time.Minute*3), save); err != nil || withdrawal.Phase != withdrawRemoved {
		t.Fatalf("exact removal not recovered: %v", err)
	}
}

func TestWithdrawalMissingSaveNeverCrossesEffectBoundary(t *testing.T) {
	owner := &fakeWithdrawalOwner{}
	withdrawal := withdrawalFixture()
	if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, time.Now(), func() error { return errors.New("disk full") }); err == nil || owner.frozen || owner.deletes != 0 {
		t.Fatal("effect preceded durable intent")
	}
}

func TestWithdrawalWorkerAfterRemoteIntentFailsClosed(t *testing.T) {
	for _, phase := range []string{withdrawRemoteIntent, withdrawRemoteGone} {
		owner := &fakeWithdrawalOwner{frozen: true, localBusy: true}
		withdrawal := withdrawalFixture()
		withdrawal.Phase = phase
		if err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, time.Now(), func() error { return nil }); err == nil || owner.resumes != 0 || owner.removed {
			t.Fatal("ambiguous worker resumed or removed")
		}
	}
}

func TestWithdrawalRemoteBusyAfterIntentRetainsFrozenOwner(t *testing.T) {
	owner := &fakeWithdrawalOwner{frozen: true, remoteBusy: true}
	withdrawal := withdrawalFixture()
	withdrawal.Phase = withdrawRemoteIntent
	original := withdrawal
	saves := 0
	err := AdvanceWithdrawal(context.Background(), &withdrawal, owner, time.Now(), func() error { saves++; return nil })
	if err == nil || errors.Is(err, ErrWorkloadBusy) || !owner.frozen || owner.resumes != 0 || owner.deletes != 0 || owner.removed || withdrawal != original || saves != 0 {
		t.Fatal("ambiguous remote assignment was reported as resumed or changed ownership", owner, withdrawal, saves, err)
	}
}
