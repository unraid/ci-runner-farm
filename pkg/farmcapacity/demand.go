// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// DemandPool retains stable slot identities; desired capacity is a count, not
// the highest occupied index. Queue demand is advisory, admission remains owned
// by the shared broker and removal by the fenced withdrawal journal.
type DemandPool struct {
	ID                     string
	Labels                 []string
	Minimum, Maximum, Idle int
	MemoryMiB              uint64
	CPUs                   uint32
}

// ParseDemandPools accepts only reviewed v3 build classes within the protected
// aggregate policy. Overlapping ceilings do not reserve physical capacity.
func ParseDemandPools(text string, policy *sharedcapacity.Policy) ([]DemandPool, error) {
	pools := []DemandPool{}
	seen := map[string]bool{}
	for rec := range strings.SplitSeq(text, ";") {
		f := strings.Split(rec, "|")
		if len(f) != 11 || f[0] != "v3" || (f[1] != buildPool && f[1] != "build-small" && f[1] != "build-large") || seen[f[1]] {
			return nil, errors.New("invalid demand pool")
		}
		seen[f[1]] = true
		p, err := parseDemandPool(f, policy)
		if err != nil {
			return nil, err
		}
		pools = append(pools, p)
	}
	if !seen[buildPool] {
		return nil, errors.New("standard demand pool required")
	}
	slices.SortFunc(pools, func(a, b DemandPool) int {
		if a.MemoryMiB != b.MemoryMiB {
			if a.MemoryMiB < b.MemoryMiB {
				return -1
			}
			return 1
		}
		if a.CPUs < b.CPUs {
			return -1
		}
		if a.CPUs > b.CPUs {
			return 1
		}
		return strings.Compare(a.ID, b.ID)
	})
	return pools, nil
}

func parseDemandPool(f []string, policy *sharedcapacity.Policy) (DemandPool, error) {
	p := DemandPool{ID: f[1], Labels: append([]string{f[2], "self-hosted", "linux", "x64"}, strings.Split(f[3], ",")...)}
	for i, dest := range map[int]*int{5: &p.Minimum, 6: &p.Maximum, 7: &p.Idle} {
		n, e := strconv.Atoi(f[i])
		if e != nil || n < 0 {
			return DemandPool{}, errors.New("invalid demand limits")
		}
		*dest = n
	}
	cpu, e := strconv.ParseUint(f[8], 10, 32)
	if e != nil {
		return DemandPool{}, e
	}
	p.CPUs = uint32(cpu)
	memory := strings.ToLower(f[9])
	if len(memory) < 2 {
		return DemandPool{}, errors.New("invalid demand memory")
	}
	n, e := strconv.ParseUint(memory[:len(memory)-1], 10, 64)
	if e != nil || n > 1048576 {
		return DemandPool{}, errors.New("invalid demand memory")
	}
	switch memory[len(memory)-1] {
	case 'g':
		p.MemoryMiB = n * 1024
	case 'm':
		p.MemoryMiB = n
	default:
		return DemandPool{}, errors.New("demand memory must use m or g")
	}
	if p.Maximum < 1 || p.Maximum > 64 || p.Minimum > p.Maximum || p.Idle > p.Maximum || p.Maximum > int(policy.Pools[buildPool].Maximum) {
		return DemandPool{}, errors.New("demand ceiling exceeds protected policy")
	}
	if _, e := sharedcapacity.RequestCost(policy, sharedcapacity.Request{Pool: buildPool, Resources: sharedcapacity.Resources{MemoryMiB: p.MemoryMiB, VCPUs: p.CPUs}}); e != nil {
		return DemandPool{}, e
	}
	if p.ID == buildPool && p.Minimum != int(policy.Pools[buildPool].Minimum) {
		return DemandPool{}, errors.New("demand standard floor differs from policy")
	}
	if p.ID != buildPool && p.Minimum != 0 {
		return DemandPool{}, errors.New("specialized demand floor must be zero")
	}
	return p, nil
}

// DemandStarts returns only absent or inert selected slots. Running/unknown
// owners are never restarted. Incomplete queue evidence must not call this.
func (c *Controller) DemandStarts(ctx context.Context, pools []DemandPool, queued map[string]int, bind BindOwner) (map[string][]int, error) {
	starts := map[string][]int{}
	for _, pool := range pools {
		q, ok := queued[pool.ID]
		if !ok || q < 0 {
			return nil, errors.New("incomplete build queue snapshot")
		}
	}
	for _, pool := range pools {
		selected, err := c.demandPoolStarts(ctx, &pool, queued[pool.ID], bind)
		if err != nil {
			return nil, err
		}
		starts[pool.ID] = selected
	}
	return starts, nil
}

type demandSlot struct {
	index       int
	item        *Container
	binding     OwnerBinding
	idle, inert bool
}

func (c *Controller) demandPoolStarts(ctx context.Context, pool *DemandPool, queued int, bind BindOwner) ([]int, error) {
	slots, occupied, retained, err := c.observeDemandSlots(ctx, pool, bind)
	if err != nil {
		return nil, err
	}
	// Job records omit requested groups. Keep at most one advisory spare per
	// class; subsequent busy pickups expand the class on the next tick. This
	// prevents unrelated-group queued jobs reserving a whole class ceiling.
	target := min(pool.Maximum, max(pool.Minimum, retained+min(queued, 1)+pool.Idle))
	return c.applyDemandTarget(ctx, pool, target, slots, occupied, retained)
}

func (c *Controller) applyDemandTarget(ctx context.Context, pool *DemandPool, target int, slots []demandSlot, occupied map[int]bool, retained int) ([]int, error) {
	floor, required, result := c.demandFloorSlots(pool, slots, occupied)
	target = max(target, retained+required)
	keep := max(0, target-retained-required)
	for _, slot := range slots {
		if !slot.idle && !slot.inert {
			continue
		}
		if floor[slot.index] || keep > 0 {
			if !floor[slot.index] {
				keep--
			}
			if slot.inert {
				result = append(result, slot.index)
			}
			continue
		}
		name := slot.item.Name
		if slot.inert {
			if err := c.CancelQueued(ctx, name, slot.item.ID); err != nil {
				return nil, err
			}
		} else {
			// Settlement may span ticks. Existing withdrawal recovery finishes it;
			// the allocation remains charged and is never a start candidate here.
			if err := c.Withdraw(ctx, name, slot.item.ID, slot.binding.Owner, slot.binding.RunnerID, slot.binding.RunnerName, c.now()); err != nil {
				continue
			}
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

func (c *Controller) demandFloorSlots(pool *DemandPool, slots []demandSlot, occupied map[int]bool) (floor map[int]bool, required int, result []int) {
	floor = map[int]bool{}
	result = []int{}
	for _, id := range c.Policy.Pools[buildPool].MinimumRequestIDs {
		for index := 1; index <= pool.Maximum; index++ {
			if id != "build:"+demandSlotName(pool.ID, index) {
				continue
			}
			floor[index] = true
			if !occupied[index] {
				result = append(result, index)
				occupied[index] = true
				required++
			}
		}
	}
	for _, slot := range slots {
		if floor[slot.index] && (slot.idle || slot.inert) {
			required++
		}
	}
	return floor, required, result
}

func (c *Controller) observeDemandSlots(ctx context.Context, pool *DemandPool, bind BindOwner) (slots []demandSlot, occupied map[int]bool, retained int, returnErr error) {
	slots = []demandSlot{}
	occupied = map[int]bool{}
	for index := 1; index <= pool.Maximum; index++ {
		name := demandSlotName(pool.ID, index)
		item, err := c.Docker.Inspect(ctx, name)
		if errors.Is(err, ErrContainerMissing) {
			continue
		}
		if err != nil {
			return nil, nil, 0, err
		}
		if validationErr := c.validate(item, name); validationErr != nil {
			return nil, nil, 0, validationErr
		}
		occupied[index] = true
		slot := demandSlot{index: index, item: item}
		owned, err := c.demandReceipt(ctx, name, item)
		if err != nil {
			return nil, nil, 0, err
		}
		if owned.ID != item.ID {
			return nil, nil, 0, errors.New("demand owner identity changed")
		}
		if owned.Fence == "" && item.NeverStarted && !item.Running && !owned.ReleasePending {
			slot.inert = true
		} else if !item.Paused && item.Running && (owned.Withdrawal == nil || owned.Withdrawal.Phase == "") && !owned.ReleasePending {
			binding, e := c.bindWithdrawalOwner(ctx, name, owned, bind)
			if e == nil {
				idle, idleErr := binding.Owner.Idle(ctx)
				if idleErr == nil && idle {
					slot.idle = true
					slot.binding = binding
				}
			}
		}
		if !slot.idle && !slot.inert {
			retained++
		}
		slots = append(slots, slot)
	}
	return slots, occupied, retained, nil
}

func (c *Controller) demandReceipt(_ context.Context, name string, item *Container) (*receipt, error) {
	owned, err := c.load(name)
	if errors.Is(err, os.ErrNotExist) && item.NeverStarted && !item.Running && item.RoutingGated {
		snapshot, statusErr := c.Broker.Status(&c.Policy)
		if statusErr != nil {
			return nil, statusErr
		}
		if _, charged := snapshot.Grants["build:"+name]; !charged {
			// Recover only the inert create-before-receipt boundary. No
			// native start, registration or grant is inferred here.
			owned = &receipt{ID: item.ID}
			err = c.save(name, owned)
		}
	}
	if err != nil {
		return nil, err
	}
	return owned, nil
}

func demandSlotName(pool string, index int) string {
	return fmt.Sprintf("ci-runner-%s-%d", pool, index)
}

// CancelQueued records removal intent before deleting a never-started owner.
// Release cancels only the exact uncharged request after ID/name absence proof.
func (c *Controller) CancelQueued(ctx context.Context, name, id string) error {
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned.ID != id || owned.Fence != "" {
		return errors.New("queued cancellation identity differs")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	if _, charged := snapshot.Grants["build:"+name]; charged || (owned.Withdrawal != nil && owned.Withdrawal.Phase != "") {
		return errors.New("charged owner cannot cancel queued demand")
	}
	if owned.ReleasePending && owned.ReplacementPrepared {
		if absenceErr := c.oldReplacementAbsent(ctx, name, id); absenceErr == nil {
			return c.Release(ctx, name, id)
		}
	}
	owned.ReleasePending = true
	if err := c.save(name, owned); err != nil {
		return err
	}
	if err := c.PrepareQueuedReplacement(ctx, name, id); err != nil {
		return err
	}
	return c.Release(ctx, name, id)
}
