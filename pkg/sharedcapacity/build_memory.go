// Package sharedcapacity bounds builder memory borrowing while protecting physical reserves.
package sharedcapacity

import (
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	memoryObservationRequired = "requires_fresh_memory_observation"
	memoryPressure            = "memory_pressure"
	memoryHeadroom            = "memory_headroom"
	memoryStatePressure       = "pressure"
)

// BuildMemoryOvercommit is explicit permission to share physical memory, not
// a larger physical budget or permission to relax a workload's hard limit.
type BuildMemoryOvercommit struct {
	AdditionalMiB       uint64 `json:"additionalMiB"`
	MinimumAvailableMiB uint64 `json:"minimumAvailableMiB"`
}

// MemoryObservation supplies measured headroom for burst admission and contraction.
type MemoryObservation struct {
	AvailableMiB uint64
	ObservedAt   time.Time
}

func (p *Policy) commitmentBudget() Resources {
	budget := p.Budget
	if p.BuildMemoryOvercommit != nil {
		budget.MemoryMiB += p.BuildMemoryOvercommit.AdditionalMiB
	}
	return budget
}

func allocatedMemory(snapshot *Snapshot) uint64 {
	var memory uint64
	for _, grant := range snapshot.Grants {
		memory += grant.Cost.MemoryMiB
	}
	return memory
}

func borrowedMemory(snapshot *Snapshot) uint64 {
	var memory uint64
	for _, grant := range snapshot.Grants {
		memory += grant.BorrowedMemoryMiB
	}
	return memory
}

func physicalMemory(snapshot *Snapshot) uint64 {
	return allocatedMemory(snapshot) - borrowedMemory(snapshot)
}

func missingFloorMemory(snapshot *Snapshot) uint64 {
	counts := minimumCounts(snapshot)
	var memory uint64
	for name, pool := range snapshot.Policy.Pools {
		memory += uint64(pool.Minimum-min(pool.Minimum, counts[name])) * pool.Cost.MemoryMiB
	}
	return memory
}

func validateBuildLoans(snapshot *Snapshot) error {
	if snapshot.Schema != buildMemoryLedgerSchema {
		return nil
	}
	reserve := missingFloorMemory(snapshot)
	physical := physicalMemory(snapshot)
	if reserve > snapshot.Policy.Budget.MemoryMiB || physical > snapshot.Policy.Budget.MemoryMiB-reserve {
		return errors.New("physical charges exceed the budget or guaranteed floor reserves")
	}
	borrowed := borrowedMemory(snapshot)
	if borrowed > 0 && (snapshot.Policy.BuildMemoryOvercommit == nil || borrowed > snapshot.Policy.BuildMemoryOvercommit.AdditionalMiB) {
		return errors.New("borrowed build memory exceeds its allowance")
	}
	return nil
}

// admissionFunding keeps queue fairness, ledger funding, and the fresh resident
// memory guard in the same native admission transaction.
func (b *Broker) admissionFunding(snapshot *Snapshot, request Request) (borrowed uint64, reason string) {
	head := queueHead(snapshot, b.now())
	backfill := head != request.ID && canBackfill(snapshot, request, head)
	if head != request.ID && !backfill {
		return 0, reasonPriority
	}
	borrowed, fits := admissionLoan(snapshot, request, backfill)
	if !fits {
		return 0, diagnosticBudget
	}
	if !b.memoryReady(snapshot, request) {
		return 0, memoryPressure
	}
	return borrowed, ""
}

// migrateBuildLoans preserves every workload identity and full charge. Only
// the accounting portion backed by the existing build allowance is assigned.
// v5 makes older writers reject this representation rather than ignore it.
func migrateBuildLoans(snapshot *Snapshot) error {
	extra := snapshot.Policy.BuildMemoryOvercommit
	if extra == nil || snapshot.Schema == buildMemoryLedgerSchema {
		return nil
	}
	snapshot.Schema = buildMemoryLedgerSchema
	reserve := missingFloorMemory(snapshot)
	if reserve > snapshot.Policy.Budget.MemoryMiB {
		return errors.New("legacy physical floor reserve exceeds the budget")
	}
	physicalCapacity := snapshot.Policy.Budget.MemoryMiB - reserve
	used := allocatedMemory(snapshot)
	deficit := used - min(used, physicalCapacity)
	if deficit > extra.AdditionalMiB {
		return errors.New("legacy build loans exceed the allowance")
	}
	grants := make([]Grant, 0, len(snapshot.Grants))
	for _, grant := range snapshot.Grants {
		if grant.Pool == buildPool {
			grants = append(grants, grant)
		}
	}
	sort.Slice(grants, func(i, j int) bool {
		if !grants[i].GrantedAt.Equal(grants[j].GrantedAt) {
			return grants[i].GrantedAt.After(grants[j].GrantedAt)
		}
		return grants[i].ID < grants[j].ID
	})
	for _, grant := range grants {
		if deficit == 0 {
			break
		}
		if ProtectsMinimum(snapshot, grant.Request) {
			continue
		}
		grant.BorrowedMemoryMiB = min(deficit, grant.Cost.MemoryMiB)
		snapshot.Grants[grant.ID] = grant
		deficit -= grant.BorrowedMemoryMiB
	}
	if deficit > 0 {
		return errors.New("legacy build loans would borrow a protected floor")
	}
	return validateSnapshot(snapshot)
}

func (p *Policy) validateBuildMemory() error {
	extra := p.BuildMemoryOvercommit
	if extra == nil {
		return nil
	}
	if _, ok := p.Pools[buildPool]; !ok || extra.AdditionalMiB == 0 || extra.AdditionalMiB > p.Budget.MemoryMiB ||
		extra.MinimumAvailableMiB == 0 || extra.MinimumAvailableMiB >= p.Budget.MemoryMiB || p.Budget.MemoryMiB > ^uint64(0)-extra.AdditionalMiB {
		return errors.New("build memory overcommit requires a bounded allowance and positive available-memory reserve")
	}
	return nil
}

func (b *Broker) memoryReady(snapshot *Snapshot, request Request) bool {
	extra := snapshot.Policy.BuildMemoryOvercommit
	if request.Pool != buildPool || extra == nil {
		return true
	}
	if restoresBuildFloor(snapshot, request) {
		return true
	}
	cost, err := RequestCost(&snapshot.Policy, request)
	if err != nil {
		return false
	}
	status := b.BuildMemoryStatus(&snapshot.Policy)
	return status.AvailableMiB != nil && *status.AvailableMiB >= extra.MinimumAvailableMiB &&
		*status.AvailableMiB-extra.MinimumAvailableMiB >= cost.MemoryMiB
}

func restoresBuildFloor(snapshot *Snapshot, request Request) bool {
	pool := snapshot.Policy.Pools[buildPool]
	cost, err := RequestCost(&snapshot.Policy, request)
	return err == nil && countsAsPhysicalFloor(snapshot, request, cost) && minimumCounts(snapshot)[buildPool] < pool.Minimum
}

// BuildMemoryDiagnostic separates measured headroom from configured commitments.
// Unavailable observations block burst starts but never authorize withdrawal.
type BuildMemoryDiagnostic struct {
	State               string    `json:"state"`
	AvailableMiB        *uint64   `json:"availableMiB,omitempty"`
	ObservedAt          time.Time `json:"observedAt"`
	MinimumAvailableMiB uint64    `json:"minimumAvailableMiB"`
}

// BuildMemoryStatus takes one bounded native observation, without changing state.
func (b *Broker) BuildMemoryStatus(policy *Policy) BuildMemoryDiagnostic {
	status := BuildMemoryDiagnostic{State: "disabled"}
	if policy.BuildMemoryOvercommit == nil {
		return status
	}
	status.State = "unavailable"
	status.MinimumAvailableMiB = policy.BuildMemoryOvercommit.MinimumAvailableMiB
	observe := b.ObserveMemory
	if observe == nil {
		observe = nativeMemoryObservation
	}
	observation, err := observe()
	now := b.now()
	if err != nil || observation.ObservedAt.IsZero() || observation.ObservedAt.After(now) || now.Sub(observation.ObservedAt) > 5*time.Second {
		return status
	}
	status.AvailableMiB, status.ObservedAt = &observation.AvailableMiB, observation.ObservedAt
	status.State = "headroom"
	if observation.AvailableMiB < status.MinimumAvailableMiB {
		status.State = memoryStatePressure
	}
	return status
}

func nativeMemoryObservation() (MemoryObservation, error) {
	file, err := os.Open("/proc/meminfo")
	if err != nil {
		return MemoryObservation{}, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 64*1024+1))
	if err != nil || len(data) > 64*1024 {
		return MemoryObservation{}, errors.New("native memory observation is unreadable or oversized")
	}
	available, err := parseAvailableMemory(string(data))
	return MemoryObservation{AvailableMiB: available, ObservedAt: time.Now().UTC()}, err
}

func parseAvailableMemory(data string) (uint64, error) {
	var available uint64
	found := false
	for line := range strings.SplitSeq(data, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != "MemAvailable:" {
			continue
		}
		if found || len(fields) != 3 || fields[2] != "kB" {
			return 0, errors.New("native MemAvailable is invalid")
		}
		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			return 0, fmt.Errorf("native MemAvailable: %w", err)
		}
		available, found = value/1024, true
	}
	if !found {
		return 0, errors.New("native MemAvailable is missing")
	}
	return available, nil
}

// IsBuildCapacityIncrease also permits a reviewed build-only memory guard change.
// First opt-in may also bound the build ceiling; the atomic broker preview
// must prove every existing allocation still fits. Decreasing other capacity,
// changing physical budgets, or changing QA settings needs the ordinary path.
func IsBuildCapacityIncrease(previous, revised *Policy) bool {
	if IsBuildFloorIncrease(previous, revised) {
		return true
	}
	if previous == nil || revised == nil || previous.Validate() != nil || revised.Validate() != nil {
		return false
	}
	old, ok := previous.Pools[buildPool]
	next, exists := revised.Pools[buildPool]
	firstOptIn := previous.BuildMemoryOvercommit == nil && revised.BuildMemoryOvercommit != nil
	if !ok || !exists || old.Minimum == 0 || next.Minimum < old.Minimum || (next.Maximum < old.Maximum && !firstOptIn) ||
		len(old.MinimumRequestIDs) != int(old.Minimum) || len(next.MinimumRequestIDs) != int(next.Minimum) ||
		!slices.Equal(old.MinimumRequestIDs, next.MinimumRequestIDs[:old.Minimum]) {
		return false
	}
	if extra := previous.BuildMemoryOvercommit; extra != nil && (revised.BuildMemoryOvercommit == nil ||
		revised.BuildMemoryOvercommit.AdditionalMiB < extra.AdditionalMiB) {
		return false
	}
	normalized := *revised
	normalized.Pools = maps.Clone(revised.Pools)
	next.Minimum, next.Maximum, next.MinimumRequestIDs = old.Minimum, old.Maximum, old.MinimumRequestIDs
	normalized.Pools[buildPool] = next
	normalized.BuildMemoryOvercommit = previous.BuildMemoryOvercommit
	return reflect.DeepEqual(*previous, normalized) && !reflect.DeepEqual(*previous, *revised)
}
