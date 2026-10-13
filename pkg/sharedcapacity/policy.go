// Package sharedcapacity serializes admission to a host's shared CPU and RAM budget.
// A grant is durable before a workload starts and remains charged until its owner
// proves that workload has stopped. Timeouts and process exits never free grants.
package sharedcapacity

import (
	"errors"
	"fmt"
	"maps"
	"reflect"
	"slices"
)

// CPUAdmissionSoft allows sharing host CPU time without changing workload limits.
const CPUAdmissionSoft = "soft"

const buildPool = "build"

// Resources are workload limits, not measurements of current utilization.
type Resources struct {
	MemoryMiB uint64 `json:"memoryMiB"`
	VCPUs     uint32 `json:"vcpus"`
}

// Pool specifies one workload class and its guaranteed and maximum capacity.
// Cost is the default allocation and floor reserve. MaxCost optionally bounds
// explicit requests without changing default allocations or floor reserves.
type Pool struct {
	Cost     Resources `json:"cost"`
	MaxCost  Resources `json:"maxCost,omitzero"`
	Minimum  uint32    `json:"minimum"`
	Maximum  uint32    `json:"maximum"`
	Priority uint32    `json:"priority"`
	// MinimumRequestIDs optionally binds the guarantee to stable workload IDs.
	// An omitted selector preserves the legacy aggregate guarantee.
	MinimumRequestIDs []string `json:"minimumRequestIDs,omitempty"`
}

// Policy is the admission contract materialized from durable host policy.
type Policy struct {
	Budget       Resources       `json:"budget"`
	Pools        map[string]Pool `json:"pools"`
	AgingSeconds uint32          `json:"agingSeconds"`
	// CPUAdmission defaults to hard aggregate admission. Soft admission keeps
	// each workload's CPU limit but allows CPU time to be shared across grants.
	CPUAdmission string `json:"cpuAdmission,omitempty"`
	// BuildMemoryOvercommit adds a bounded, best-effort commitment allowance
	// for builders only. Costs and container hard limits remain unchanged.
	BuildMemoryOvercommit *BuildMemoryOvercommit `json:"buildMemoryOvercommit,omitempty"`
}

// IsBuildFloorIncrease recognizes only an additive, identity-bound build floor.
// All existing guarantees and every other admission setting must stay exact.
func IsBuildFloorIncrease(previous, revised *Policy) bool {
	if previous == nil || revised == nil || previous.Validate() != nil || revised.Validate() != nil {
		return false
	}
	oldBuild, oldExists := previous.Pools[buildPool]
	newBuild, newExists := revised.Pools[buildPool]
	if !oldExists || !newExists || oldBuild.Minimum == 0 || newBuild.Minimum <= oldBuild.Minimum ||
		len(oldBuild.MinimumRequestIDs) != int(oldBuild.Minimum) ||
		len(newBuild.MinimumRequestIDs) != int(newBuild.Minimum) ||
		!slices.Equal(oldBuild.MinimumRequestIDs, newBuild.MinimumRequestIDs[:oldBuild.Minimum]) {
		return false
	}
	normalized := *revised
	normalized.Pools = maps.Clone(revised.Pools)
	newBuild.Minimum = oldBuild.Minimum
	newBuild.MinimumRequestIDs = oldBuild.MinimumRequestIDs
	normalized.Pools[buildPool] = newBuild
	return reflect.DeepEqual(*previous, normalized)
}

// SoftCPU reports whether only memory constrains aggregate host admission.
func (p *Policy) SoftCPU() bool { return p.CPUAdmission == CPUAdmissionSoft }

// Validate rejects impossible guarantees and unbounded policies.
func (p *Policy) Validate() error {
	if p == nil || p.Budget.MemoryMiB == 0 || p.Budget.VCPUs == 0 || p.AgingSeconds == 0 || len(p.Pools) == 0 {
		return errors.New("shared capacity requires a positive budget, aging interval and pools")
	}
	if err := errors.Join(validateCPUAdmission(p.CPUAdmission), p.validateBuildMemory()); err != nil {
		return err
	}
	remaining := p.Budget
	selected := map[string]bool{}
	for name, pool := range p.Pools {
		if name == "" || pool.Cost.MemoryMiB == 0 || pool.Cost.VCPUs == 0 || pool.Maximum == 0 || pool.Maximum > 64 || pool.Minimum > pool.Maximum || pool.Priority > 16 {
			return fmt.Errorf("shared capacity pool %q is invalid", name)
		}
		if len(pool.MinimumRequestIDs) != 0 && len(pool.MinimumRequestIDs) != int(pool.Minimum) {
			return fmt.Errorf("shared capacity pool %q minimum selector must name every guaranteed request", name)
		}
		for _, id := range pool.MinimumRequestIDs {
			if id == "" || len(id) > 200 || selected[id] {
				return errors.New("shared capacity minimum request IDs must be valid and unique")
			}
			selected[id] = true
		}
		if !fits(pool.requestCeiling(), pool.Cost) || !fits(p.Budget, pool.requestCeiling()) {
			return fmt.Errorf("shared capacity pool %q cannot admit one workload", name)
		}
		for range pool.Minimum {
			if !p.fitsHost(remaining, pool.Cost) {
				return errors.New("shared capacity pool guarantees exceed the host budget")
			}
			remaining = subtract(remaining, pool.Cost)
		}
	}
	return nil
}

func validateCPUAdmission(mode string) error {
	switch mode {
	case "", "hard", CPUAdmissionSoft:
		return nil
	default:
		return errors.New("shared capacity CPU admission must be hard or soft")
	}
}

func fits(available, cost Resources) bool {
	return cost.MemoryMiB <= available.MemoryMiB && cost.VCPUs <= available.VCPUs
}

func (p *Policy) fitsHost(available, cost Resources) bool {
	return cost.MemoryMiB <= available.MemoryMiB && (p.SoftCPU() || cost.VCPUs <= available.VCPUs)
}

func subtract(available, cost Resources) Resources {
	// Diagnostics clamp the physical budget when build commitments exceed it.
	return Resources{MemoryMiB: available.MemoryMiB - min(available.MemoryMiB, cost.MemoryMiB), VCPUs: available.VCPUs - min(available.VCPUs, cost.VCPUs)}
}

// RequestCost resolves a legacy fixed request or a bounded explicit allocation.
// Partial or oversized requests are rejected before they can enter the queue.
func RequestCost(policy *Policy, request Request) (Resources, error) {
	for name, other := range policy.Pools {
		if name != request.Pool && slices.Contains(other.MinimumRequestIDs, request.ID) {
			return Resources{}, errors.New("guaranteed shared capacity request belongs to another pool")
		}
	}
	pool, exists := policy.Pools[request.Pool]
	if !exists {
		return Resources{}, errors.New("shared capacity request pool is unknown")
	}
	if request.Resources == (Resources{}) {
		return pool.Cost, nil
	}
	if len(pool.MinimumRequestIDs) != 0 && pool.CountsTowardMinimum(request.ID) && request.Resources != pool.Cost {
		return Resources{}, errors.New("guaranteed shared capacity request differs from its reserved resources")
	}
	if request.Resources.MemoryMiB == 0 || request.Resources.VCPUs == 0 || !fits(pool.requestCeiling(), request.Resources) {
		return Resources{}, errors.New("shared capacity requested resources exceed the pool envelope or are incomplete")
	}
	return request.Resources, nil
}

// CountsTowardMinimum separates guaranteed identities from aggregate limits.
func (p Pool) CountsTowardMinimum(id string) bool {
	return len(p.MinimumRequestIDs) == 0 || slices.Contains(p.MinimumRequestIDs, id)
}

func minimumCounts(snapshot *Snapshot) map[string]uint32 {
	counts := map[string]uint32{}
	for _, grant := range snapshot.Grants {
		if grant.BorrowedMemoryMiB == 0 && countsAsPhysicalFloor(snapshot, grant.Request, grant.Cost) {
			counts[grant.Pool]++
		}
	}
	return counts
}

func countsAsPhysicalFloor(snapshot *Snapshot, request Request, cost Resources) bool {
	pool := snapshot.Policy.Pools[request.Pool]
	return pool.CountsTowardMinimum(request.ID) &&
		(snapshot.Schema != buildMemoryLedgerSchema || cost.MemoryMiB >= pool.Cost.MemoryMiB)
}

// ProtectsMinimum is shared by planning and the native withdrawal boundary.
// Maintenance and positively exited owner recovery remain the owner's concern.
func ProtectsMinimum(snapshot *Snapshot, request Request) bool {
	if grant, found := snapshot.Grants[request.ID]; found && grant.BorrowedMemoryMiB > 0 {
		return false
	}
	pool := snapshot.Policy.Pools[request.Pool]
	cost, err := RequestCost(&snapshot.Policy, request)
	return err == nil && countsAsPhysicalFloor(snapshot, request, cost) && minimumCounts(snapshot)[request.Pool] <= pool.Minimum
}

func (p Pool) requestCeiling() Resources {
	if p.MaxCost != (Resources{}) {
		return p.MaxCost
	}
	return p.Cost
}
