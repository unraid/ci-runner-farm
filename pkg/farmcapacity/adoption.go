// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"os"
	"slices"
	"strings"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type inventoryDocker interface {
	Owned(context.Context) ([]Container, error)
}

// Inventory observes every native managed container, including inert and
// stopped identities. Busy workers may continue; all native starts are closed
// and the caller holds fleet.lock through adoption and receipt persistence.
func (c *Controller) Inventory(ctx context.Context) ([]Container, error) {
	docker, ok := c.Docker.(inventoryDocker)
	if !ok {
		return nil, errors.New("native complete inventory is unavailable")
	}
	containers, err := docker.Owned(ctx)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for index := range containers {
		item := &containers[index]
		if err := c.validate(item, item.Name); err != nil {
			return nil, err
		}
		if item.Paused {
			return nil, errors.New("paused native owner requires lifecycle recovery before adoption")
		}
		if seen[item.Name] {
			return nil, errors.New("duplicate native owner slot")
		}
		seen[item.Name] = true
		owned, readErr := c.load(item.Name)
		if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
			return nil, readErr
		}
		if owned != nil && (owned.ID != item.ID || owned.ReplacementPrepared || (owned.Withdrawal != nil && owned.Withdrawal.Phase != "")) {
			return nil, errors.New("native owner has unresolved lifecycle state")
		}
	}
	if err := c.validateReceiptCoverage(seen); err != nil {
		return nil, err
	}
	slices.SortFunc(containers, func(a, b Container) int {
		if a.Name < b.Name {
			return -1
		}
		if a.Name > b.Name {
			return 1
		}
		return 0
	})
	return containers, nil
}

// AdoptionRequests conservatively charges every inventoried native identity.
func (c *Controller) AdoptionRequests(containers []Container) ([]sharedcapacity.Request, error) {
	var snapshot *sharedcapacity.Snapshot
	if _, err := os.Lstat(c.Broker.Path); err == nil {
		current, statusErr := c.Broker.Status(&c.Policy)
		if statusErr != nil && !errors.Is(statusErr, sharedcapacity.ErrUninitialized) {
			return nil, statusErr
		}
		if statusErr == nil {
			snapshot = &current
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	requests := make([]sharedcapacity.Request, 0, len(containers))
	for i := range containers {
		if err := c.validate(&containers[i], containers[i].Name); err != nil {
			return nil, err
		}
		request, err := c.containerRequest(&containers[i], snapshot)
		if err != nil {
			return nil, err
		}
		requests = append(requests, request)
	}
	return requests, nil
}

// SaveAdoption writes each exact adopted fence before native starts reopen.
// A partial write remains recoverable with starts closed; allocations stay charged.
func (c *Controller) SaveAdoption(containers []Container, snapshot *sharedcapacity.Snapshot) error {
	for index := range containers {
		item := &containers[index]
		grant, exists := snapshot.Grants["build:"+item.Name]
		if !exists && c.provedQueuedAdoption(item, snapshot) {
			continue
		}

		resources, resourceErr := containerResources(item)
		if !exists || grant.Pool != buildPool || grant.Fence == "" || resourceErr != nil || grant.Cost != resources {
			return errors.New("native adoption grant is missing")
		}
		owned, err := c.load(item.Name)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if owned != nil && (owned.ID != item.ID || (owned.Fence != "" && owned.Fence != grant.Fence)) {
			return sharedcapacity.ErrFenceMismatch
		}
		if owned == nil {
			owned = &receipt{ID: item.ID}
		}
		owned.Fence = grant.Fence
		if err := c.save(item.Name, owned); err != nil {
			return err
		}
	}
	return nil
}

func (c *Controller) validateReceiptCoverage(seen map[string]bool) error {
	entries, err := os.ReadDir(c.ReceiptRoot)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		name := strings.TrimSuffix(entry.Name(), ".json")
		if !namePattern.MatchString(name) || !seen[name] {
			return errors.New("native receipt has no attested container; recover lifecycle before adoption")
		}
		if _, err := c.load(name); err != nil {
			return err
		}
	}
	return nil
}

// A never-started queued owner has no grant fence yet. Its exact protected
// receipt and pending request must survive adoption without starting it.
func (c *Controller) provedQueuedAdoption(item *Container, snapshot *sharedcapacity.Snapshot) bool {
	if !item.NeverStarted || item.Running || item.Paused || !item.RoutingGated {
		return false
	}
	pending, queued := snapshot.Pending["build:"+item.Name]
	request, requestErr := c.containerRequest(item, snapshot)
	owned, receiptErr := c.load(item.Name)
	return queued && requestErr == nil && pending.Request == request && receiptErr == nil && owned != nil && owned.ID == item.ID && owned.Fence == "" && !owned.ReleasePending && owned.Withdrawal == nil
}
