// Package sharedcapacity persists fenced grants against one shared host resource budget.
package sharedcapacity

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	bolt "go.etcd.io/bbolt"
)

// ErrPolicyChanged requires explicit policy reconciliation rather than an
// implicit budget change on a workload's next admission attempt.
var ErrPolicyChanged = errors.New("shared capacity policy changed; reconcile the admission ledger")

// ErrFenceMismatch rejects a delayed release belonging to an earlier workload.
var ErrFenceMismatch = errors.New("shared capacity grant fence differs")

const (
	hostReserveGuestPool           = "qa-guest"
	ledgerSchema                   = "shared-capacity-ledger/v1"
	ownedWaitLedgerSchema          = "shared-capacity-ledger/v2"
	softCPULedgerSchema            = "shared-capacity-ledger/v3"
	legacyBuildMemoryLedgerSchema  = "shared-capacity-ledger/v4"
	buildMemoryLedgerSchema        = "shared-capacity-ledger/v5"
	sharedMemoryLedgerSchema       = "shared-capacity-ledger/v7"
	legacySharedMemoryLedgerSchema = "shared-capacity-ledger/v6"
	reasonPriority                 = "priority"
)

// Request identifies a workload's admission intent. IDs are stable across retries
// but must be unique across distinct executions of a workload.
type Request struct {
	ID        string    `json:"id"`
	Pool      string    `json:"pool"`
	Resources Resources `json:"resources,omitzero"`
}

// Grant is an immutable allocation with a fence for the workload's release.
// A stopped continuation may rotate the fence without releasing its charge.
type Grant struct {
	Request
	Cost              Resources `json:"cost"`
	BorrowedMemoryMiB uint64    `json:"borrowedMemoryMiB,omitempty"`
	Fence             string    `json:"fence"`
	GrantedAt         time.Time `json:"grantedAt"`
}

// Pending preserves age across polling, daemon restarts and lower priority arrivals.
type Pending struct {
	Request
	QueuedAt  time.Time  `json:"queuedAt"`
	Owner     *WaitOwner `json:"owner,omitzero"`
	Suspended bool       `json:"suspended,omitempty"`
	Revision  uint64     `json:"revision,omitempty"`
}

// WaitOwner binds a pre-start wait to one operation under its lifecycle lease.
// Incarnation prevents a delayed caller from changing a later waiting attempt.
type WaitOwner struct {
	PrincipalID   string `json:"principalId"`
	ReservationID string `json:"reservationId"`
	CapacityID    string `json:"capacityId"`
	OperationID   string `json:"operationId"`
	RequestKey    string `json:"requestKey"`
	Generation    uint64 `json:"generation"`
	Incarnation   string `json:"incarnation"`
}

func (o *WaitOwner) valid() bool {
	return o != nil && o.PrincipalID != "" && o.ReservationID != "" && o.CapacityID != "" && o.OperationID != "" && o.RequestKey != "" && o.Generation != 0 && o.Incarnation != ""
}

// Snapshot records allocations and waiting demand without expiring allocations.
type Snapshot struct {
	Starts       map[string]StartReservation `json:"starts,omitzero"`
	Schema       string                      `json:"schema"`
	PolicyDigest string                      `json:"policyDigest"`
	Policy       Policy                      `json:"policy"`
	Grants       map[string]Grant            `json:"grants"`
	Pending      map[string]Pending          `json:"pending"`
}

// Decision distinguishes a durable grant from queued demand.
type Decision struct {
	Start    *StartReservation `json:"start,omitempty"`
	Admitted bool              `json:"admitted"`
	Reason   string            `json:"reason"`
	Grant    *Grant            `json:"grant,omitempty"`
	Pending  *Pending          `json:"pending,omitempty"`
}

// Broker opens a separate admission database for each short transaction. It must
// not share the provider's state DB, which can be closed around external effects.
type Broker struct {
	Path          string
	Now           func() time.Time
	ObserveMemory func() (MemoryObservation, error)
}

func (b *Broker) now() time.Time {
	if b.Now != nil {
		return b.Now().UTC()
	}
	return time.Now().UTC()
}

func policyDigest(policy *Policy) (string, error) {
	if err := policy.Validate(); err != nil {
		return "", err
	}
	data, err := json.Marshal(policy)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

func (b *Broker) update(policy *Policy, initialize bool, apply func(*Snapshot) error) error {
	digest, err := policyDigest(policy)
	if err != nil {
		return err
	}
	if pathErr := b.validatePath(initialize); pathErr != nil {
		return pathErr
	}
	db, err := bolt.Open(b.Path, 0o600, &bolt.Options{Timeout: 5 * time.Second})
	if err != nil {
		return err
	}
	defer db.Close()
	return db.Update(func(tx *bolt.Tx) error {
		bucket, err := tx.CreateBucketIfNotExists([]byte("admission"))
		if err != nil {
			return err
		}
		snapshot, readErr := readSnapshot(bucket, policy, digest, initialize)
		if readErr != nil {
			return readErr
		}
		if migrationErr := migrateBuildLoans(&snapshot); migrationErr != nil {
			return migrationErr
		}
		if err := migrateSharedStarts(&snapshot); err != nil {
			return err
		}
		if applyErr := apply(&snapshot); applyErr != nil {
			return applyErr
		}
		if validationErr := validateSnapshot(&snapshot); validationErr != nil {
			return validationErr
		}
		data, err := json.Marshal(snapshot)
		if err != nil {
			return err
		}
		return bucket.Put([]byte("snapshot"), data)
	})
}

// ReclassifyHostReserve removes one reviewed allocation only after its owner
// proves independent host-reserve coverage. It is not stopped-workload Release.
// The diagnostic pin binds every immutable field without exposing the raw fence.
func (b *Broker) ReclassifyHostReserve(policy *Policy, expected *GrantDiagnostic, proveReserved func(Grant) error) (bool, error) {
	if expected == nil || expected.ID == "" || expected.Pool != hostReserveGuestPool || expected.Resources == (Resources{}) || expected.Cost != expected.Resources || proveReserved == nil {
		return false, errors.New("host reserve classification requires an explicit reviewed guest allocation and proof")
	}
	changed := false
	absent := errors.New("host reserve allocation is already absent")
	err := b.update(policy, false, func(snapshot *Snapshot) error {
		grant, exists := snapshot.Grants[expected.ID]
		if !exists {
			return absent
		}
		fenceHash := sha256.Sum256([]byte(grant.Fence))
		if grant.Request != expected.Request || grant.Cost != expected.Cost || hex.EncodeToString(fenceHash[:]) != expected.FenceSHA256 || !grant.GrantedAt.Equal(expected.GrantedAt) {
			return ErrFenceMismatch
		}
		if err := proveReserved(grant); err != nil {
			return err
		}
		// Compare the complete raw incarnation captured in this transaction.
		if snapshot.Grants[expected.ID] != grant {
			return ErrFenceMismatch
		}
		delete(snapshot.Grants, expected.ID)
		delete(snapshot.Starts, expected.ID)
		changed = true
		return nil
	})
	if errors.Is(err, absent) {
		return false, nil
	}
	return changed && err == nil, err
}

// ReclassifyPendingHostReserve removes only legacy ownerless demand already
// covered by signed host reserve. Running-reserve proof is distinct from the
// stopped-workload proof required by CancelPending. A promoted request fails.
func (b *Broker) ReclassifyPendingHostReserve(policy *Policy, expected *Pending, proveReserved func() error) (bool, error) {
	if expected == nil || expected.ID == "" || expected.Pool != hostReserveGuestPool || expected.Resources == (Resources{}) || expected.Owner != nil || expected.Suspended || expected.Revision != 0 || proveReserved == nil {
		return false, errors.New("pending reserve classification requires exact legacy ownerless demand and proof")
	}
	changed := false
	absent := errors.New("host reserve pending demand is already absent")
	err := b.update(policy, false, func(snapshot *Snapshot) error {
		if _, granted := snapshot.Grants[expected.ID]; granted {
			return errors.New("pending router demand was promoted to an allocation")
		}
		current, found := snapshot.Pending[expected.ID]
		if !found {
			return absent
		}
		if current.Request != expected.Request || !current.QueuedAt.Equal(expected.QueuedAt) || current.Owner != nil || current.Suspended || current.Revision != 0 {
			return errors.New("legacy pending router incarnation changed")
		}
		if err := proveReserved(); err != nil {
			return err
		}
		delete(snapshot.Pending, expected.ID)
		changed = true
		return nil
	})
	if errors.Is(err, absent) {
		return false, nil
	}
	return changed && err == nil, err
}

func (b *Broker) validatePath(initialize bool) error {
	if !filepath.IsAbs(b.Path) {
		return errors.New("shared capacity ledger path must be absolute")
	}
	if mkdirErr := os.MkdirAll(filepath.Dir(b.Path), 0o700); mkdirErr != nil {
		return mkdirErr
	}
	if info, statErr := os.Lstat(b.Path); statErr == nil && (!info.Mode().IsRegular() || info.Mode()&0o077 != 0) {
		return errors.New("shared capacity ledger must be a private regular file")
	} else if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return statErr
	} else if errors.Is(statErr, os.ErrNotExist) && !initialize {
		return errors.New("shared capacity ledger is absent; reconcile owned workloads before initialization")
	}
	return nil
}

// ErrUninitialized identifies a ledger with no committed snapshot or grants.
var ErrUninitialized = errors.New("shared capacity ledger is uninitialized")

func readSnapshot(bucket *bolt.Bucket, policy *Policy, digest string, initialize bool) (Snapshot, error) {
	var snapshot Snapshot
	data := bucket.Get([]byte("snapshot"))
	if data == nil {
		if !initialize {
			return snapshot, ErrUninitialized
		}
		schema := ledgerSchema
		if policy.SoftCPU() {
			schema = softCPULedgerSchema
		}
		if policy.BuildMemoryOvercommit != nil {
			schema = buildMemoryLedgerSchema
		}
		if policy.SharedMemoryHeadroom {
			schema = sharedMemoryLedgerSchema
		}
		return Snapshot{Schema: schema, PolicyDigest: digest, Policy: *policy, Grants: map[string]Grant{}, Pending: map[string]Pending{}}, nil
	}
	if decodeErr := json.Unmarshal(data, &snapshot); decodeErr != nil {
		return snapshot, fmt.Errorf("read shared capacity ledger: %w", decodeErr)
	}
	if !supportedLedgerSchema(snapshot.Schema) || snapshot.Grants == nil || snapshot.Pending == nil {
		return snapshot, errors.New("shared capacity ledger is invalid")
	}
	if snapshot.PolicyDigest != digest {
		return snapshot, ErrPolicyChanged
	}
	validationErr := validateSnapshot(&snapshot)
	return snapshot, validationErr
}

// Initialize establishes an empty ledger only after proving that every owned
// workload is stopped. An existing ledger is validated and never reset.
func (b *Broker) Initialize(policy *Policy, proveHostStopped func() error) error {
	if proveHostStopped == nil {
		return errors.New("shared capacity initialization requires stopped-host proof")
	}
	return b.update(policy, true, func(snapshot *Snapshot) error {
		if len(snapshot.Grants) != 0 || len(snapshot.Pending) != 0 {
			return nil
		}
		return proveHostStopped()
	})
}

func validateSnapshot(snapshot *Snapshot) error {
	if snapshot == nil {
		return errors.New("shared capacity ledger is absent")
	}
	if !validPolicySchema(snapshot) {
		return errors.New("shared capacity ledger schema does not support its policy")
	}
	digest, err := policyDigest(&snapshot.Policy)
	if err != nil || digest != snapshot.PolicyDigest {
		return errors.New("shared capacity ledger policy is invalid")
	}
	remaining := snapshot.Policy.commitmentBudget()
	nonBuildRemaining := snapshot.Policy.Budget.MemoryMiB
	counts := map[string]uint32{}
	var totalMemory uint64
	for id, grant := range snapshot.Grants {
		if totalMemory > ^uint64(0)-grant.Cost.MemoryMiB {
			return errors.New("shared capacity memory accounting overflow")
		}
		totalMemory += grant.Cost.MemoryMiB
		if snapshot.Schema == sharedMemoryLedgerSchema {
			remaining.MemoryMiB = snapshot.Policy.Budget.MemoryMiB
		}
		pool, exists := snapshot.Policy.Pools[grant.Pool]
		if id != grant.ID || !exists || !validGrant(snapshot, &grant, remaining) {
			return errors.New("shared capacity ledger grant is invalid")
		}
		if grant.Pool != buildPool {
			physical := grant.Cost.MemoryMiB - grant.BorrowedMemoryMiB
			if physical > nonBuildRemaining {
				return errors.New("non-build grants exceed the physical memory budget")
			}
			nonBuildRemaining -= physical
		}
		remaining = subtract(remaining, grant.Cost)
		counts[grant.Pool]++
		if counts[grant.Pool] > pool.Maximum {
			return errors.New("shared capacity ledger exceeds its pool limit")
		}
	}
	for id, pending := range snapshot.Pending {
		_, exists := snapshot.Policy.Pools[pending.Pool]
		_, costErr := RequestCost(&snapshot.Policy, pending.Request)
		_, granted := snapshot.Grants[id]
		if id != pending.ID || id == "" || !exists || costErr != nil || pending.QueuedAt.IsZero() || granted {
			return errors.New("shared capacity ledger pending request is invalid")
		}
		if err := validateOwnedWait(snapshot.Schema, &pending); err != nil {
			return err
		}
	}
	if err := validateStartReservations(snapshot); err != nil {
		return err
	}
	return validateBuildLoans(snapshot)
}

func validPolicySchema(snapshot *Snapshot) bool {
	return supportedLedgerSchema(snapshot.Schema) && (snapshot.Policy.SharedMemoryHeadroom == (sharedMemorySchema(snapshot.Schema))) &&
		(!snapshot.Policy.SoftCPU() || snapshot.Schema == softCPULedgerSchema || snapshot.Schema == legacyBuildMemoryLedgerSchema || snapshot.Schema == buildMemoryLedgerSchema || sharedMemorySchema(snapshot.Schema)) &&
		(snapshot.Policy.BuildMemoryOvercommit == nil || snapshot.Schema == legacyBuildMemoryLedgerSchema || snapshot.Schema == buildMemoryLedgerSchema || sharedMemorySchema(snapshot.Schema))
}

func validGrant(snapshot *Snapshot, grant *Grant, remaining Resources) bool {
	cost, err := chargedRequestCost(&snapshot.Policy, grant)
	if grant.BorrowedMemoryMiB > 0 && ((snapshot.Schema != buildMemoryLedgerSchema && !sharedMemorySchema(snapshot.Schema)) || (grant.Pool != buildPool && !snapshot.Policy.SharedMemoryHeadroom) ||
		snapshot.Policy.BuildMemoryOvercommit == nil || grant.BorrowedMemoryMiB > grant.Cost.MemoryMiB ||
		(len(snapshot.Policy.Pools[grant.Pool].MinimumRequestIDs) > 0 && snapshot.Policy.Pools[grant.Pool].CountsTowardMinimum(grant.ID))) {
		return false
	}
	return grant.ID != "" && err == nil && grant.Cost == cost && len(grant.Fence) == 32 &&
		!grant.GrantedAt.IsZero() && snapshot.Policy.fitsHost(remaining, grant.Cost)
}

func chargedRequestCost(policy *Policy, grant *Grant) (Resources, error) {
	cost, err := RequestCost(policy, grant.Request)
	// A reviewed CPU increase changes future defaults, not an implicit
	// request's immutable admitted charge. Explicit sizes and memory stay exact.
	if err == nil && grant.Resources == (Resources{}) && grant.Cost.MemoryMiB == cost.MemoryMiB &&
		grant.Cost.VCPUs > 0 && grant.Cost.VCPUs <= cost.VCPUs {
		return grant.Cost, nil
	}
	return cost, err
}

// Admit atomically records intent and grants the next eligible request.
// A physically blocked non-build head permits build-only backfill funded
// entirely by the disjoint allowance. Its physical headroom and age stay intact.
func (b *Broker) Admit(policy *Policy, request Request) (Decision, error) {
	return b.admit(policy, request, nil)
}

// AdmitOwned preserves retry age but only the exact owner may resume its wait.
// The caller must hold the exclusive capacity lifecycle lease.
func (b *Broker) AdmitOwned(policy *Policy, request Request, owner *WaitOwner) (Decision, error) {
	if !owner.valid() {
		return Decision{}, errors.New("shared capacity wait owner is incomplete")
	}
	return b.admit(policy, request, owner)
}

func (b *Broker) admit(policy *Policy, request Request, owner *WaitOwner) (Decision, error) {
	decision := Decision{Reason: "queued"}
	if request.ID == "" || len(request.ID) > 200 {
		return decision, errors.New("shared capacity request ID is invalid")
	}
	err := b.update(policy, false, func(snapshot *Snapshot) error {
		cost, err := RequestCost(policy, request)
		if err != nil {
			return err
		}
		if grant, exists := snapshot.Grants[request.ID]; exists {
			if grant.Request != request {
				return errors.New("shared capacity request identity conflicts")
			}
			decision = Decision{Admitted: true, Reason: "existing", Grant: &grant}
			if snapshot.Policy.SharedMemoryHeadroom {
				start := snapshot.Starts[grant.ID]
				decision.Start = &start
			}
			return nil
		}
		pending, exists := snapshot.Pending[request.ID]
		if exists {
			if pending.Request != request || !sameWaitOwner(pending.Owner, owner) {
				return errors.New("shared capacity waiting owner or request conflicts")
			}
		} else {
			pending = Pending{Request: request, QueuedAt: b.now(), Owner: owner}
			if owner != nil {
				pending.Revision = 1
			}
		}
		if pending.Suspended {
			pending.Revision++
		}
		pending.Suspended = false
		if owner != nil && snapshot.Schema == ledgerSchema {
			// Older writers reject v2 rather than ignoring suspended intent.
			snapshot.Schema = ownedWaitLedgerSchema
		}
		snapshot.Pending[request.ID] = pending
		decision.Pending = &pending
		borrowed, constraint := b.admissionFunding(snapshot, request)
		if constraint != "" {
			decision.Reason = constraint
			return nil
		}
		fence := make([]byte, 16)
		if _, err := rand.Read(fence); err != nil {
			return err
		}
		grant := Grant{Request: request, Cost: cost, BorrowedMemoryMiB: borrowed, Fence: hex.EncodeToString(fence), GrantedAt: b.now()}
		snapshot.Grants[request.ID] = grant
		delete(snapshot.Pending, request.ID)
		decision = Decision{Admitted: true, Reason: "granted", Grant: &grant}
		if snapshot.Policy.SharedMemoryHeadroom {
			start := reservedStart(grant)
			snapshot.Starts[grant.ID] = start
			decision.Start = &start
		}
		return nil
	})
	return decision, err
}

func queueHead(snapshot *Snapshot, now time.Time) string {
	return eligibleQueueHead(snapshot, now, false, false)
}

func eligibleQueueHead(snapshot *Snapshot, now time.Time, includeFull, includeSuspended bool) string {
	queue := make([]Pending, 0, len(snapshot.Pending))
	counts := map[string]uint32{}
	floors := minimumCounts(snapshot)
	for _, grant := range snapshot.Grants {
		counts[grant.Pool]++
	}
	for _, pending := range snapshot.Pending {
		if pending.Suspended && !includeSuspended {
			continue
		}
		if includeFull || counts[pending.Pool] < snapshot.Policy.Pools[pending.Pool].Maximum {
			queue = append(queue, pending)
		}
	}
	sort.Slice(queue, func(i, j int) bool {
		leftPool, rightPool := snapshot.Policy.Pools[queue[i].Pool], snapshot.Policy.Pools[queue[j].Pool]
		leftFloor := countsAsPhysicalFloor(snapshot, queue[i].Request, diagnosticCost(&snapshot.Policy, queue[i].Request)) && floors[queue[i].Pool] < leftPool.Minimum
		rightFloor := countsAsPhysicalFloor(snapshot, queue[j].Request, diagnosticCost(&snapshot.Policy, queue[j].Request)) && floors[queue[j].Pool] < rightPool.Minimum
		if leftFloor != rightFloor {
			return leftFloor
		}
		left, right := effectivePriority(snapshot, &queue[i], now), effectivePriority(snapshot, &queue[j], now)
		if left != right {
			return left > right
		}
		if !queue[i].QueuedAt.Equal(queue[j].QueuedAt) {
			return queue[i].QueuedAt.Before(queue[j].QueuedAt)
		}
		return queue[i].ID < queue[j].ID
	})
	if len(queue) == 0 {
		return ""
	}
	return queue[0].ID
}

func effectivePriority(snapshot *Snapshot, pending *Pending, now time.Time) uint64 {
	priority := uint64(snapshot.Policy.Pools[pending.Pool].Priority)
	if now.After(pending.QueuedAt) {
		priority += uint64(max(0, now.Sub(pending.QueuedAt)/time.Second)) / uint64(snapshot.Policy.AgingSeconds)
	}
	return priority
}

func canAdmit(snapshot *Snapshot, request Request) bool {
	_, ok := admissionLoan(snapshot, request, false)
	return ok
}

// admissionLoan funds physical floors first. Backfill may spend only the
// disjoint build allowance, so it cannot postpone the physical queue head.
func admissionLoan(snapshot *Snapshot, request Request, backfill bool) (uint64, bool) {
	cost, err := RequestCost(&snapshot.Policy, request)
	if err != nil {
		return 0, false
	}
	target := request.Pool
	budget := snapshot.Policy.Budget
	used := physicalMemory(snapshot)
	if used > budget.MemoryMiB {
		return 0, false
	}
	remaining := Resources{MemoryMiB: budget.MemoryMiB - used, VCPUs: budget.VCPUs}
	counts := map[string]uint32{}
	for _, grant := range snapshot.Grants {
		if !snapshot.Policy.SoftCPU() && grant.Cost.VCPUs > remaining.VCPUs {
			return 0, false
		}
		remaining = subtract(remaining, Resources{VCPUs: grant.Cost.VCPUs})
		counts[grant.Pool]++
	}
	pool := snapshot.Policy.Pools[target]
	if counts[target] >= pool.Maximum || (!snapshot.Policy.SoftCPU() && cost.VCPUs > remaining.VCPUs) {
		return 0, false
	}
	remaining = subtract(remaining, Resources{VCPUs: cost.VCPUs})
	counts[target]++
	floors := minimumCounts(snapshot)
	restoresFloor := countsAsPhysicalFloor(snapshot, request, cost) && floors[target] < pool.Minimum
	if countsAsPhysicalFloor(snapshot, request, cost) {
		floors[target]++
	}
	for name, other := range snapshot.Policy.Pools {
		missing := other.Minimum - min(floors[name], other.Minimum)
		if counts[name]+missing > other.Maximum {
			return 0, false
		}
		for range missing {
			if !snapshot.Policy.fitsHost(remaining, other.Cost) {
				return 0, false
			}
			remaining = subtract(remaining, other.Cost)
		}
	}
	borrowed := cost.MemoryMiB - min(cost.MemoryMiB, remaining.MemoryMiB)
	if backfill && !snapshot.Policy.SharedMemoryHeadroom {
		borrowed = cost.MemoryMiB
	}
	if borrowed == 0 {
		return 0, true
	}
	extra := snapshot.Policy.BuildMemoryOvercommit
	alreadyBorrowed := borrowedMemory(snapshot)
	if (target != buildPool && !snapshot.Policy.SharedMemoryHeadroom) || restoresFloor || (len(pool.MinimumRequestIDs) > 0 && pool.CountsTowardMinimum(request.ID)) ||
		extra == nil || (!snapshot.Policy.SharedMemoryHeadroom && (alreadyBorrowed > extra.AdditionalMiB || borrowed > extra.AdditionalMiB-alreadyBorrowed)) {
		return 0, false
	}
	return borrowed, true
}

func canBackfill(snapshot *Snapshot, request Request, head string) bool {
	pending, found := snapshot.Pending[head]
	if !found || request.Pool != buildPool || pending.Pool == buildPool || snapshot.Policy.BuildMemoryOvercommit == nil ||
		!snapshot.Policy.SoftCPU() || restoresBuildFloor(snapshot, request) || canAdmit(snapshot, pending.Request) {
		return false
	}
	_, ok := admissionLoan(snapshot, request, true)
	return ok
}

// RenewStopped rotates the fence of an exact stopped grant without removing its
// charge or reordering pending work. The caller must hold the exclusive workload
// lifecycle lease. Changed resources require ordinary release and admission.
func (b *Broker) RenewStopped(policy *Policy, expected *Grant, proveStopped func(Grant) error) (Grant, error) {
	var renewed Grant
	if expected == nil || expected.Fence == "" || proveStopped == nil {
		return renewed, errors.New("shared capacity continuation requires exact grant and stopped proof")
	}
	err := b.update(policy, false, func(snapshot *Snapshot) error {
		grant, exists := snapshot.Grants[expected.ID]
		if !exists || grant.Fence != expected.Fence {
			return ErrFenceMismatch
		}
		if grant.Request != expected.Request || grant.Cost != expected.Cost || !grant.GrantedAt.Equal(expected.GrantedAt) {
			return errors.New("shared capacity continuation grant differs")
		}
		if err := proveStopped(grant); err != nil {
			return fmt.Errorf("shared capacity continuation cannot prove workload stopped: %w", err)
		}
		fence := make([]byte, 16)
		if _, err := rand.Read(fence); err != nil {
			return err
		}
		grant.Fence = hex.EncodeToString(fence)
		grant.GrantedAt = b.now()
		if snapshot.Policy.SharedMemoryHeadroom && !b.memoryReadyExcluding(snapshot, grant.Request, grant.ID) {
			return ErrMemoryHeadroom
		}
		snapshot.Grants[grant.ID] = grant
		if snapshot.Policy.SharedMemoryHeadroom {
			snapshot.Starts[grant.ID] = reservedStart(grant)
		}
		renewed = grant
		return nil
	})
	return renewed, err
}

// Release calls proveStopped inside the admission transaction before reclaiming
// the exact fenced grant. Unknown state retains the allocation. The owner must
// serialize workload start/stop with this call; the broker never kills work.
func (b *Broker) Release(policy *Policy, id, fence string, proveStopped func(Grant) error) error {
	if proveStopped == nil {
		return errors.New("shared capacity release requires stopped-workload proof")
	}
	return b.update(policy, false, func(snapshot *Snapshot) error {
		grant, exists := snapshot.Grants[id]
		if !exists || grant.Fence != fence {
			return ErrFenceMismatch
		}
		if err := proveStopped(grant); err != nil {
			return fmt.Errorf("shared capacity release cannot prove workload stopped: %w", err)
		}
		delete(snapshot.Grants, id)
		delete(snapshot.Starts, id)
		return nil
	})
}

// Cancel removes waiting demand only. It cannot release a granted workload.
func (b *Broker) Cancel(policy *Policy, request Request) error {
	return b.update(policy, false, func(snapshot *Snapshot) error {
		if _, granted := snapshot.Grants[request.ID]; granted {
			return errors.New("shared capacity granted workload requires a fenced release")
		}
		if pending, exists := snapshot.Pending[request.ID]; exists && pending.Request != request {
			return errors.New("shared capacity request identity conflicts")
		} else if exists && pending.Owner != nil {
			return errors.New("owned waiting demand requires exact stopped reconciliation")
		}
		delete(snapshot.Pending, request.ID)
		return nil
	})
}

// CancelPending ends only the observed waiting incarnation. The owner must hold
// its lifecycle lease and attest that the workload is stopped before deletion.
// A later enqueue or grant can never be removed by an older cleanup attempt.
func (b *Broker) CancelPending(policy *Policy, expected *Pending, attest func() error) (bool, error) {
	if expected == nil || expected.ID == "" || expected.QueuedAt.IsZero() || attest == nil {
		return false, errors.New("pending cancellation requires exact identity and stopped attestation")
	}
	cancelled := false
	err := b.update(policy, false, func(snapshot *Snapshot) error {
		if _, granted := snapshot.Grants[expected.ID]; granted {
			return errors.New("shared capacity granted workload requires a fenced release")
		}
		current, found := snapshot.Pending[expected.ID]
		if !found {
			return nil
		}
		if current.Request != expected.Request || !current.QueuedAt.Equal(expected.QueuedAt) || !sameWaitOwner(current.Owner, expected.Owner) || current.Suspended != expected.Suspended || current.Revision != expected.Revision {
			return errors.New("shared capacity pending incarnation changed")
		}
		if err := attest(); err != nil {
			return err
		}
		delete(snapshot.Pending, expected.ID)
		cancelled = true
		return nil
	})
	return cancelled && err == nil, err
}

func supportedLedgerSchema(schema string) bool {
	return schema == ledgerSchema || schema == ownedWaitLedgerSchema || schema == softCPULedgerSchema || schema == legacyBuildMemoryLedgerSchema || schema == buildMemoryLedgerSchema || sharedMemorySchema(schema)
}

// SuspendPending parks only an exact pre-start wait after stopped proof under
// the owner's lifecycle lease. Demand, age and ownership remain durable. Grants
// cannot be suspended, and timeouts alone never constitute stopped proof.
func (b *Broker) SuspendPending(policy *Policy, expected *Pending, attest func() error) error {
	if expected == nil || !expected.Owner.valid() || expected.QueuedAt.IsZero() || attest == nil {
		return errors.New("suspending a wait requires exact ownership and stopped proof")
	}
	return b.update(policy, false, func(snapshot *Snapshot) error {
		if _, granted := snapshot.Grants[expected.ID]; granted {
			return errors.New("shared capacity granted workload cannot be suspended")
		}
		current, found := snapshot.Pending[expected.ID]
		if !found || current.Request != expected.Request || !current.QueuedAt.Equal(expected.QueuedAt) || !sameWaitOwner(current.Owner, expected.Owner) || current.Suspended != expected.Suspended || current.Revision != expected.Revision {
			return errors.New("shared capacity pending incarnation changed")
		}
		if err := attest(); err != nil {
			return err
		}
		current.Suspended = true
		current.Revision++
		snapshot.Pending[expected.ID] = current
		return nil
	})
}

// Status returns the same validated snapshot used by admission decisions.
func (b *Broker) Status(policy *Policy) (Snapshot, error) {
	var result Snapshot
	err := b.update(policy, false, func(snapshot *Snapshot) error {
		result = *snapshot
		return nil
	})
	return result, err
}

// ReconcilePolicy applies a reviewed change against the exact previous policy.
// Existing allocations remain charged; a budget reduction, pool removal or cost
// change that would invalidate them is rejected in the same transaction.
func (b *Broker) ReconcilePolicy(previous, revised *Policy) error {
	digest, err := policyDigest(revised)
	if err != nil {
		return err
	}
	err = b.update(previous, false, func(snapshot *Snapshot) error {
		if sharedMemorySchema(snapshot.Schema) && !revised.SharedMemoryHeadroom {
			return errors.New("shared headroom ledger cannot downgrade its protocol")
		}
		snapshot.Policy, snapshot.PolicyDigest = *revised, digest
		if revised.SoftCPU() && snapshot.Schema != buildMemoryLedgerSchema && !sharedMemorySchema(snapshot.Schema) {
			snapshot.Schema = softCPULedgerSchema
		}
		if revised.BuildMemoryOvercommit != nil {
			if snapshot.Schema != buildMemoryLedgerSchema && !sharedMemorySchema(snapshot.Schema) {
				snapshot.Schema = legacyBuildMemoryLedgerSchema
			}
			if err := migrateBuildLoans(snapshot); err != nil {
				return err
			}
			return migrateSharedStarts(snapshot)
		}
		return nil
	})
	if errors.Is(err, ErrPolicyChanged) {
		// Configuration reconciliation can stop after committing this ledger
		// but before committing provider configuration. Only the exact reviewed
		// destination is an idempotent recovery; a third policy still rejects.
		_, err = b.Status(revised)
	}
	return err
}

// CheckPolicyChange previews the same allocation invariants without committing.
// The caller must serialize owner effects until ReconcilePolicy commits.
func (b *Broker) CheckPolicyChange(previous, revised *Policy) error {
	digest, err := policyDigest(revised)
	if err != nil {
		return err
	}
	snapshot, err := b.Status(previous)
	if errors.Is(err, ErrPolicyChanged) {
		snapshot, err = b.Status(revised)
	}
	if err != nil {
		return err
	}
	if sharedMemorySchema(snapshot.Schema) && !revised.SharedMemoryHeadroom {
		return errors.New("shared headroom ledger cannot downgrade its protocol")
	}
	snapshot.Policy, snapshot.PolicyDigest = *revised, digest
	if revised.SoftCPU() && snapshot.Schema != buildMemoryLedgerSchema && !sharedMemorySchema(snapshot.Schema) {
		snapshot.Schema = softCPULedgerSchema
	}
	if revised.BuildMemoryOvercommit != nil {
		if snapshot.Schema != buildMemoryLedgerSchema && !sharedMemorySchema(snapshot.Schema) {
			snapshot.Schema = legacyBuildMemoryLedgerSchema
		}
		if err := migrateBuildLoans(&snapshot); err != nil {
			return err
		}
	}
	if err := migrateSharedStarts(&snapshot); err != nil {
		return err
	}
	return validateSnapshot(&snapshot)
}

func sameWaitOwner(left, right *WaitOwner) bool {
	if left == nil || right == nil {
		return left == right
	}
	return *left == *right
}

func validateOwnedWait(schema string, pending *Pending) error {
	if pending.Owner == nil && !pending.Suspended {
		return nil
	}
	if (schema != ownedWaitLedgerSchema && schema != softCPULedgerSchema && schema != legacyBuildMemoryLedgerSchema && schema != buildMemoryLedgerSchema && !sharedMemorySchema(schema)) || !pending.Owner.valid() || pending.Revision == 0 {
		return errors.New("shared capacity owned wait is invalid")
	}
	return nil
}

// v6 is readable only for an identity-preserving upgrade to resident admission.
func sharedMemorySchema(schema string) bool {
	return schema == sharedMemoryLedgerSchema || schema == legacySharedMemoryLedgerSchema
}
