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

const endpointCollision = "Docker build start did not complete: failed to set up container networking: endpoint with name ci-runner-build-1 already exists in network ci-runner-net"

// failedStartFixture leaves two inert gated builders on a host whose measured
// headroom fits one start beside the reserve, but not two shadow charges.
func failedStartFixture(t *testing.T) (controller *Controller, nativeDocker *fakeDocker, first, second string) {
	t.Helper()
	root := t.TempDir()
	first, second = strings.Repeat("a", 64), strings.Repeat("b", 64)
	nativeDocker = &fakeDocker{containers: map[string]*Container{}}
	for id, name := range map[string]string{first: testName, second: demandSlotName(buildPool, 2)} {
		nativeDocker.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: time.Now().Unix(), DockerRoot: "/mnt/cache/docker/" + name}
	}
	controller = &Controller{
		Broker: sharedcapacity.Broker{Path: filepath.Join(root, "shared-capacity.bolt"), ObserveMemory: func() (sharedcapacity.MemoryObservation, error) {
			return sharedcapacity.MemoryObservation{AvailableMiB: 20480, ObservedAt: time.Now().UTC()}, nil
		}},
		Policy: sharedcapacity.Policy{
			Budget: sharedcapacity.Resources{MemoryMiB: 2 * 12288, VCPUs: 2}, AgingSeconds: 60, CPUAdmission: sharedcapacity.CPUAdmissionSoft,
			BuildMemoryOvercommit: &sharedcapacity.BuildMemoryOvercommit{AdditionalMiB: 12288, MinimumAvailableMiB: 1024}, SharedMemoryHeadroom: true,
			Pools: map[string]sharedcapacity.Pool{buildPool: {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 1}, Maximum: 2}},
		},
		ReceiptRoot: filepath.Join(root, "receipts"), Docker: nativeDocker,
		// Nothing ran in a never-started owner; release must keep its cache.
		RepairCache: func(context.Context, string, string) error { return errors.New("never-started cache was repaired") },
	}
	if err := controller.Broker.Initialize(&controller.Policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	return controller, nativeDocker, first, second
}

func requireRetainedFailedStart(t *testing.T, c *Controller, docker *fakeDocker, id string, before *sharedcapacity.Snapshot) {
	t.Helper()
	after, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	requestID := "build:" + testName
	if after.Grants[requestID] != before.Grants[requestID] || after.Starts[requestID] != before.Starts[requestID] || after.Starts[requestID].MemoryMiB != 12288 {
		t.Fatal("unproved owner lost its grant or shadow charge")
	}
	if docker.containers[id] == nil {
		t.Fatal("unproved owner was removed")
	}
}

func TestProvedFailedStartReleasesChargeForReplacementAndUnblocksAdmission(t *testing.T) {
	c, docker, first, second := failedStartFixture(t)
	docker.startErr = errors.New(endpointCollision)
	err := c.Start(t.Context(), testName, first)
	if !errors.Is(err, ErrStartReplaced) || errors.Is(err, ErrQueued) || !strings.Contains(err.Error(), "already exists in network ci-runner-net") {
		t.Fatal("proved failed start was not replaced with its Docker cause", err)
	}
	if docker.containers[first] != nil {
		t.Fatal("never-started owner remains")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 0 || len(snapshot.Starts) != 0 || len(snapshot.Pending) != 0 {
		t.Fatal("failed start kept its grant, shadow charge or demand", err)
	}
	if _, err = c.load(testName); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("released receipt remains", err)
	}
	// The released shadow charge no longer holds the next start below headroom.
	docker.startErr = nil
	if err = c.Start(t.Context(), demandSlotName(buildPool, 2), second); err != nil || !docker.containers[second].Running {
		t.Fatal("released charge still blocked admission", err)
	}
	// The native owner recreates the slot as a fresh owner with a new fence.
	replacement := strings.Repeat("c", 64)
	docker.containers[replacement] = &Container{ID: replacement, Name: testName, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: time.Now().Unix()}
	if err = c.Start(t.Context(), testName, replacement); !errors.Is(err, ErrQueued) {
		t.Fatal("replacement bypassed admission", err)
	}
	owned, err := c.load(testName)
	if err != nil || owned.ID != replacement || owned.Fence != "" || owned.ReleasePending {
		t.Fatal("replacement did not bind a fresh unfenced receipt", err)
	}
}

func TestUnprovedFailedStartRetainsGrantAndCharge(t *testing.T) {
	for _, mode := range []string{"inspect-unavailable", "deadline-expired"} {
		t.Run(mode, func(t *testing.T) {
			c, docker, first, second := failedStartFixture(t)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			var before sharedcapacity.Snapshot
			docker.startErr = errors.New("Docker build start did not complete")
			docker.onFailedStart = func() {
				var err error
				if before, err = c.Broker.Status(&c.Policy); err != nil {
					t.Fatal(err)
				}
				if mode == "deadline-expired" {
					cancel()
				} else {
					docker.inspectErr = errors.New("daemon unavailable")
				}
			}
			if err := c.Start(ctx, testName, first); err == nil || errors.Is(err, ErrStartReplaced) {
				t.Fatal("unproved start outcome was replaced", err)
			}
			requireRetainedFailedStart(t, c, docker, first, &before)
			owned, err := c.load(testName)
			if err != nil || owned.ReleasePending || owned.ReplacementPrepared {
				t.Fatal("unproved start recorded removal intent", err)
			}
			// The retained charge keeps the next start waiting, as before.
			docker.startErr, docker.inspectErr = nil, nil
			if err := c.Start(t.Context(), demandSlotName(buildPool, 2), second); !errors.Is(err, ErrQueued) || docker.containers[second].Running {
				t.Fatal("retained charge was not counted", err)
			}
		})
	}
}

func TestFailedStartLeavesStartedOrChangedOwnerUntouched(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(*Container)
	}{
		{"running", func(item *Container) { item.Running = true }},
		{"paused", func(item *Container) { item.Paused = true }},
		{"started-and-exited", func(item *Container) { item.NeverStarted, item.Exited = false, true }},
		{"renamed", func(item *Container) { item.Name = testName + "-epfix" }},
		{"ungated", func(item *Container) { item.RoutingGated = false }},
	} {
		t.Run(test.name, func(t *testing.T) {
			c, docker, first, _ := failedStartFixture(t)
			var before sharedcapacity.Snapshot
			docker.startErr = errors.New(endpointCollision)
			docker.onFailedStart = func() {
				var err error
				if before, err = c.Broker.Status(&c.Policy); err != nil {
					t.Fatal(err)
				}
				test.mutate(docker.containers[first])
			}
			if err := c.Start(t.Context(), testName, first); err == nil || errors.Is(err, ErrStartReplaced) {
				t.Fatal("started or changed owner was replaced", err)
			}
			requireRetainedFailedStart(t, c, docker, first, &before)
		})
	}
}

func TestFailedStartRecoveryRequiresExactFenceAndInertOwners(t *testing.T) {
	const fenceMismatch = "fence-mismatch"
	for _, test := range []struct {
		mode    string
		refused bool
	}{
		{"resume", false}, {collisionCompleted, false}, {"inert-replacement", false},
		{fenceMismatch, true}, {"foreign-name", true}, {"started-replacement", true},
	} {
		t.Run(test.mode, func(t *testing.T) {
			c, docker, first, _ := failedStartFixture(t)
			native := &collisionDocker{fakeDocker: docker, removeErr: errors.New("removal did not complete")}
			c.Docker = native
			docker.startErr = errors.New(endpointCollision)
			// A failed removal leaves durable intent exactly like a crash would.
			if err := c.Start(t.Context(), testName, first); err == nil || errors.Is(err, ErrStartReplaced) {
				t.Fatal("incomplete replacement reported success", err)
			}
			owned, err := c.load(testName)
			if err != nil || !owned.ReleasePending || !owned.ReplacementPrepared || !owned.PreserveCache || owned.Fence == "" {
				t.Fatal("failed start intent was not durable before removal", err)
			}
			before, err := c.Broker.Status(&c.Policy)
			if err != nil {
				t.Fatal(err)
			}
			native.removeErr = nil
			replacement := strings.Repeat("c", 64)
			item := &Container{ID: replacement, Name: testName, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: time.Now().Unix()}
			switch test.mode {
			case collisionCompleted:
				delete(docker.containers, first)
				if err = c.Broker.Release(&c.Policy, "build:"+testName, owned.Fence, func(sharedcapacity.Grant) error { return nil }); err != nil {
					t.Fatal(err)
				}
			case "inert-replacement":
				delete(docker.containers, first)
				docker.containers[replacement] = item
				// Pending intent refuses admission of the fresh container.
				if err = c.Start(t.Context(), testName, replacement); err == nil || docker.starts != 1 {
					t.Fatal("replacement was admitted under pending intent", err)
				}
			case fenceMismatch:
				owned.Fence = "stale"
				if err = c.save(testName, owned); err != nil {
					t.Fatal(err)
				}
			case "foreign-name":
				delete(docker.containers, first)
				item.Managed = false
				docker.containers[replacement] = item
			case "started-replacement":
				delete(docker.containers, first)
				item.NeverStarted, item.Running = false, true
				docker.containers[replacement] = item
			}
			recoveryErr := c.recoverReleasedOwners(t.Context(), &before, nil)
			after, err := c.Broker.Status(&c.Policy)
			if err != nil {
				t.Fatal(err)
			}
			if test.refused {
				if recoveryErr == nil || after.Grants["build:"+testName] != before.Grants["build:"+testName] || after.Starts["build:"+testName].MemoryMiB != 12288 {
					t.Fatal("unproved recovery released the allocation", recoveryErr)
				}
				if (test.mode == fenceMismatch && docker.containers[first] == nil) || (test.mode != fenceMismatch && docker.containers[replacement] == nil) || native.removes != 1 {
					t.Fatal("unproved recovery removed an owner", native.removes)
				}
				return
			}
			if recoveryErr != nil || len(after.Grants) != 0 || len(after.Starts) != 0 || docker.containers[first] != nil || docker.containers[replacement] != nil {
				t.Fatal("saved intent did not finish exact inert release", recoveryErr)
			}
			if _, err = c.load(testName); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("released receipt remains", err)
			}
		})
	}
}
