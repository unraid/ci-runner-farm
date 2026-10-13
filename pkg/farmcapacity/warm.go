// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"slices"
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
	starts := map[string][]int{}
	for _, pool := range pools {
		selected, planErr := c.warmPoolStarts(ctx, &pool, request.Targets[pool.ID], rank)
		if planErr != nil {
			return nil, planErr
		}
		starts[pool.ID] = selected
	}
	return starts, nil
}

func (c *Controller) warmPoolStarts(ctx context.Context, pool *DemandPool, target int, rank map[string]int) ([]int, error) {
	occupied := map[int]bool{}
	inert := []demandSlot{}
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
		if item.Running && !item.Paused && !owned.ReleasePending && (owned.Withdrawal == nil || owned.Withdrawal.Phase == "") {
			running++
		} else if owned.Fence == "" && item.NeverStarted && !item.Running && !owned.ReleasePending {
			inert = append(inert, demandSlot{index: index, item: item, inert: true})
		}
	}
	floor, _, result := c.demandFloorSlots(pool, inert, occupied)
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
		if !floor[slot.index] && keep > 0 {
			result = append(result, slot.index)
			keep--
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

func warmPendingRank(slot demandSlot, rank map[string]int) int {
	if order := rank["build:"+slot.item.Name]; order > 0 {
		return order
	}
	return len(rank) + slot.index + 1
}
