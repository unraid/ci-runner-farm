package farmcapacity

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

type currentProjectionDocker struct {
	*projectionDocker
	sample  *CurrentMetadata
	calls   int
	onRead  func()
	failure error
}

func (d *currentProjectionDocker) observeCurrentMetadata(ctx context.Context, id string, runnerID int64, name, organization string) (*CurrentMetadata, error) {
	d.calls++
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if id != d.sample.Runtime.ContainerID || runnerID != 123 || name != ownerNameForRoutingTest || organization != testRegistrationOrganization {
		return nil, errors.New("selected read changed")
	}
	if d.onRead != nil {
		d.onRead()
	}
	if d.failure != nil {
		return nil, d.failure
	}
	return d.sample, nil
}
func currentProjectionFixture(t *testing.T) (*Controller, *currentProjectionDocker, string) {
	t.Helper()
	c, d, id := projectionFixture(t)
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	owned.OriginalRegistration = nil
	if err = c.save(testName, owned); err != nil {
		t.Fatal(err)
	}
	d.plainForbidden = true
	item := *d.containers[id]
	sample := &CurrentMetadata{
		Runtime: d.current, RunnerID: 123, RunnerName: ownerNameForRoutingTest, RootDevice: 1, RootInode: 2,
		Image:      CurrentImage{ID: "sha256:" + strings.Repeat("b", 64), Reference: "ci-runner-farm-runner:latest", Entrypoint: "/entrypoint.sh", RepoDigests: []string{}},
		Limits:     CurrentLimits{MemoryBytes: item.MemoryBytes, MemorySwapBytes: -1, NanoCPUs: item.NanoCPUs},
		MemoryFile: CurrentMemoryFile{State: "not-observed; absence-or-access-unknown"}, container: &item,
	}
	current := &currentProjectionDocker{projectionDocker: d, sample: sample}
	c.Docker = current
	return c, current, id
}
func currentDiagnostics(t *testing.T, c *Controller) sharedcapacity.Diagnostics {
	t.Helper()
	d, err := c.Broker.Diagnose(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	return d
}
func TestCurrentOwnerLegacyReadDoesNotBackfillOrWrite(t *testing.T) {
	c, d, _ := currentProjectionFixture(t)
	// The native private directory can reside below a shared writable ancestor.
	if err := os.Chmod(filepath.Dir(c.ReceiptRoot), 0o777); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(c.ReceiptRoot, testName+".json")
	before, _ := os.ReadFile(path)
	ledger, _ := os.ReadFile(c.Broker.Path)
	starts := d.starts
	diagnostics := currentDiagnostics(t, c)
	old, err := c.ObserveOwners(t.Context(), diagnostics)
	if err != nil {
		t.Fatal(err)
	}
	result, err := c.ObserveCurrentOwner(t.Context(), diagnostics, 123)
	if err != nil {
		t.Fatal(err)
	}
	if result.Schema != "ci-runner-farm-current-owner/v1" || result.OriginalProvenance != "unavailable" || result.Metadata.RunnerID != 123 || len(result.BindingSHA256) != 64 {
		t.Fatal("current-only result differs", result)
	}
	after, _ := os.ReadFile(path)
	ledgerAfter, _ := os.ReadFile(c.Broker.Path)
	now, err := c.ObserveOwners(t.Context(), currentDiagnostics(t, c))
	if err != nil || !reflect.DeepEqual(old, now) || len(now) != 1 || now[0].Reason != "original_unavailable" || now[0].Current != nil ||
		string(before) != string(after) || string(ledger) != string(ledgerAfter) || d.starts != starts || d.calls != 1 {
		t.Fatal("current observation changed old status or durable state", err)
	}
	raw, _ := json.Marshal(result)
	owned, _ := c.load(testName)
	if strings.Contains(string(raw), owned.Fence) || strings.Contains(string(raw), "originalRegistration") || result.Metadata.MemoryFile.ContentRead {
		t.Fatal("private capability or invented original leaked", string(raw))
	}
}
func TestCurrentOwnerRefusesUnboundOrPendingOwners(t *testing.T) {
	for _, kind := range []string{"duplicate", "wrong fence", "wrong CID", "phase", "retiring", "release pending", "maintenance", "replacement", "unregistered", "missing registration", "bad name", "wrong cost", "wrong policy", "stale", "future", "pending", "wrong runtime", "wrong image", "image secret", "memory content", "busy"} {
		t.Run(kind, func(t *testing.T) {
			c, d, _ := currentProjectionFixture(t)
			diag := currentDiagnostics(t, c)
			owned, _ := c.load(testName)
			switch kind {
			case "duplicate":
				if err := c.save("ci-runner-build-2", owned); err != nil {
					t.Fatal(err)
				}
			case "wrong fence":
				owned.Fence = "different-private-fence"
			case "wrong CID":
				owned.Withdrawal.ContainerID = strings.Repeat("c", 64)
			case "phase":
				owned.Withdrawal.Phase = "remove-intent"
			case "retiring":
				owned.Retiring = true
			case "release pending":
				owned.ReleasePending = true
			case "maintenance":
				owned.Maintenance = true
			case "replacement":
				owned.ReplacementPrepared = true
			case "unregistered":
				owned.Withdrawal.Unregistered = true
			case "missing registration":
				owned.Withdrawal = nil
			case "bad name":
				owned.Withdrawal.RunnerName = "bad\nname"
			case "wrong cost":
				diag.Grants[0].Cost.MemoryMiB++
			case "wrong policy":
				diag.PolicyMatches = false
			case "stale":
				diag.ObservedAt = time.Now().Add(-time.Minute)
			case "future":
				diag.ObservedAt = time.Now().Add(time.Minute)
			case "pending":
				pending := sharedcapacity.PendingDiagnostic{}
				pending.ID = "build:" + testName
				diag.Pending = append(diag.Pending, pending)
			case "wrong runtime":
				d.sample.Runtime.ContainerID = strings.Repeat("d", 64)
			case "wrong image":
				d.sample.Image.ID = "sha256:invalid"
			case "image secret":
				d.sample.Image.Reference = "private.invalid/SECRET:credential"
			case "memory content":
				d.sample.MemoryFile.ContentRead = true
			case "busy":
				d.failure = errors.New("worker present")
			}
			if kind != "duplicate" {
				if err := c.save(testName, owned); err != nil {
					t.Fatal(err)
				}
			}
			before, _ := os.ReadFile(filepath.Join(c.ReceiptRoot, testName+".json"))
			starts := d.starts
			result, err := c.ObserveCurrentOwner(t.Context(), diag, 123)
			if err == nil || result != nil {
				t.Fatal("unbound current owner accepted", result)
			}
			after, _ := os.ReadFile(filepath.Join(c.ReceiptRoot, testName+".json"))
			if string(before) != string(after) || starts != d.starts {
				t.Fatal("refusal wrote ownership or started work")
			}
		})
	}
}
func TestCurrentOwnerRejectsUnsafeReceiptBoundary(t *testing.T) {
	for _, kind := range []string{"directory mode", "directory symlink", "file mode", "file symlink", "file hardlink", "oversized", "malformed", "unknown entry"} {
		t.Run(kind, func(t *testing.T) {
			c, d, _ := currentProjectionFixture(t)
			diag := currentDiagnostics(t, c)
			path := filepath.Join(c.ReceiptRoot, testName+".json")
			switch kind {
			case "directory mode":
				if err := os.Chmod(c.ReceiptRoot, 0o755); err != nil {
					t.Fatal(err)
				}
			case "directory symlink":
				real := c.ReceiptRoot + "-real"
				if err := os.Rename(c.ReceiptRoot, real); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(real, c.ReceiptRoot); err != nil {
					t.Fatal(err)
				}
			case "file mode":
				if err := os.Chmod(path, 0o644); err != nil {
					t.Fatal(err)
				}
			case "file symlink":
				real := path + ".other"
				if err := os.Rename(path, real); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(real, path); err != nil {
					t.Fatal(err)
				}
			case "file hardlink":
				if err := os.Link(path, filepath.Join(t.TempDir(), "alias")); err != nil {
					t.Fatal(err)
				}
			case "oversized":
				if err := os.WriteFile(path, []byte(strings.Repeat("x", 4097)), 0o600); err != nil {
					t.Fatal(err)
				}
			case "malformed":
				if err := os.WriteFile(path, []byte("{} {}"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "unknown entry":
				if err := os.WriteFile(filepath.Join(c.ReceiptRoot, "unexpected"), []byte("x"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := c.ObserveCurrentOwner(t.Context(), diag, 123); err == nil || d.calls != 0 {
				t.Fatal("unsafe receipt reached Docker", err)
			}
		})
	}
}
func TestCurrentOwnerDetectsInterveningReceiptGrantAndCancellation(t *testing.T) {
	for _, kind := range []string{"receipt", "grant", "cancel"} {
		t.Run(kind, func(t *testing.T) {
			c, d, _ := currentProjectionFixture(t)
			diag := currentDiagnostics(t, c)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			d.onRead = func() {
				switch kind {
				case "receipt":
					owned, _ := c.load(testName)
					owned.Maintenance = true
					if err := c.save(testName, owned); err != nil {
						t.Fatal(err)
					}
				case "grant":
					c.Policy.Budget.MemoryMiB++
				case "cancel":
					cancel()
				}
			}
			if result, err := c.ObserveCurrentOwner(ctx, diag, 123); err == nil || result != nil {
				t.Fatal("changed observation accepted")
			}
		})
	}
	c, d, _ := currentProjectionFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := c.ObserveCurrentOwner(ctx, currentDiagnostics(t, c), 123); !errors.Is(err, context.Canceled) || d.calls != 0 {
		t.Fatal("cancellation reached current read", err)
	}
	for _, id := range []int64{0, -1, 124} {
		if _, err := c.ObserveCurrentOwner(t.Context(), currentDiagnostics(t, c), id); err == nil {
			t.Fatal("unbound selector accepted")
		}
	}
}

func TestCurrentOwnerRejectsAmbiguousReceiptJSON(t *testing.T) {
	for _, kind := range []string{"duplicate fence", "duplicate runner", "missing phase", "null phase", "null unregistered", "null lifecycle"} {
		t.Run(kind, func(t *testing.T) {
			c, d, _ := currentProjectionFixture(t)
			path := filepath.Join(c.ReceiptRoot, testName+".json")
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			s := string(raw)
			switch kind {
			case "duplicate fence":
				s = strings.Replace(s, `"fence":`, `"fence":"spoofed","fence":`, 1)
			case "duplicate runner":
				s = strings.Replace(s, `"runnerId":123`, `"runnerId":999,"runnerId":123`, 1)
			case "missing phase":
				s = strings.Replace(s, `,"phase":""`, "", 1)
			case "null phase":
				s = strings.Replace(s, `"phase":""`, `"phase":null`, 1)
			case "null unregistered":
				s = strings.Replace(s, `"phase":""`, `"unregistered":null,"phase":""`, 1)
			case "null lifecycle":
				s = strings.Replace(s, `"containerId":`, `"maintenance":null,"containerId":`, 1)
			}
			if s == string(raw) {
				t.Fatal("fixture mutation did not apply")
			}
			if err := os.WriteFile(path, []byte(s), 0o600); err != nil {
				t.Fatal(err)
			}
			if result, err := c.ObserveCurrentOwner(t.Context(), currentDiagnostics(t, c), 123); err == nil || result != nil || d.calls != 0 {
				t.Fatal("ambiguous private receipt was accepted")
			}
		})
	}
}
