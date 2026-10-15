// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func (d *fakeDocker) Owned(context.Context) ([]Container, error) {
	if d.inspectErr != nil {
		return nil, d.inspectErr
	}
	result := []Container{}
	for _, item := range d.containers {
		result = append(result, *item)
	}
	return result, nil
}

func (d *fakeDocker) ManagedNames(context.Context) ([]string, error) {
	if d.inspectErr != nil {
		return nil, d.inspectErr
	}
	names := []string{}
	for _, item := range d.containers {
		names = append(names, item.Name)
	}
	return names, nil
}

func TestAdoptionChargesExistingBusyBuilderBeforeOpeningStarts(t *testing.T) {
	c, d, id := fixture(t)
	d.containers[id].Running = true
	inventory, err := c.Inventory(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	requests, requestErr := c.AdoptionRequests(inventory)
	if requestErr != nil {
		t.Fatal(requestErr)
	}
	if checkErr := c.Broker.Adopt(&c.Policy, requests, func() error { return nil }); checkErr != nil {
		t.Fatal(checkErr)
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if checkErr := c.SaveAdoption(inventory, &snapshot); checkErr != nil {
		t.Fatal(checkErr)
	}
	if checkErr := c.Start(context.Background(), testName, id); checkErr != nil {
		t.Fatal(checkErr)
	}
	if d.starts != 0 || !d.containers[id].Running {
		t.Fatal("adoption interrupted or restarted the existing worker")
	}
	before := snapshot.Grants[requests[0].ID]
	if checkErr := c.Broker.Adopt(&c.Policy, requests, func() error { return nil }); checkErr != nil {
		t.Fatal(checkErr)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || before.Fence != after.Grants[requests[0].ID].Fence {
		t.Fatal("adoption replay replaced the running fence")
	}
}

func TestAdoptionRejectsUnknownLimitsAndPausedOwner(t *testing.T) {
	for _, mode := range []string{"limits", "provider", "paused"} {
		c, d, id := fixture(t)
		switch mode {
		case "limits":
			d.containers[id].MemoryBytes = 0
		case "provider":
			d.containers[id].Provider = "unexpected-provider"
		case "paused":
			d.containers[id].Paused = true
		}
		if _, err := c.Inventory(context.Background()); err == nil {
			t.Fatal(mode + " owner was adopted")
		}
		snapshot, err := c.Broker.Status(&c.Policy)
		if err != nil || len(snapshot.Grants) != 0 {
			t.Fatal("failed owner proof changed allocation")
		}
	}
}

func TestInitialAdoptionRecoversLedgerAfterFailedAttestation(t *testing.T) {
	c, d, id := fixture(t)
	c.Broker.Path = filepath.Join(t.TempDir(), "admission.bolt")
	d.containers[id].Running = true
	inventory, err := c.Inventory(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	requests, err := c.AdoptionRequests(inventory)
	if err != nil {
		t.Fatal(err)
	}
	failed := errors.New("inventory changed before commit")
	if checkErr := c.Broker.Adopt(&c.Policy, requests, func() error { return failed }); !errors.Is(checkErr, failed) {
		t.Fatal(checkErr)
	}
	if _, checkErr := c.Broker.Status(&c.Policy); !errors.Is(checkErr, sharedcapacity.ErrUninitialized) {
		t.Fatal("failed adoption committed workload", checkErr)
	}
	requests, err = c.AdoptionRequests(inventory)
	if err != nil {
		t.Fatal("safe initial adoption retry blocked", err)
	}
	if checkErr := c.Broker.Adopt(&c.Policy, requests, func() error { return nil }); checkErr != nil {
		t.Fatal(checkErr)
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 1 || snapshot.Grants[requests[0].ID].Fence == "" {
		t.Fatal("complete adoption did not preserve owner", err)
	}
	if d.starts != 0 {
		t.Fatal("adoption restarted busy worker")
	}
}

func TestAdoptionRetainsInertQueuedOwnerAndRejectsUnchargedRunningOwner(t *testing.T) {
	c, d, id := fixture(t)
	ctx := context.Background()
	if err := c.Start(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	second := *d.containers[id]
	second.ID = strings.Repeat("b", 64)
	second.Name = "ci-runner-build-2"
	second.Running = false
	second.NeverStarted = true
	second.RoutingGated = true
	second.RegistrationIssuedAt = time.Now().Unix()
	d.containers[second.ID] = &second
	if err := c.Start(ctx, second.Name, second.ID); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	native := []Container{*d.containers[id], second}
	requests, err := c.AdoptionRequests(native)
	if err != nil {
		t.Fatal(err)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if adoptErr := c.Broker.Adopt(&c.Policy, requests, func() error { return nil }); adoptErr != nil {
		t.Fatal(adoptErr)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.SaveAdoption(native, &after); err != nil {
		t.Fatal(err)
	}
	if after.Pending[requests[1].ID] != before.Pending[requests[1].ID] || d.starts != 1 {
		t.Fatal("queued owner started or lost queue age")
	}
	native[1].Running = true
	if err := c.SaveAdoption(native, &after); err == nil {
		t.Fatal("running owner accepted without a grant")
	}
}
