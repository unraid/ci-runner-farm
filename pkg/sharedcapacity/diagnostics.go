// Package sharedcapacity reports admission state without exposing release capabilities.
package sharedcapacity

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	bolt "go.etcd.io/bbolt"
	"golang.org/x/sys/unix"
)

const (
	diagnosticMaxBytes   = 1 << 20
	diagnosticMaxItems   = 256
	diagnosticLockWait   = time.Second
	diagnosticBudget     = "budget"
	diagnosticWouldAdmit = "would_admit"
)

// ErrDiagnosticUnsafe rejects nonprivate, symlinked or unbounded ledger input.
var ErrDiagnosticUnsafe = errors.New("shared capacity diagnostic input is unsafe or exceeds its bound")

// Diagnostics is a point-in-time observation, never a grant or stopped-workload proof.
// Fence hashes correlate allocations without disclosing release capabilities.
type Diagnostics struct {
	BuildMemory         *BuildMemoryDiagnostic `json:"buildMemory,omitempty"`
	Schema              string                 `json:"schema"`
	ObservedAt          time.Time              `json:"observedAt"`
	ActivePolicyDigest  string                 `json:"activePolicyDigest"`
	LedgerPolicyDigest  string                 `json:"ledgerPolicyDigest"`
	PolicyMatches       bool                   `json:"policyMatches"`
	Policy              Policy                 `json:"policy"`
	Remaining           Resources              `json:"remaining"`
	AllocatedMemoryMiB  uint64                 `json:"allocatedMemoryMiB"`
	PhysicalMemoryMiB   uint64                 `json:"physicalMemoryMiB"`
	BorrowedMemoryMiB   uint64                 `json:"borrowedMemoryMiB"`
	MemoryOvercommitted bool                   `json:"memoryOvercommitted"`
	CommitmentRemaining Resources              `json:"commitmentRemaining"`
	AllocatedVCPUs      uint64                 `json:"allocatedVcpus"`
	CPUOvercommitted    bool                   `json:"cpuOvercommitted"`
	Pools               []PoolDiagnostic       `json:"pools"`
	Grants              []GrantDiagnostic      `json:"grants"`
	Pending             []PendingDiagnostic    `json:"pending"`
	QueueHead           string                 `json:"queueHead,omitempty"`
}

// PoolDiagnostic reports charged allocations and the unfilled guaranteed floor.
type PoolDiagnostic struct {
	Name          string    `json:"name"`
	Granted       uint32    `json:"granted"`
	FloorMissing  uint32    `json:"floorMissing"`
	FloorReserved Resources `json:"floorReserved"`
}

// GrantDiagnostic retains allocation identity without the raw ownership fence.
type GrantDiagnostic struct {
	Request
	Cost              Resources `json:"cost"`
	BorrowedMemoryMiB uint64    `json:"borrowedMemoryMiB,omitempty"`
	FenceSHA256       string    `json:"fenceSha256"`
	GrantedAt         time.Time `json:"grantedAt"`
}

// PendingDiagnostic follows scheduler order including full pools. QueueHead
// separately names the first request whose pool is below its maximum.
type PendingDiagnostic struct {
	Pending
	Cost              Resources `json:"cost"`
	AgeSeconds        int64     `json:"ageSeconds"`
	EffectivePriority uint64    `json:"effectivePriority"`
	Reason            string    `json:"reason"`
	Constraint        string    `json:"constraint,omitempty"`
}

// Diagnose opens only an existing ledger, with no initialization or write
// transaction. It refuses incomplete/oversized snapshots rather than truncating
// accounting. A policy mismatch exposes ledger facts but no admission prediction.
func (b *Broker) Diagnose(active *Policy) (Diagnostics, error) {
	digest, err := policyDigest(active)
	if err != nil {
		return Diagnostics{}, err
	}
	db, err := bolt.Open(b.Path, 0o600, &bolt.Options{
		ReadOnly: true, Timeout: diagnosticLockWait, OpenFile: openDiagnosticFile,
	})
	if err != nil {
		return Diagnostics{}, err
	}
	defer db.Close()
	var snapshot Snapshot
	err = db.View(func(tx *bolt.Tx) error {
		bucket := tx.Bucket([]byte("admission"))
		if bucket == nil {
			return ErrUninitialized
		}
		data := bucket.Get([]byte("snapshot"))
		if len(data) == 0 {
			return ErrUninitialized
		}
		if len(data) > diagnosticMaxBytes {
			return ErrDiagnosticUnsafe
		}
		if decodeErr := json.Unmarshal(data, &snapshot); decodeErr != nil {
			return decodeErr
		}
		if !supportedLedgerSchema(snapshot.Schema) || snapshot.Grants == nil || snapshot.Pending == nil {
			return ErrUninitialized
		}
		if len(snapshot.Grants) > diagnosticMaxItems || len(snapshot.Pending) > diagnosticMaxItems || len(snapshot.Policy.Pools) > diagnosticMaxItems {
			return ErrDiagnosticUnsafe
		}
		return validateSnapshot(&snapshot)
	})
	if err != nil {
		return Diagnostics{}, err
	}
	report := diagnoseSnapshot(&snapshot, digest, b.now())
	b.annotateBuildMemory(&snapshot, &report)
	return report, nil
}

func (b *Broker) annotateBuildMemory(snapshot *Snapshot, report *Diagnostics) {
	if snapshot.Policy.BuildMemoryOvercommit == nil {
		return
	}
	status := b.BuildMemoryStatus(&snapshot.Policy)
	report.BuildMemory = &status
	for index := range report.Pending {
		pending := &report.Pending[index]
		if (pending.Reason != diagnosticWouldAdmit && pending.Reason != memoryObservationRequired) || pending.Pool != buildPool || restoresBuildFloor(snapshot, pending.Request) {
			continue
		}
		pending.Reason, pending.Constraint = diagnosticWouldAdmit, ""
		if status.AvailableMiB == nil {
			pending.Reason, pending.Constraint = memoryObservationRequired, memoryHeadroom
			continue
		}
		if *status.AvailableMiB < status.MinimumAvailableMiB || *status.AvailableMiB-status.MinimumAvailableMiB < pending.Cost.MemoryMiB {
			pending.Reason, pending.Constraint = memoryPressure, memoryHeadroom
		}
	}
}

// Open every component through its parent descriptor. O_NOFOLLOW prevents a
// concurrent replacement with a symlink from escaping the validated path.
func openDiagnosticFile(path string, flags int, _ os.FileMode) (*os.File, error) {
	if flags != os.O_RDONLY || !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return nil, ErrDiagnosticUnsafe
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	parent := os.NewFile(uintptr(fd), "/")
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	for _, part := range parts[:len(parts)-1] {
		next, openErr := unix.Openat(int(parent.Fd()), part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		parent.Close()
		if openErr != nil {
			return nil, openErr
		}
		parent = os.NewFile(uintptr(next), part)
	}
	defer parent.Close()
	fd, err = unix.Openat(int(parent.Fd()), parts[len(parts)-1], unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || info.Size() < 1 || info.Size() > 64<<20 {
		file.Close()
		return nil, ErrDiagnosticUnsafe
	}
	return file, nil
}

func diagnoseSnapshot(snapshot *Snapshot, digest string, now time.Time) Diagnostics {
	report := Diagnostics{
		Schema: "shared-capacity-diagnostics/v1", ObservedAt: now,
		ActivePolicyDigest: digest, LedgerPolicyDigest: snapshot.PolicyDigest,
		PolicyMatches: digest == snapshot.PolicyDigest, Policy: snapshot.Policy,
		Remaining: snapshot.Policy.Budget, CommitmentRemaining: snapshot.Policy.commitmentBudget(),
		Pools: []PoolDiagnostic{}, Grants: []GrantDiagnostic{}, Pending: []PendingDiagnostic{},
	}
	counts := map[string]uint32{}
	for _, id := range slices.Sorted(maps.Keys(snapshot.Grants)) {
		grant := snapshot.Grants[id]
		hash := sha256.Sum256([]byte(grant.Fence))
		report.Grants = append(report.Grants, GrantDiagnostic{Request: grant.Request, Cost: grant.Cost, BorrowedMemoryMiB: grant.BorrowedMemoryMiB, FenceSHA256: hex.EncodeToString(hash[:]), GrantedAt: grant.GrantedAt})
		physicalCost := grant.Cost
		physicalCost.MemoryMiB -= grant.BorrowedMemoryMiB
		report.Remaining = subtract(report.Remaining, physicalCost)
		report.CommitmentRemaining = subtract(report.CommitmentRemaining, grant.Cost)
		report.AllocatedMemoryMiB += grant.Cost.MemoryMiB
		report.PhysicalMemoryMiB += physicalCost.MemoryMiB
		report.BorrowedMemoryMiB += grant.BorrowedMemoryMiB
		report.AllocatedVCPUs += uint64(grant.Cost.VCPUs)
		counts[grant.Pool]++
	}
	report.MemoryOvercommitted = report.AllocatedMemoryMiB > snapshot.Policy.Budget.MemoryMiB
	report.CPUOvercommitted = report.AllocatedVCPUs > uint64(snapshot.Policy.Budget.VCPUs)
	floorCounts := minimumCounts(snapshot)
	for _, name := range slices.Sorted(maps.Keys(snapshot.Policy.Pools)) {
		pool := snapshot.Policy.Pools[name]
		missing := pool.Minimum - min(pool.Minimum, floorCounts[name])
		report.Pools = append(report.Pools, PoolDiagnostic{
			Name: name, Granted: counts[name], FloorMissing: missing,
			FloorReserved: Resources{MemoryMiB: pool.Cost.MemoryMiB * uint64(missing), VCPUs: pool.Cost.VCPUs * missing},
		})
	}
	if report.PolicyMatches {
		report.QueueHead = queueHead(snapshot, now)
	}
	ordered := *snapshot
	ordered.Pending = maps.Clone(snapshot.Pending)
	for len(ordered.Pending) > 0 {
		id := eligibleQueueHead(&ordered, now, true, true)
		pending := ordered.Pending[id]
		if pending.Owner != nil {
			owner := *pending.Owner
			pending.Owner = &owner
			hash := sha256.Sum256([]byte(pending.Owner.Incarnation))
			pending.Owner.Incarnation = "sha256:" + hex.EncodeToString(hash[:])
		}
		cost := diagnosticCost(&snapshot.Policy, pending.Request)
		reason, constraint := diagnosticReason(snapshot, &pending, &report)
		report.Pending = append(report.Pending, PendingDiagnostic{
			Pending: pending, Cost: cost,
			AgeSeconds: max(0, int64(now.Sub(pending.QueuedAt)/time.Second)), EffectivePriority: effectivePriority(snapshot, &pending, now),
			Reason: reason, Constraint: constraint,
		})
		delete(ordered.Pending, id)
	}
	return report
}

func diagnosticReason(snapshot *Snapshot, pending *Pending, report *Diagnostics) (reason, constraint string) {
	if pending.Suspended {
		return "owner_wait_ended", ""
	}
	if !report.PolicyMatches {
		return "policy_changed", ""
	}
	cost := diagnosticCost(&snapshot.Policy, pending.Request)
	for _, pool := range report.Pools {
		if pool.Name == pending.Pool && pool.Granted >= snapshot.Policy.Pools[pending.Pool].Maximum {
			constraint = "pool_maximum"
		}
	}
	remaining := report.Remaining
	if pending.Pool == buildPool {
		remaining = report.CommitmentRemaining
	}
	if constraint == "" && !snapshot.Policy.fitsHost(remaining, cost) {
		constraint = "host_budget"
	}
	if constraint == "" && !canAdmit(snapshot, pending.Request) {
		constraint = "floor_reserve"
	}
	if report.QueueHead != pending.ID {
		if !canBackfill(snapshot, pending.Request, report.QueueHead) {
			return reasonPriority, constraint
		}
		return memoryObservationRequired, memoryHeadroom
	}
	if constraint != "" {
		return diagnosticBudget, constraint
	}
	if pending.Pool == buildPool && snapshot.Policy.BuildMemoryOvercommit != nil && !restoresBuildFloor(snapshot, pending.Request) {
		return memoryObservationRequired, memoryHeadroom
	}
	return diagnosticWouldAdmit, ""
}

// diagnosticCost is used only after validateSnapshot has checked RequestCost.
func diagnosticCost(policy *Policy, request Request) Resources {
	if request.Resources == (Resources{}) {
		return policy.Pools[request.Pool].Cost
	}
	return request.Resources
}
