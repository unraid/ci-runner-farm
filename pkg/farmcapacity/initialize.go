// Package farmcapacity binds native Farm owners to durable allocation fences.
package farmcapacity

import (
	"context"
	"errors"
	"reflect"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// InitializeStandalone charges a complete native inventory without restarting
// workers. The caller closes starts and holds fleet.lock and an exclusive Farm
// policy lease until this operation and active-policy publication finish.
// Shared consumers must use ownership transfer, never this initialization path.
func (c *Controller) InitializeStandalone(ctx context.Context) error {
	if len(c.Policy.Pools) != 1 || c.Policy.Pools[buildPool].Maximum == 0 {
		return errors.New("standalone initialization cannot own consumer classes")
	}
	inventory, err := c.Inventory(ctx)
	if err != nil {
		return err
	}
	requests, err := c.AdoptionRequests(inventory)
	if err != nil {
		return err
	}
	if err := c.Broker.AdoptWithSnapshot(&c.Policy, requests, func(*sharedcapacity.Snapshot) error {
		current, err := c.Inventory(ctx)
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(inventory, current) {
			return errors.New("native inventory changed before standalone initialization")
		}
		return ctx.Err()
	}); err != nil {
		return err
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	return c.SaveAdoption(inventory, &snapshot)
}
