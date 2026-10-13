package sharedcapacity_test

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	bolt "go.etcd.io/bbolt"
)

// The fixture was serialized by the pre-extraction QA allocator, not by this
// module. Real host ledgers and release capabilities must never be test inputs.
func TestOriginalLedgerPreservesOwnersAndWaitingAge(t *testing.T) {
	data, err := os.ReadFile("testdata/qa-ledger-v5.json")
	if err != nil {
		t.Fatal(err)
	}
	var original sharedcapacity.Snapshot
	if err := json.Unmarshal(data, &original); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "admission.db")
	db, err := bolt.Open(path, 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	err = db.Update(func(tx *bolt.Tx) error {
		bucket, err := tx.CreateBucket([]byte("admission"))
		if err != nil {
			return err
		}
		return bucket.Put([]byte("snapshot"), data)
	})
	if closeErr := db.Close(); err != nil || closeErr != nil {
		t.Fatal(err, closeErr)
	}
	now := time.Date(2026, 10, 13, 13, 0, 0, 0, time.UTC)
	b := &sharedcapacity.Broker{Path: path, Now: func() time.Time { return now }}
	b.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: 65536, ObservedAt: now}, nil
	}
	assertUnchanged := func() {
		t.Helper()
		snapshot, err := b.Status(&original.Policy)
		if err != nil || !reflect.DeepEqual(snapshot, original) {
			t.Fatal("opening the original ledger changed its policy, grants or pending owners", err)
		}
	}
	assertUnchanged()
	grant := original.Grants["loan-builder-0"]
	replay, err := b.Admit(&original.Policy, grant.Request)
	if err != nil || !replay.Admitted || replay.Grant == nil || *replay.Grant != grant {
		t.Fatal("original active grant did not replay exactly", replay, err)
	}
	waiting := original.Pending["waiting-guest"]
	decision, err := b.AdmitOwned(&original.Policy, waiting.Request, waiting.Owner)
	if err != nil || decision.Admitted || decision.Pending == nil || !reflect.DeepEqual(*decision.Pending, waiting) {
		t.Fatal("original waiting owner or age changed", decision, err)
	}
	proofCalled := false
	err = b.Release(&original.Policy, grant.ID, "00000000000000000000000000000000", func(sharedcapacity.Grant) error {
		proofCalled = true
		return nil
	})
	if !errors.Is(err, sharedcapacity.ErrFenceMismatch) || proofCalled {
		t.Fatal("stale fence reached release proof", err, proofCalled)
	}
	stillRunning := errors.New("test workload remains running")
	err = b.Release(&original.Policy, grant.ID, grant.Fence, func(sharedcapacity.Grant) error { return stillRunning })
	if !errors.Is(err, stillRunning) {
		t.Fatal("failed stopped-workload proof was accepted", err)
	}
	assertUnchanged()
	if err := b.Release(&original.Policy, grant.ID, grant.Fence, func(observed sharedcapacity.Grant) error {
		if observed != grant {
			return errors.New("release proof received a different owner")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	delete(original.Grants, grant.ID)
	assertUnchanged()
}
