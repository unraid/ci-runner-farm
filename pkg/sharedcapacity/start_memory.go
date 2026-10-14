// Package sharedcapacity fences resident-memory reservations in the admission ledger.
package sharedcapacity

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"
)

// ErrMemoryHeadroom retains the allocation while an actual start waits for RAM.
var ErrMemoryHeadroom = errors.New("fresh shared memory headroom is unavailable")

// StartReservation charges a not-yet-confirmed start against measured headroom.
// It never expires. Only exact started-owner proof or fenced release ends it.
type StartReservation struct {
	Nonce     string `json:"nonce"`
	Fence     string `json:"fence"`
	MemoryMiB uint64 `json:"memoryMiB"`
	Started   bool   `json:"started,omitempty"`
}

func reservedStart(grant Grant) StartReservation {
	return StartReservation{Nonce: grant.Fence, Fence: grant.Fence, MemoryMiB: grant.Cost.MemoryMiB}
}

func pendingStartMemory(snapshot *Snapshot, exclude string) uint64 {
	var reserved uint64
	for id, start := range snapshot.Starts {
		if id != exclude {
			reserved += start.MemoryMiB
		}
	}
	return reserved
}

// migrateSharedStarts conservatively retains the full cost of every legacy
// grant until its lifecycle owner proves that execution is already running.
func migrateSharedStarts(snapshot *Snapshot) error {
	if !snapshot.Policy.SharedMemoryHeadroom {
		if snapshot.Schema == sharedMemoryLedgerSchema {
			return errors.New("shared headroom ledger cannot downgrade its protocol")
		}
		return nil
	}
	if snapshot.Schema == sharedMemoryLedgerSchema && snapshot.Starts != nil {
		return nil
	}
	snapshot.Schema = sharedMemoryLedgerSchema
	snapshot.Starts = make(map[string]StartReservation, len(snapshot.Grants))
	for id, grant := range snapshot.Grants {
		snapshot.Starts[id] = reservedStart(grant)
	}
	return nil
}

func validateStartReservations(snapshot *Snapshot) error {
	if !snapshot.Policy.SharedMemoryHeadroom {
		if len(snapshot.Starts) != 0 {
			return errors.New("legacy ledger contains shared start reservations")
		}
		return nil
	}
	if snapshot.Schema != sharedMemoryLedgerSchema || snapshot.Starts == nil || len(snapshot.Starts) != len(snapshot.Grants) {
		return errors.New("shared start reservation inventory differs from grants")
	}
	for id, start := range snapshot.Starts {
		grant, exists := snapshot.Grants[id]
		nonce, err := hex.DecodeString(start.Nonce)
		if !exists || start.Fence != grant.Fence || err != nil || len(nonce) != 16 || (start.Started && start.MemoryMiB != 0) || (!start.Started && start.MemoryMiB != grant.Cost.MemoryMiB) {
			return errors.New("shared start reservation identity or charge is invalid")
		}
	}
	return nil
}

// ReserveStart must run immediately before every real workload dispatch while
// holding its lifecycle lease. Even a previously granted retry needs a fresh
// sample. An uncertain earlier start keeps its nonce and its memory charge.
func (b *Broker) ReserveStart(policy *Policy, id, fence string) (StartReservation, error) {
	var result StartReservation
	if !policy.SharedMemoryHeadroom {
		return result, nil
	}
	err := b.update(policy, false, func(snapshot *Snapshot) error {
		grant, ok := snapshot.Grants[id]
		if !ok || grant.Fence != fence {
			return ErrFenceMismatch
		}
		if !b.memoryReadyExcluding(snapshot, grant.Request, id) {
			return ErrMemoryHeadroom
		}
		result = snapshot.Starts[id]
		if result.Started {
			nonce := make([]byte, 16)
			if _, err := rand.Read(nonce); err != nil {
				return err
			}
			result = StartReservation{Nonce: hex.EncodeToString(nonce), Fence: fence, MemoryMiB: grant.Cost.MemoryMiB}
			snapshot.Starts[id] = result
		}
		return nil
	})
	return result, err
}

// ConfirmStarted releases only the exact start's shadow charge. The owner must
// retain its lifecycle and policy leases through running-owner proof and its
// durable receipt/state commit. Unknown outcomes keep the full shadow charge.
func (b *Broker) ConfirmStarted(policy *Policy, id string, expected StartReservation, proveStarted func(Grant) error) error {
	if !policy.SharedMemoryHeadroom {
		return nil
	}
	if proveStarted == nil {
		return errors.New("shared start confirmation requires running-owner proof")
	}
	return b.update(policy, false, func(snapshot *Snapshot) error {
		grant, ok := snapshot.Grants[id]
		start, found := snapshot.Starts[id]
		if !ok || !found || grant.Fence != expected.Fence || start.Fence != expected.Fence || start.Nonce != expected.Nonce {
			return ErrFenceMismatch
		}
		if start.Started {
			return nil
		}
		if err := proveStarted(grant); err != nil {
			return err
		}
		start.Started = true
		start.MemoryMiB = 0
		snapshot.Starts[id] = start
		return nil
	})
}

// sharedAdmissionFunding uses one physical observation for both the head and
// a fitting follower. Unfundable or memory-blocked demand retains its age but
// cannot prevent a fitting workload from using otherwise stranded headroom.
func (b *Broker) sharedAdmissionFunding(snapshot *Snapshot, request Request) (uint64, string) {
	return sharedFundingObserved(snapshot, request, b.now(), b.BuildMemoryStatus(&snapshot.Policy))
}

func sharedFundingObserved(snapshot *Snapshot, request Request, now time.Time, status BuildMemoryDiagnostic) (uint64, string) {
	head := queueHead(snapshot, now)
	if head != request.ID {
		pending, found := snapshot.Pending[head]
		if found && canAdmit(snapshot, pending.Request) && memoryReadyObserved(snapshot, pending.Request, "", status) {
			return 0, reasonPriority
		}
	}
	borrowed, fits := admissionLoan(snapshot, request, false)
	if !fits {
		return 0, diagnosticBudget
	}
	if !memoryReadyObserved(snapshot, request, "", status) {
		return 0, memoryPressure
	}
	return borrowed, ""
}
