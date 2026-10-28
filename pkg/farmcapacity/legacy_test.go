// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type legacyPlanningOwner struct {
	*fakePlanningOwner
	routingClosed bool
	routingErr    error
}

func (o *legacyPlanningOwner) WithdrawLegacyRouting(context.Context) error {
	if o.unknown {
		return errors.New("routing status unknown")
	}
	if o.routingErr != nil {
		return o.routingErr
	}
	o.routingClosed = true
	return nil
}

func legacyFixture(t *testing.T) (*LegacyDrain, *legacyPlanningOwner, *time.Time) {
	t.Helper()
	now := time.Now().UTC()
	id := strings.Repeat("b", 64)
	docker := &fakeDocker{containers: map[string]*Container{id: {ID: id, Name: "ci-runner-1", Managed: true, Provider: githubProvider, Role: runnerRole, Pool: legacyDefaultPool, Running: true, MemoryBytes: 16 << 30, NanoCPUs: 4_000_000_000}}}
	owner := &legacyPlanningOwner{fakePlanningOwner: &fakePlanningOwner{docker: docker, id: id}}
	drain := &LegacyDrain{Root: filepath.Join(t.TempDir(), "legacy"), Docker: docker, Now: func() time.Time { return now }, Bind: func(context.Context, Container, *sharedcapacity.Withdrawal) (OwnerBinding, error) {
		return OwnerBinding{Owner: owner, RunnerID: 123, RunnerName: "DEVSTAR-1-ci-runner-1"}, nil
	}}
	return drain, owner, &now
}

func TestLegacyDrainRetainsBusyAndUnknownWorkers(t *testing.T) {
	for _, mode := range []string{"worker-active", "api-uncertain"} {
		t.Run(mode, func(t *testing.T) {
			d, o, _ := legacyFixture(t)
			o.busy = mode == "worker-active"
			o.unknown = mode == "api-uncertain"
			if err := d.Run(context.Background()); err == nil {
				t.Fatal("unsafe owner accepted")
			}
			if o.frozen || o.gone || len(o.docker.containers) != 1 {
				t.Fatal("busy/unknown owner mutated")
			}
			entries, err := os.ReadDir(d.Root)
			if err != nil || len(entries) != 1 {
				t.Fatal("exact retirement identity was not retained")
			}
		})
	}
}

func TestLegacyDrainSurvivesRestartAndSettlesBeforeExactRemoval(t *testing.T) {
	d, o, now := legacyFixture(t)
	if err := d.Run(context.Background()); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatalf("expected settlement: %v", err)
	}
	w, err := d.load("ci-runner-1")
	if err != nil || w.Phase != "withdrawn" || !o.frozen || !o.gone {
		t.Fatal("durable frozen intent missing")
	}
	copyDrain := *d
	*now = now.Add(74 * time.Second)
	if err := copyDrain.Run(context.Background()); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatalf("removed too soon: %v", err)
	}
	*now = now.Add(time.Second)
	if err := copyDrain.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(o.docker.containers) != 0 {
		t.Fatal("old owner retained after safe settlement")
	}
	if err := copyDrain.Run(context.Background()); err != nil {
		t.Fatal("terminal receipt replay failed", err)
	}
}

func TestLegacyDrainRejectsReplacementAndSymlinkReceipt(t *testing.T) {
	d, o, _ := legacyFixture(t)
	if err := d.Run(context.Background()); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	o.docker.containers[o.id].ID = strings.Repeat("c", 64)
	if err := d.Run(context.Background()); err == nil {
		t.Fatal("replacement identity accepted")
	}
	o.docker.containers[o.id].ID = o.id
	path := filepath.Join(d.Root, "ci-runner-1.json")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/dev/null", path); err != nil {
		t.Fatal(err)
	}
	if err := d.Run(context.Background()); err == nil {
		t.Fatal("symlink accepted")
	}
}

func TestLegacyRetirementDoesNotEnableSharedStartOrAdoption(t *testing.T) {
	d, o, _ := legacyFixture(t)
	item := o.docker.containers[o.id]
	if !ownedLegacyBuild(item) {
		t.Fatal("legacy identity rejected")
	}
	c, _, _ := fixture(t)
	if err := c.validate(item, item.Name); err == nil {
		t.Fatal("legacy slot admitted to new broker")
	}
	item.Pool = "build"
	if ownedLegacyBuild(item) {
		t.Fatal("foreign pool accepted")
	}
	item.Pool = legacyDefaultPool
	item.Name = "ci-runner-9"
	if ownedLegacyBuild(item) {
		t.Fatal("unbounded slot accepted")
	}
	_ = d
}

type legacyBusyRace struct{ *legacyPlanningOwner }

func (o *legacyBusyRace) Freeze(ctx context.Context) error {
	o.busy = true
	return o.legacyPlanningOwner.Freeze(ctx)
}

func TestLegacyDrainBusyPickupRaceResumesAndRetainsOwner(t *testing.T) {
	d, o, _ := legacyFixture(t)
	d.Bind = func(context.Context, Container, *sharedcapacity.Withdrawal) (OwnerBinding, error) {
		return OwnerBinding{Owner: &legacyBusyRace{o}, RunnerID: 123, RunnerName: "DEVSTAR-1-ci-runner-1"}, nil
	}
	if err := d.Run(context.Background()); !errors.Is(err, sharedcapacity.ErrWorkloadBusy) {
		t.Fatal(err)
	}
	if o.frozen || o.gone || len(o.docker.containers) != 1 {
		t.Fatal("racing worker was withdrawn")
	}
}

func TestLegacyDrainRecoversRemovalAfterLostReceiptWrite(t *testing.T) {
	d, o, now := legacyFixture(t)
	if err := d.Run(context.Background()); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	w, err := d.load("ci-runner-1")
	if err != nil {
		t.Fatal(err)
	}
	w.Phase = "remove_intent"
	if saveErr := d.save("ci-runner-1", w); saveErr != nil {
		t.Fatal(saveErr)
	}
	delete(o.docker.containers, o.id)
	*now = now.Add(80 * time.Second)
	if runErr := d.Run(context.Background()); runErr != nil {
		t.Fatal(runErr)
	}
	w, err = d.load("ci-runner-1")
	if err != nil || w.Phase != withdrawalRemovedPhase {
		t.Fatal("uncertain removal not settled", err)
	}
}
