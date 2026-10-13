// Package sharedcapacity plans withdrawals from current fenced workload observations.
package sharedcapacity

import (
	"errors"
	"maps"
	"sort"
	"time"
)

const observationFreshness = 30 * time.Second

// Observation attests the exact grant's workload state. Busy means any assigned
// job or owned worker remains active. Missing or stale observations are unknown.
type Observation struct {
	Fence      string    `json:"fence"`
	Busy       bool      `json:"busy"`
	ObservedAt time.Time `json:"observedAt"`
}

// DrainPlan proposes reclaiming idle allocations. Owners must withdraw job
// admission and check busy state again before stopping an exact workload.
// Planning does not release a grant or authorize killing an assigned job.
type DrainPlan struct {
	WaitingID string  `json:"waitingId,omitempty"`
	Grants    []Grant `json:"grants"`
	Ready     bool    `json:"ready"`
	Reason    string  `json:"reason"`
}

// PlanDrain selects only fresh, idle, lower-priority grants above their pool's
// guarantee, or same-pool extras blocking a missing physical floor slot.
// Unknown state and busy workloads retain their allocations.
func PlanDrain(snapshot *Snapshot, observations map[string]Observation, now time.Time) (DrainPlan, error) {
	plan := DrainPlan{Grants: []Grant{}, Reason: "no_demand"}
	if now.IsZero() {
		return plan, errors.New("shared capacity drain requires an observation time")
	}
	if err := validateSnapshot(snapshot); err != nil {
		return plan, err
	}
	plan.WaitingID = eligibleQueueHead(snapshot, now, true, false)
	if plan.WaitingID == "" {
		return plan, nil
	}
	pending := snapshot.Pending[plan.WaitingID]
	if canAdmit(snapshot, pending.Request) {
		plan.Ready, plan.Reason = true, "budget_available"
		return plan, nil
	}
	working := *snapshot
	working.Grants = maps.Clone(snapshot.Grants)
	candidates := drainCandidates(snapshot, observations, &pending, now)
	plan.Reason = "waiting_for_busy_or_unknown_workloads"
	for _, grant := range candidates {
		if ProtectsMinimum(&working, grant.Request) {
			continue
		}
		delete(working.Grants, grant.ID)
		plan.Grants = append(plan.Grants, grant)
		if canAdmit(&working, pending.Request) {
			plan.Reason = "withdraw_and_recheck_idle_workloads"
			return plan, nil
		}
	}
	// Do not drain partially if the available idle set cannot satisfy demand.
	// Busy owners can finish while the existing idle workers remain useful.
	plan.Grants = []Grant{}
	return plan, nil
}

func drainCandidates(snapshot *Snapshot, observations map[string]Observation, pending *Pending, now time.Time) []Grant {
	candidates := []Grant{}
	priority := effectivePriority(snapshot, pending, now)
	pool := snapshot.Policy.Pools[pending.Pool]
	missingFloor := countsAsPhysicalFloor(snapshot, pending.Request, diagnosticCost(&snapshot.Policy, pending.Request)) && minimumCounts(snapshot)[pending.Pool] < pool.Minimum
	for id, grant := range snapshot.Grants {
		observation, exists := observations[id]
		if !exists || observation.Fence != grant.Fence || observation.Busy || observation.ObservedAt.IsZero() || observation.ObservedAt.After(now) || now.Sub(observation.ObservedAt) > observationFreshness {
			continue
		}
		restoresFloor := missingFloor && grant.Pool == pending.Pool &&
			(grant.BorrowedMemoryMiB > 0 || !countsAsPhysicalFloor(snapshot, grant.Request, grant.Cost))
		if !restoresFloor && uint64(snapshot.Policy.Pools[grant.Pool].Priority) >= priority {
			continue
		}
		candidates = append(candidates, grant)
	}
	sort.Slice(candidates, func(i, j int) bool {
		left, right := snapshot.Policy.Pools[candidates[i].Pool].Priority, snapshot.Policy.Pools[candidates[j].Pool].Priority
		if left != right {
			return left < right
		}
		if !candidates[i].GrantedAt.Equal(candidates[j].GrantedAt) {
			return candidates[i].GrantedAt.After(candidates[j].GrantedAt)
		}
		return candidates[i].ID < candidates[j].ID
	})
	return candidates
}

// PlanMemoryDrain proposes one idle extra build under measured memory pressure.
// A container's hard limit is not its resident memory, so never estimate relief
// by subtracting limits. Native settlement finishes before a fresh next plan.
func PlanMemoryDrain(snapshot *Snapshot, observations map[string]Observation, status BuildMemoryDiagnostic, now time.Time) (DrainPlan, error) {
	plan := DrainPlan{Grants: []Grant{}, Reason: memoryHeadroom}
	if err := validateSnapshot(snapshot); err != nil {
		return plan, err
	}
	if snapshot.Policy.BuildMemoryOvercommit == nil || status.State != memoryStatePressure || status.AvailableMiB == nil ||
		status.MinimumAvailableMiB != snapshot.Policy.BuildMemoryOvercommit.MinimumAvailableMiB ||
		*status.AvailableMiB >= status.MinimumAvailableMiB || now.IsZero() || status.ObservedAt.IsZero() ||
		status.ObservedAt.After(now) || now.Sub(status.ObservedAt) > 5*time.Second {
		return plan, nil
	}
	plan.Reason = "memory_pressure_busy_or_unknown"
	ids := make([]string, 0, len(snapshot.Grants))
	for id := range snapshot.Grants {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		grant := snapshot.Grants[id]
		observation, exists := observations[id]
		if grant.Pool != buildPool || ProtectsMinimum(snapshot, grant.Request) || !exists || observation.Fence != grant.Fence ||
			observation.Busy || observation.ObservedAt.IsZero() || observation.ObservedAt.After(now) || now.Sub(observation.ObservedAt) > observationFreshness {
			continue
		}
		plan.Grants = append(plan.Grants, grant)
		plan.Reason = "memory_pressure_withdraw_idle_extra"
		break
	}
	return plan, nil
}
