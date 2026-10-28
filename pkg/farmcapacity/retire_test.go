// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type fakeRetirementOwner struct {
	*fakePlanningOwner
	routed        bool
	routingErr    error
	raceBusy      bool
	beforeRouting func()
}

func (o *fakeRetirementOwner) WithdrawRetirementRouting(context.Context) error {
	if o.beforeRouting != nil {
		o.beforeRouting()
	}
	if o.routingErr != nil {
		return o.routingErr
	}
	o.routed = true
	return nil
}

func (o *fakeRetirementOwner) Freeze(ctx context.Context) error {
	if o.raceBusy {
		o.busy = true
	}
	return o.fakePlanningOwner.Freeze(ctx)
}

func retirementFixture(t *testing.T) (*Controller, map[string]*fakeRetirementOwner, BindOwner, *time.Time) {
	t.Helper()
	c, old, _, now := pressureFixtureCount(t, 4)
	c.Policy.Pools[buildPool] = sharedcapacity.Pool{Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 1}, Minimum: 4, Maximum: 8, Priority: 1}
	owners := map[string]*fakeRetirementOwner{}
	for id, o := range old {
		retirementDocker(t, c).containers[id].Running = true
		owners[id] = &fakeRetirementOwner{fakePlanningOwner: o}
	}
	bind := func(_ context.Context, name, id string, _ int64, _ string) (OwnerBinding, error) {
		return OwnerBinding{Owner: owners[id], RunnerID: 123, RunnerName: name}, nil
	}
	return c, owners, bind, now
}

func TestRetirementDrainsFloorAfterSettlementWithoutPolicyOrQADemandChanges(t *testing.T) {
	c, owners, bind, now := retirementFixture(t)
	before := retirementStatus(t, c)
	policy := c.Policy
	if err := c.Retire(context.Background(), bind); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	for id, o := range owners {
		if !o.routed || !o.frozen || !o.gone {
			t.Fatal("floor did not enter fenced settlement")
		}
		owned, err := c.load(retirementDocker(t, c).containers[id].Name)
		if err != nil || !owned.Retiring || owned.Withdrawal.Phase != "withdrawn" {
			t.Fatal("retirement intent was not durable", err)
		}
	}
	during := retirementStatus(t, c)
	if len(during.Grants) != 4 {
		t.Fatal("settling retirement freed allocation early")
	}
	*now = now.Add(80 * time.Second)
	if err := c.Retire(context.Background(), bind); err != nil {
		t.Fatal(err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || len(after.Grants) != 0 || len(retirementDocker(t, c).containers) != 0 {
		t.Fatal("retirement did not reach zero", err)
	}
	if !reflect.DeepEqual(before.Pending, after.Pending) || !reflect.DeepEqual(policy, c.Policy) {
		t.Fatal("retirement changed QA demand or policy")
	}
}

func TestRetirementBusyAndUnknownOwnersRemainChargedAndUnpaused(t *testing.T) {
	for _, unknown := range []bool{false, true} {
		c, owners, bind, _ := retirementFixture(t)
		for _, o := range owners {
			o.busy = !unknown
			o.unknown = unknown
		}
		err := c.Retire(context.Background(), bind)
		if err == nil {
			t.Fatal("busy or unknown retirement reported complete")
		}
		for _, o := range owners {
			if !o.routed || o.frozen || o.gone {
				t.Fatal("busy or unknown workload changed")
			}
		}
		status := retirementStatus(t, c)
		if len(status.Grants) != 4 {
			t.Fatal("busy or unknown allocation freed")
		}
	}
}

func TestRetirementPersistsIntentBeforeRoutingAndNeverReopensStart(t *testing.T) {
	c, owners, bind, _ := retirementFixture(t)
	id := strings.Repeat("1", 64)
	name := testName
	owners[id].busy = true
	owners[id].beforeRouting = func() {
		r, err := c.load(name)
		if err != nil || !r.Retiring || r.Withdrawal.RunnerID != 123 {
			t.Fatal("routing preceded durable exact identity")
		}
	}
	if err := c.Retire(context.Background(), bind); err == nil {
		t.Fatal("busy retirement completed")
	}
	if err := c.Start(context.Background(), name, id); err == nil {
		t.Fatal("retiring owner restarted")
	}
	r, err := c.load(name)
	if err != nil || !r.Retiring || r.Withdrawal.Phase != "" {
		t.Fatal("busy intent lost across restart")
	}
	owners[id].routingErr = errors.New("unknown routing outcome")
	if err := c.Retire(context.Background(), bind); err == nil || owners[id].frozen {
		t.Fatal("uncertain routing permitted freeze")
	}
}

func TestRetirementResumesRacingWorkerAndRetainsGrant(t *testing.T) {
	c, owners, bind, _ := retirementFixture(t)
	id := strings.Repeat("1", 64)
	owners[id].raceBusy = true
	if err := c.Retire(context.Background(), bind); !errors.Is(err, sharedcapacity.ErrWorkloadBusy) {
		t.Fatal(err)
	}
	if owners[id].frozen || owners[id].gone {
		t.Fatal("racing worker did not resume")
	}
	status := retirementStatus(t, c)
	if _, ok := status.Grants["build:ci-runner-build-1"]; !ok {
		t.Fatal("racing allocation released")
	}
}

func TestRetirementRejectsChangedFenceAndNativeLimitsBeforeRouting(t *testing.T) {
	for _, limits := range []bool{false, true} {
		c, owners, bind, _ := retirementFixture(t)
		id := strings.Repeat("1", 64)
		name := testName
		if limits {
			retirementDocker(t, c).containers[id].MemoryBytes = 4096 * 1024 * 1024
		} else {
			r, loadErr := c.load(name)
			if loadErr != nil {
				t.Fatal(loadErr)
			}
			r.Fence = "different"
			if err := c.save(name, r); err != nil {
				t.Fatal(err)
			}
		}
		if err := c.Retire(context.Background(), bind); err == nil || owners[id].routed || owners[id].frozen {
			t.Fatal("unknown allocation changed")
		}
	}
}

func retirementDocker(t *testing.T, c *Controller) *fakeDocker {
	t.Helper()
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture native Docker is unavailable")
	}
	return docker
}

func retirementStatus(t *testing.T, c *Controller) sharedcapacity.Snapshot {
	t.Helper()
	status, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	return status
}

func TestOrdinaryWithdrawalCannotUseRetirementIntentToCrossFloor(t *testing.T) {
	c, owners, bind, _ := retirementFixture(t)
	id := strings.Repeat("1", 64)
	for _, o := range owners {
		o.busy = true
	}
	if err := c.Retire(context.Background(), bind); err == nil {
		t.Fatal("busy retirement completed")
	}
	owners[id].busy = false
	if err := c.Withdraw(context.Background(), testName, id, owners[id], 123, testName, c.now()); err == nil || owners[id].frozen {
		t.Fatal("ordinary withdrawal crossed floor")
	}
}

func TestRetirementRejectsChangedRegistrationBeforeRouting(t *testing.T) {
	c, owners, bind, _ := retirementFixture(t)
	for _, o := range owners {
		o.busy = true
	}
	if err := c.Retire(context.Background(), bind); err == nil {
		t.Fatal("busy retirement completed")
	}
	for _, o := range owners {
		o.routed = false
	}
	changed := func(ctx context.Context, name, id string, runnerID int64, runnerName string) (OwnerBinding, error) {
		b, err := bind(ctx, name, id, runnerID, runnerName)
		if err != nil {
			return b, err
		}
		b.RunnerID = 124
		return b, nil
	}
	if err := c.Retire(context.Background(), changed); err == nil {
		t.Fatal("changed registration accepted")
	}
	for _, o := range owners {
		if o.routed || o.frozen {
			t.Fatal("changed registration had lifecycle effects")
		}
	}
}
