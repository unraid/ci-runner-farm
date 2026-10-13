// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const testName = "ci-runner-build-1"

type fakeDocker struct {
	containers map[string]*Container
	startErr   error
	inspectErr error
	starts     int
}

func (d *fakeDocker) Inspect(_ context.Context, identity string) (*Container, error) {
	if d.inspectErr != nil {
		return nil, d.inspectErr
	}
	for _, container := range d.containers {
		if container.ID == identity || container.Name == identity {
			return container, nil
		}
	}
	return nil, ErrContainerMissing
}

func (d *fakeDocker) Start(_ context.Context, id string) error {
	d.starts++
	if d.startErr != nil {
		return d.startErr
	}
	d.containers[id].Running = true
	return nil
}

func fixture(t *testing.T) (*Controller, *fakeDocker, string) {
	t.Helper()
	id := strings.Repeat("a", 64)
	docker := &fakeDocker{containers: map[string]*Container{id: {ID: id, Name: testName, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000}}}
	root := t.TempDir()
	controller := &Controller{
		Broker: sharedcapacity.Broker{Path: filepath.Join(root, "shared-capacity.bolt")},
		Policy: sharedcapacity.Policy{
			Budget: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 1}, AgingSeconds: 60,
			Pools: map[string]sharedcapacity.Pool{buildPool: {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 1}, Maximum: 1}},
		},
		ReceiptRoot: filepath.Join(root, "receipts"), Docker: docker,
	}
	if err := controller.Broker.Initialize(&controller.Policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	return controller, docker, id
}

func TestUncertainStartKeepsGrantAcrossRestartAndRejectsReplacement(t *testing.T) {
	c, d, id := fixture(t)
	ctx := context.Background()
	d.startErr = errors.New("timeout")
	if err := c.Start(ctx, testName, id); err == nil {
		t.Fatal("uncertain start accepted")
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil || len(before.Grants) != 1 {
		t.Fatalf("allocation lost: %v", err)
	}
	d.startErr = nil
	restarted := *c
	if restartErr := restarted.Start(ctx, testName, id); restartErr != nil {
		t.Fatal(restartErr)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || after.Grants["build:"+testName].Fence != before.Grants["build:"+testName].Fence {
		t.Fatal("restart changed grant")
	}
	newID := strings.Repeat("b", 64)
	d.containers[newID] = &Container{ID: newID, Name: testName, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000}
	if err := c.Start(ctx, testName, newID); err == nil {
		t.Fatal("replacement replayed old grant")
	}
}

func TestReleaseRequiresExactRemovalAndDockerProof(t *testing.T) {
	c, d, id := fixture(t)
	ctx := context.Background()
	if err := c.Start(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	if err := c.Release(ctx, testName, id); err == nil {
		t.Fatal("running owner released")
	}
	delete(d.containers, id)
	d.inspectErr = errors.New("daemon unavailable")
	if err := c.Release(ctx, testName, id); err == nil {
		t.Fatal("inspect error counted as removal")
	}
	d.inspectErr = nil
	if err := c.Release(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 0 {
		t.Fatal("removed owner stayed charged")
	}
	if err := c.Release(ctx, testName, id); err == nil {
		t.Fatal("stale release accepted")
	}
}

func TestQueueRetryPreservesAgeAndNeverStartsWithoutBudget(t *testing.T) {
	c, d, id := fixture(t)
	decision, err := c.Broker.Admit(&c.Policy, sharedcapacity.Request{ID: "other", Pool: buildPool})
	if err != nil || !decision.Admitted {
		t.Fatal(err)
	}
	for range 2 {
		if err := c.Start(context.Background(), testName, id); !errors.Is(err, ErrQueued) {
			t.Fatalf("queue: %v", err)
		}
	}
	if d.starts != 0 {
		t.Fatal("queued build started")
	}
	before, beforeErr := c.Broker.Status(&c.Policy)
	if beforeErr != nil {
		t.Fatal(beforeErr)
	}
	if err := c.Broker.Release(&c.Policy, "other", decision.Grant.Fence, func(sharedcapacity.Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if err := c.Start(context.Background(), testName, id); err != nil {
		t.Fatal(err)
	}
	after, afterErr := c.Broker.Status(&c.Policy)
	if afterErr != nil {
		t.Fatal(afterErr)
	}
	if before.Pending["build:"+testName].QueuedAt.IsZero() || len(after.Pending) != 0 || d.starts != 1 {
		t.Fatal("queued request not reconciled")
	}
}

func TestOwnershipAndLimitsFailBeforeCharging(t *testing.T) {
	for _, change := range []func(*Container){
		func(item *Container) { item.MemoryBytes = 0 },
		func(item *Container) { item.NanoCPUs = 2_000_000_000 },
		func(item *Container) { item.Pool = "qa" },
		func(item *Container) { item.Managed = false },
		func(item *Container) { item.Running = true },
	} {
		c, d, id := fixture(t)
		change(d.containers[id])
		if err := c.Start(context.Background(), testName, id); err == nil {
			t.Fatal("unsafe container started")
		}
		snapshot, err := c.Broker.Status(&c.Policy)
		if err != nil || len(snapshot.Grants) != 0 || d.starts != 0 {
			t.Fatal("unsafe container charged")
		}
	}
}

func TestReleaseResumesAfterGrantCommitBeforeReceiptRemoval(t *testing.T) {
	c, d, id := fixture(t)
	ctx := context.Background()
	if err := c.Start(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	if err := c.PrepareRelease(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	delete(d.containers, id)
	if err = c.Broker.Release(&c.Policy, "build:"+testName, owned.Fence, func(sharedcapacity.Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if err = c.Release(ctx, testName, id); err != nil {
		t.Fatal("release committed but receipt cleanup cannot resume", err)
	}
	if _, err = c.load(testName); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("receipt remains", err)
	}
}
func TestReleaseIntentRequiresNoGrantOrPendingRequest(t *testing.T) {
	c, _, id := fixture(t)
	ctx := context.Background()
	if err := c.Start(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	owned.ReleasePending = true
	for _, live := range []string{"grant", "pending", "none"} {
		snapshot := sharedcapacity.Snapshot{Grants: map[string]sharedcapacity.Grant{}, Pending: map[string]sharedcapacity.Pending{}}
		if live == "grant" {
			snapshot.Grants["build:"+testName] = sharedcapacity.Grant{}
		}
		if live == "pending" {
			snapshot.Pending["build:"+testName] = sharedcapacity.Pending{}
		}
		if completedRelease("build:"+testName, owned, &snapshot) != (live == "none") {
			t.Fatalf("intent completion with %s", live)
		}
	}
}

func TestReleaseRejectsMissingGrantWithoutPriorIntent(t *testing.T) {
	c, d, id := fixture(t)
	ctx := context.Background()
	if err := c.Start(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	delete(d.containers, id)
	if err = c.Broker.Release(&c.Policy, "build:"+testName, owned.Fence, func(sharedcapacity.Grant) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if err = c.Release(ctx, testName, id); err == nil {
		t.Fatal("unexplained lost grant accepted")
	}
	after, err := c.load(testName)
	if err != nil || after.ReleasePending {
		t.Fatal("missing grant manufactured release intent", err)
	}
}
