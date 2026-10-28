// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"slices"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// WarmTargets contains Farm's static profile targets, never queue evidence.
type WarmTargets struct {
	Schema  int            `json:"schema"`
	Targets map[string]int `json:"targets"`
}

// WarmStarts plans only additive restoration. It never observes remote idleness,
// withdraws an owner, cancels pending intent or grants resources itself.
func (c *Controller) WarmStarts(ctx context.Context, pools []DemandPool, request *WarmTargets) (map[string][]int, error) {
	if request == nil || request.Schema != 1 || len(request.Targets) != len(pools) {
		return nil, errors.New("incomplete warm target identity")
	}
	for _, pool := range pools {
		target, exists := request.Targets[pool.ID]
		if !exists || target != max(pool.Minimum, pool.Idle) || target > pool.Maximum {
			return nil, errors.New("warm target differs from protected profile")
		}
	}
	// Reuse the broker's scheduler order so an old inert owner outside the
	// lowest indices cannot block the selected warm replacements indefinitely.
	diagnostic, err := c.Broker.Diagnose(&c.Policy)
	if err != nil {
		return nil, err
	}
	if !diagnostic.PolicyMatches {
		return nil, errors.New("warm recovery policy changed")
	}
	rank := map[string]int{}
	for index := range diagnostic.Pending {
		rank[diagnostic.Pending[index].ID] = index + 1
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return nil, err
	}
	starts := map[string][]int{}
	for _, pool := range pools {
		selected, planErr := c.warmPoolStarts(ctx, &pool, request.Targets[pool.ID], rank, diagnostic.QueueHead, &snapshot)
		if planErr != nil {
			return nil, planErr
		}
		starts[pool.ID] = selected
	}
	return starts, nil
}

func (c *Controller) warmPoolStarts(ctx context.Context, pool *DemandPool, target int, rank map[string]int, head string, snapshot *sharedcapacity.Snapshot) ([]int, error) {
	occupied := map[int]bool{}
	inert := []demandSlot{}
	granted := []int{}
	running := 0
	for index := 1; index <= pool.Maximum; index++ {
		name := demandSlotName(pool.ID, index)
		item, err := c.Docker.Inspect(ctx, name)
		if errors.Is(err, ErrContainerMissing) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if validationErr := c.validate(item, name); validationErr != nil {
			return nil, validationErr
		}
		owned, err := c.demandReceipt(ctx, name, item)
		if err != nil {
			return nil, err
		}
		if owned.ID != item.ID {
			return nil, errors.New("warm owner identity changed")
		}
		occupied[index] = true
		switch {
		case item.Running && !item.Paused && !owned.ReleasePending && (owned.Withdrawal == nil || owned.Withdrawal.Phase == ""):
			running++
		case owned.Fence == "" && item.NeverStarted && !item.Running && !owned.ReleasePending:
			inert = append(inert, demandSlot{index: index, item: item, inert: true})
		case grantedNeverStarted(name, item, owned, snapshot):
			granted = append(granted, index)
		}
	}
	floor, _, result := c.demandFloorSlots(pool, inert, occupied)
	// A charged owner whose start failed or waited for memory headroom holds
	// its grant until native start runs again. Retry it; it already counts
	// toward the warm total, so it never adds an allocation.
	result = append(result, granted...)
	for _, slot := range inert {
		if floor[slot.index] {
			result = append(result, slot.index)
		}
	}
	keep := max(0, target-running-len(result))
	slices.SortStableFunc(inert, func(a, b demandSlot) int {
		return warmPendingRank(a, rank) - warmPendingRank(b, rank)
	})
	for _, slot := range inert {
		if floor[slot.index] {
			continue
		}
		// The broker grants only its queue head. Retry an inert head even when
		// running owners satisfy the warm target, or every later request
		// waits behind it after its capacity frees.
		if keep > 0 || "build:"+slot.item.Name == head {
			result = append(result, slot.index)
			keep = max(0, keep-1)
		}
	}
	for index := 1; index <= pool.Maximum && keep > 0; index++ {
		if !occupied[index] {
			result = append(result, index)
			keep--
		}
	}
	return result, nil
}

// grantedNeverStarted is a charged owner that native start has not yet run.
// Withdrawing, releasing or remotely unproved owners keep their own recovery.
func grantedNeverStarted(name string, item *Container, owned *receipt, snapshot *sharedcapacity.Snapshot) bool {
	grant, charged := snapshot.Grants["build:"+name]
	return charged && owned.Fence != "" && owned.Fence == grant.Fence && item.NeverStarted && !item.Running && !item.Paused &&
		!owned.ReleasePending && !owned.Retiring && (owned.Withdrawal == nil || owned.Withdrawal.Phase == "")
}

func warmPendingRank(slot demandSlot, rank map[string]int) int {
	if order := rank["build:"+slot.item.Name]; order > 0 {
		return order
	}
	return len(rank) + slot.index + 1
}
