// Package sharedcapacity preserves exact workload ownership during explicit ledger adoption.
package sharedcapacity

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
)

// Adopt charges all existing workloads before enabling shared admission. The
// caller must close every owner's start path and hold their lifecycle locks
// through attestation and this transaction. Attestation must prove the exact
// complete inventory, ownership and hard resource limits; busy is allowed.
// Existing allocations are never reset or silently replaced.
func (b *Broker) Adopt(policy *Policy, workloads []Request, attest func() error) error {
	if attest == nil {
		return errors.New("shared adoption requires complete owner attestation")
	}
	return b.AdoptWithSnapshot(policy, workloads, func(*Snapshot) error { return attest() })
}

// AdoptWithSnapshot supplies the current transaction snapshot to attestation.
// Treat it as read-only; reopening this broker from the callback would deadlock
// on the ledger lock already held by adoption.
func (b *Broker) AdoptWithSnapshot(policy *Policy, workloads []Request, attest func(*Snapshot) error) error {
	if attest == nil {
		return errors.New("shared adoption requires complete owner attestation")
	}
	return b.update(policy, true, func(snapshot *Snapshot) error {
		if err := validateAdoption(snapshot, workloads); err != nil {
			return err
		}
		if err := attest(snapshot); err != nil {
			return err
		}
		if len(snapshot.Grants) != 0 || len(snapshot.Pending) != 0 {
			return nil
		}
		for _, workload := range workloads {
			borrowed, fits := admissionLoan(snapshot, workload, false)
			if !fits {
				return errors.New("existing owned workloads exceed shared budget or guarantees")
			}
			fence := make([]byte, 16)
			if _, err := rand.Read(fence); err != nil {
				return err
			}
			cost, err := RequestCost(policy, workload)
			if err != nil {
				return err
			}
			snapshot.Grants[workload.ID] = Grant{Request: workload, Cost: cost, BorrowedMemoryMiB: borrowed, Fence: hex.EncodeToString(fence), GrantedAt: b.now()}
			if snapshot.Policy.SharedMemoryHeadroom {
				snapshot.Starts[workload.ID] = reservedStart(snapshot.Grants[workload.ID])
			}
		}
		return nil
	})
}

func validateAdoption(snapshot *Snapshot, workloads []Request) error {
	seen := map[string]bool{}
	for _, workload := range workloads {
		if workload.ID == "" || seen[workload.ID] {
			return errors.New("shared adoption contains invalid or duplicate owner identities")
		}
		seen[workload.ID] = true
		if _, exists := snapshot.Policy.Pools[workload.Pool]; !exists {
			return errors.New("shared adoption contains an unknown pool")
		}
		if len(snapshot.Grants) != 0 || len(snapshot.Pending) != 0 {
			grant, exists := snapshot.Grants[workload.ID]
			pending, queued := snapshot.Pending[workload.ID]
			if (!exists || grant.Request != workload) && (!queued || pending.Request != workload) {
				return errors.New("shared adoption differs from existing allocations")
			}
		}
	}
	for id := range snapshot.Grants {
		if !seen[id] {
			return errors.New("shared adoption omits existing allocations")
		}
	}
	return nil
}
