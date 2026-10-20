package sharedcapacity

import (
	"errors"
	"fmt"
	bolt "go.etcd.io/bbolt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRetirementPreservesLedgerAndFencesStaleClients(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	binding := RetirementBinding{WindowID: strings.Repeat("a", 64), OwnerDigest: strings.Repeat("b", 64)}
	called := 0
	receipt, err := b.Retire(&policy, &snapshot, binding, func(observed *Snapshot) error {
		called++
		observed.PolicyDigest = "mutation must not persist"
		return nil
	})
	if err != nil || called != 1 || receipt.Binding != binding || receipt.SnapshotSHA256 == "" {
		t.Fatalf("retire: %+v %v calls=%d", receipt, err, called)
	}
	reopened := &Broker{Path: b.Path}
	proof, err := reopened.VerifyRetired(binding)
	if err != nil || proof != receipt {
		t.Fatalf("reopen: %+v %v", proof, err)
	}
	if _, err = b.Status(&policy); !errors.Is(err, ErrRetired) {
		t.Fatalf("stale status: %v", err)
	}
	if err = reopened.Initialize(&policy, func() error { return nil }); !errors.Is(err, ErrRetired) {
		t.Fatalf("reinitialize: %v", err)
	}
	if _, err = b.Admit(&policy, Request{ID: "late", Pool: "qa"}); !errors.Is(err, ErrRetired) {
		t.Fatalf("late admission: %v", err)
	}
	if _, err = b.Diagnose(&policy); !errors.Is(err, ErrRetired) {
		t.Fatalf("retired diagnostic predicted admission: %v", err)
	}
	foreign := binding
	foreign.WindowID = strings.Repeat("c", 64)
	if _, err = reopened.VerifyRetired(foreign); err == nil {
		t.Fatal("foreign window accepted")
	}
}

func TestRetirementRequiresCurrentEmptyLedgerAndSuccessfulProof(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	binding := RetirementBinding{WindowID: strings.Repeat("a", 64), OwnerDigest: strings.Repeat("b", 64)}
	before, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	grant := requireGrant(t, b, &policy, "busy", "qa")
	if _, err = b.Retire(&policy, &before, binding, func(*Snapshot) error { return nil }); err == nil {
		t.Fatal("stale snapshot accepted")
	}
	current, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = b.Retire(&policy, &current, binding, func(*Snapshot) error { return nil }); err == nil {
		t.Fatal("live allocation retired")
	}
	releaseGrant(t, b, &policy, &grant)
	current, err = b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	denied := errors.New("owner remains active")
	if _, err = b.Retire(&policy, &current, binding, func(*Snapshot) error { return denied }); !errors.Is(err, denied) {
		t.Fatalf("proof: %v", err)
	}
	if _, err = b.Status(&policy); err != nil {
		t.Fatalf("failed proof changed ledger: %v", err)
	}
	if _, err = b.VerifyRetired(binding); err == nil {
		t.Fatal("failed proof produced authority")
	}
}

func TestRetirementAdmissionRaceHasOneWinner(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	binding := RetirementBinding{WindowID: strings.Repeat("a", 64), OwnerDigest: strings.Repeat("b", 64)}
	start := make(chan struct{})
	retired := make(chan error, 1)
	admitted := make(chan error, 1)
	go func() {
		<-start
		_, e := b.Retire(&policy, &snapshot, binding, func(*Snapshot) error { return nil })
		retired <- e
	}()
	go func() { <-start; _, e := b.Admit(&policy, Request{ID: "racing", Pool: "qa"}); admitted <- e }()
	close(start)
	r, a := <-retired, <-admitted
	if (r == nil) == (a == nil) {
		t.Fatalf("exactly one must succeed: retire=%v admit=%v", r, a)
	}
	if r == nil && !errors.Is(a, ErrRetired) {
		t.Fatalf("admission did not observe retirement: %v", a)
	}
}

func TestRetirementRejectsPendingDemand(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	for i := 0; i < 8; i++ {
		requireGrant(t, b, &policy, fmt.Sprintf("qa-%d", i), "qa")
	}
	_, err := b.Admit(&policy, Request{ID: "waiting", Pool: "qa"})
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Pending) == 0 {
		t.Fatal("fixture has no pending demand")
	}
	// Settle grants through their original owner while keeping the queued demand.
	for _, grant := range snapshot.Grants {
		releaseGrant(t, b, &policy, &grant)
	}
	snapshot, err = b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	binding := RetirementBinding{WindowID: strings.Repeat("a", 64), OwnerDigest: strings.Repeat("b", 64)}
	called := false
	if _, err = b.Retire(&policy, &snapshot, binding, func(*Snapshot) error { called = true; return nil }); err == nil || called {
		t.Fatalf("pending demand retired: %v callback=%v", err, called)
	}
}

func TestRetirementDetectsRetainedSnapshotTampering(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	binding := RetirementBinding{WindowID: strings.Repeat("a", 64), OwnerDigest: strings.Repeat("b", 64)}
	if _, err = b.Retire(&policy, &snapshot, binding, func(*Snapshot) error { return nil }); err != nil {
		t.Fatal(err)
	}
	db, err := bolt.Open(b.Path, 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	err = db.Update(func(tx *bolt.Tx) error { return tx.Bucket([]byte("admission")).Put([]byte("snapshot"), []byte("{}")) })
	closeErr := db.Close()
	if err != nil || closeErr != nil {
		t.Fatal(err, closeErr)
	}
	if _, err = b.VerifyRetired(binding); err == nil {
		t.Fatal("tampered retained snapshot accepted")
	}
	if _, err = b.Status(&policy); !errors.Is(err, ErrRetired) {
		t.Fatalf("tamper reopened admission: %v", err)
	}
}

func TestRetirementRefusesMissingProofInputs(t *testing.T) {
	policy := hostPolicy()
	b := newBroker(t, &policy)
	snapshot, err := b.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	binding := RetirementBinding{WindowID: strings.Repeat("a", 64), OwnerDigest: strings.Repeat("b", 64)}
	cases := []struct {
		name     string
		expected *Snapshot
		binding  RetirementBinding
		proof    func(*Snapshot) error
	}{
		{"missing snapshot", nil, binding, func(*Snapshot) error { return nil }},
		{"missing owner proof", &snapshot, binding, nil},
		{"missing binding", &snapshot, RetirementBinding{}, func(*Snapshot) error { return nil }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, e := b.Retire(&policy, tc.expected, tc.binding, tc.proof); e == nil {
				t.Fatal("missing authority accepted")
			}
		})
	}
	if _, err = b.Status(&policy); err != nil {
		t.Fatalf("rejection changed admission: %v", err)
	}
	absent := &Broker{Path: filepath.Join(t.TempDir(), "absent.db")}
	if _, err = absent.VerifyRetired(binding); err == nil {
		t.Fatal("missing ledger proved retirement")
	}
	if _, err = os.Stat(absent.Path); !os.IsNotExist(err) {
		t.Fatalf("verification created ledger: %v", err)
	}
}
