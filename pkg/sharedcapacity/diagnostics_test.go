package sharedcapacity

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
	boltErrors "go.etcd.io/bbolt/errors"
	"golang.org/x/sys/unix"
)

const (
	diagnosticFIFO     = "fifo"
	diagnosticOldFirst = "old-a"
)

func diagnosticBroker(t *testing.T, policy *Policy) *Broker {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir()) // macOS's temporary parent is a symlink.
	if err != nil {
		t.Fatal(err)
	}
	b := &Broker{Path: filepath.Join(root, "ledger.bolt"), Now: func() time.Time {
		return time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	}}
	if err = b.Initialize(policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	return b
}

func TestDiagnosticsCountsOnlySelectedOwnersTowardStandardFloor(t *testing.T) {
	policy := selectedBuildPolicy()
	b := diagnosticBroker(t, &policy)
	if !admitSized(t, b, &policy, "large-diagnostic", 16384).Admitted || !admitSized(t, b, &policy, "small-diagnostic", 4096).Admitted {
		t.Fatal("elastic setup did not fit spare budget")
	}
	missing := uint32(2)
	for _, id := range []string{standardFloorOne, standardFloorTwo, ""} {
		report, err := b.Diagnose(&policy)
		if err != nil || len(report.Pools) != 1 {
			t.Fatal("standard floor diagnostic unavailable", err)
		}
		pool := report.Pools[0]
		if pool.Granted != 4-missing || pool.FloorMissing != missing || pool.FloorReserved != (Resources{MemoryMiB: uint64(missing) * 12288, VCPUs: missing * 4}) {
			t.Fatalf("elastic owners hid the standard floor: %+v", pool)
		}
		if id != "" {
			requireGrant(t, b, &policy, id, buildPool)
			missing--
		}
	}
}

func TestDiagnosticsDoesNotWriteOrDiscloseReleaseFence(t *testing.T) {
	policy := hostPolicy()
	b := diagnosticBroker(t, &policy)
	grant := requireGrant(t, b, &policy, "unknown-owner", buildPool)
	stamp := time.Unix(100, 0)
	if err := os.Chtimes(b.Path, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(b.Path)
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		report, diagnoseErr := b.Diagnose(&policy)
		if diagnoseErr != nil || len(report.Grants) != 1 || !report.PolicyMatches || report.Grants[0].Cost != grant.Cost || len(report.Grants[0].FenceSHA256) != 64 {
			t.Fatalf("allocation diagnostic: %+v %v", report, diagnoseErr)
		}
		encoded, marshalErr := json.Marshal(report)
		if marshalErr != nil || bytes.Contains(encoded, []byte(grant.Fence)) || bytes.Contains(encoded, []byte(b.Path)) {
			t.Fatalf("private capability/path disclosed: %v", marshalErr)
		}
	}
	after, err := os.ReadFile(b.Path)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(b.Path)
	if err != nil || !bytes.Equal(before, after) || !info.ModTime().Equal(stamp) {
		t.Fatalf("diagnostics rewrote the ledger: %v", err)
	}
}

func TestDiagnosticsMissingLedgerNeverCreatesDirectories(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	policy := hostPolicy()
	b := &Broker{Path: filepath.Join(root, "absent", "ledger.bolt")}
	if _, err = b.Diagnose(&policy); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing ledger did not fail closed: %v", err)
	}
	if _, err = os.Stat(filepath.Dir(b.Path)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("diagnostics created its parent: %v", err)
	}
}

func TestDiagnosticsRefusesUnsafePaths(t *testing.T) {
	for _, kind := range []string{"file-symlink", "parent-symlink", "public", diagnosticFIFO, "empty", "noncanonical"} {
		t.Run(kind, func(t *testing.T) {
			policy := hostPolicy()
			b := diagnosticBroker(t, &policy)
			makeUnsafeDiagnosticPath(t, b, kind)
			if _, err := b.Diagnose(&policy); err == nil {
				t.Fatal("unsafe diagnostic path accepted")
			}
		})
	}
}

func TestDiagnosticsLockWaitIsBounded(t *testing.T) {
	policy := hostPolicy()
	b := diagnosticBroker(t, &policy)
	db, err := bolt.Open(b.Path, 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	start := time.Now()
	if _, err = b.Diagnose(&policy); !errors.Is(err, boltErrors.ErrTimeout) {
		t.Fatalf("locked ledger: %v", err)
	}
	if time.Since(start) > 3*time.Second {
		t.Fatal("diagnostic lock wait exceeded its bound")
	}
}

func TestDiagnosticsPolicyMismatchKeepsFactsButNoPrediction(t *testing.T) {
	policy := hostPolicy()
	b := diagnosticBroker(t, &policy)
	requireGrant(t, b, &policy, "unknown-owner", buildPool)
	if err := b.update(&policy, false, func(snapshot *Snapshot) error {
		snapshot.Pending[pendingQAID] = Pending{Request: Request{ID: pendingQAID, Pool: "qa"}, QueuedAt: b.now().Add(-time.Minute)}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	active := hostPolicy()
	active.Budget.MemoryMiB++
	report, err := b.Diagnose(&active)
	if err != nil || report.PolicyMatches || report.QueueHead != "" || report.ActivePolicyDigest == report.LedgerPolicyDigest || len(report.Grants) != 1 || len(report.Pending) != 1 || report.Pending[0].Reason != "policy_changed" {
		t.Fatalf("mismatch masked or predicted admission: %+v %v", report, err)
	}
	if _, err = b.Status(&policy); err != nil {
		t.Fatalf("diagnostics reconciled policy: %v", err)
	}
}

func TestDiagnosticsRefusesInvalidOrOversizedSnapshot(t *testing.T) {
	for _, data := range []string{"{}", "not-json", strings.Repeat(" ", diagnosticMaxBytes+1)} {
		policy := hostPolicy()
		b := diagnosticBroker(t, &policy)
		db, err := bolt.Open(b.Path, 0o600, nil)
		if err != nil {
			t.Fatal(err)
		}
		err = db.Update(func(tx *bolt.Tx) error { return tx.Bucket([]byte("admission")).Put([]byte("snapshot"), []byte(data)) })
		if err != nil {
			t.Fatal(err)
		}
		if err = db.Close(); err != nil {
			t.Fatal(err)
		}
		if _, err = b.Diagnose(&policy); err == nil {
			t.Fatal("invalid snapshot accepted")
		}
	}
}

func TestDiagnosticsMatchesActualAdmission(t *testing.T) {
	for _, scenario := range []diagnosticScenario{
		{"ready", 12, 1, 0, "qa", diagnosticWouldAdmit, ""},
		{diagnosticBudget, 12, 2, 1, "qa", diagnosticBudget, "host_budget"},
		{"floor", 8, 0, 1, "qa", diagnosticBudget, "floor_reserve"},
		{"maximum", 12, 1, 2, "qa", reasonPriority, "pool_maximum"},
		{"priority", 12, 1, 0, buildPool, reasonPriority, ""},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			policy, b, request, queuedAt := admissionDiagnosticFixture(t, &scenario)
			report, err := b.Diagnose(&policy)
			if err != nil {
				t.Fatal(err)
			}
			var observed PendingDiagnostic
			for _, pending := range report.Pending {
				if pending.ID == request.ID {
					observed = pending
				}
			}
			if observed.Reason != scenario.reason || observed.Constraint != scenario.constraint || observed.AgeSeconds != 30 || !observed.QueuedAt.Equal(queuedAt) {
				t.Fatalf("wrong denial or age: %+v", observed)
			}
			decision, err := b.Admit(&policy, request)
			if err != nil || decision.Admitted != (scenario.reason == diagnosticWouldAdmit) || (!decision.Admitted && decision.Reason != observed.Reason) {
				t.Fatalf("diagnostic disagrees with real admission: %+v %+v %v", observed, decision, err)
			}
		})
	}
}

func TestDiagnosticsRetainsQueueAgeAndUsesSchedulerOrder(t *testing.T) {
	policy := hostPolicy()
	b := diagnosticBroker(t, &policy)
	for i := range 4 {
		requireGrant(t, b, &policy, fmt.Sprintf("build-%d", i), buildPool)
	}
	old := b.now().Add(-10 * time.Minute)
	if err := b.update(&policy, false, func(snapshot *Snapshot) error {
		for _, id := range []string{"old-b", diagnosticOldFirst} {
			snapshot.Pending[id] = Pending{Request: Request{ID: id, Pool: buildPool}, QueuedAt: old}
		}
		snapshot.Pending["fresh-qa"] = Pending{Request: Request{ID: "fresh-qa", Pool: "qa"}, QueuedAt: b.now()}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		report, err := b.Diagnose(&policy)
		if err != nil || len(report.Pending) != 3 || report.QueueHead != diagnosticOldFirst || report.Pending[0].ID != diagnosticOldFirst || report.Pending[1].ID != "old-b" || report.Pending[2].ID != "fresh-qa" || report.Pending[0].AgeSeconds != 600 || report.Pending[0].EffectivePriority != 11 {
			t.Fatalf("age/tie ordering changed: %+v %v", report, err)
		}
	}
}

func TestDiagnosticsDoesNotTruncateOversizedQueue(t *testing.T) {
	policy := hostPolicy()
	b := diagnosticBroker(t, &policy)
	if err := b.update(&policy, false, func(snapshot *Snapshot) error {
		for i := range diagnosticMaxItems + 1 {
			id := fmt.Sprintf("waiting-%d", i)
			snapshot.Pending[id] = Pending{Request: Request{ID: id, Pool: "qa"}, QueuedAt: b.now()}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if report, err := b.Diagnose(&policy); !errors.Is(err, ErrDiagnosticUnsafe) || len(report.Pending) != 0 {
		t.Fatalf("oversized accounting was partially exposed: %+v %v", report, err)
	}
}

func makeUnsafeDiagnosticPath(t *testing.T, b *Broker, kind string) {
	t.Helper()
	switch kind {
	case "file-symlink":
		link := b.Path + ".link"
		if err := os.Symlink(b.Path, link); err != nil {
			t.Fatal(err)
		}
		b.Path = link
	case "parent-symlink":
		link := filepath.Dir(b.Path) + "-link"
		if err := os.Symlink(filepath.Dir(b.Path), link); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Remove(link) })
		b.Path = filepath.Join(link, filepath.Base(b.Path))
	case "public":
		// Deliberately unsafe permission verifies the private-file admission guard.
		//nolint:gosec // This negative fixture must be group/world readable.
		if err := os.Chmod(b.Path, 0o644); err != nil {
			t.Fatal(err)
		}
	case diagnosticFIFO, "empty":
		if err := os.Remove(b.Path); err != nil {
			t.Fatal(err)
		}
		if kind == diagnosticFIFO {
			if err := unix.Mkfifo(b.Path, 0o600); err != nil {
				t.Fatal(err)
			}
		} else if err := os.WriteFile(b.Path, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	case "noncanonical":
		b.Path = filepath.Dir(b.Path) + "/./ledger.bolt"
	}
}

type diagnosticScenario struct {
	name       string
	budget     uint64
	builds     int
	guests     int
	pool       string
	reason     string
	constraint string
}

func admissionDiagnosticFixture(t *testing.T, scenario *diagnosticScenario) (Policy, *Broker, Request, time.Time) {
	t.Helper()
	policy := Policy{Budget: Resources{MemoryMiB: scenario.budget, VCPUs: 12}, AgingSeconds: 60, Pools: map[string]Pool{
		buildPool: {Cost: Resources{MemoryMiB: 4, VCPUs: 1}, Minimum: 1, Maximum: 2, Priority: 1},
		"qa":      {Cost: Resources{MemoryMiB: 4, VCPUs: 1}, Maximum: 2, Priority: 3},
	}}
	b := diagnosticBroker(t, &policy)
	for i := range scenario.builds {
		requireGrant(t, b, &policy, string(rune('a'+i)), buildPool)
	}
	for i := range scenario.guests {
		requireGrant(t, b, &policy, string(rune('x'+i)), "qa")
	}
	request := Request{ID: "waiting", Pool: scenario.pool}
	queuedAt := b.now().Add(-30 * time.Second)
	if err := b.update(&policy, false, func(snapshot *Snapshot) error {
		snapshot.Pending[request.ID] = Pending{Request: request, QueuedAt: queuedAt}
		if scenario.name == "priority" {
			snapshot.Pending["ahead"] = Pending{Request: Request{ID: "ahead", Pool: "qa"}, QueuedAt: queuedAt}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return policy, b, request, queuedAt
}
