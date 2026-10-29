// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

const testRegistrationOrganization = "unraid"

func TestRegistrationAcceptsGitHubBOMAndRetainsExactIdentityChecks(t *testing.T) {
	expectedName := "original-host-" + testName
	for _, test := range []struct {
		name, organization, runnerName string
		bom, valid                     bool
	}{
		{name: "plain", organization: testRegistrationOrganization, runnerName: expectedName, valid: true},
		{name: "github BOM", organization: testRegistrationOrganization, runnerName: expectedName, bom: true, valid: true},
		{name: "foreign organization", organization: "foreign", runnerName: expectedName, bom: true},
		{name: "foreign owner", organization: testRegistrationOrganization, runnerName: "other-slot", bom: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := installExitedRegistrationFixture(t, strings.Repeat("a", 64), testRunningStatus, true, 123, expectedName, testRegistrationOrganization, expectedName)
			identity, encodeErr := json.Marshal(map[string]any{"agentId": 123, "agentName": test.runnerName, "gitHubUrl": "https://github.com/" + test.organization})
			if encodeErr != nil {
				t.Fatal(encodeErr)
			}
			if test.bom {
				identity = append([]byte{0xef, 0xbb, 0xbf}, identity...)
			}
			fixture := filepath.Join(directory, "identity.json")
			if writeErr := os.WriteFile(fixture, identity, 0o600); writeErr != nil {
				t.Fatal(writeErr)
			}
			mock := "#!/bin/sh\ncase \"$1\" in ps) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "listing")) + ";; inspect) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "inspect")) + ";; exec) exec /bin/cat " + strconv.Quote(fixture) + ";; *) exit 1;; esac\n"
			if writeErr := os.WriteFile(filepath.Join(directory, "docker"), []byte(mock), 0o600); writeErr != nil {
				t.Fatal(writeErr)
			}
			// The private fixture must be executable to exercise native command decoding.
			// #nosec G302 -- owner-only executable test fixture in t.TempDir.
			if chmodErr := os.Chmod(filepath.Join(directory, "docker"), 0o700); chmodErr != nil {
				t.Fatal(chmodErr)
			}
			t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
			id, name, readErr := Registration(context.Background(), strings.Repeat("a", 64), testRegistrationOrganization, testName)
			if test.valid {
				if readErr != nil || id != 123 || name != expectedName {
					t.Fatalf("registration = %d, %q, %v", id, name, readErr)
				}
			} else if readErr == nil {
				t.Fatal("foreign native identity was accepted")
			}
		})
	}
}

func TestLiveLegacyRegistrationUsesImmutableNameAfterHostRename(t *testing.T) {
	id := strings.Repeat("a", 64)
	name := "ci-runner-1"
	expected := "original-host-" + name
	directory := installExitedRegistrationFixture(t, id, testRunningStatus, true, 123, expected, testRegistrationOrganization, expected)
	raw, err := os.ReadFile(filepath.Join(directory, "inspect"))
	if err != nil {
		t.Fatal(err)
	}
	var inspected []map[string]any
	if err = json.Unmarshal(raw, &inspected); err != nil {
		t.Fatal(err)
	}
	inspected[0]["Name"] = "/" + name
	config := inspected[0]["Config"].(map[string]any)
	config["Labels"].(map[string]any)["net.unraid.ci-runner-farm.pool"] = "default"
	raw, err = json.Marshal(inspected)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(directory, "inspect"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(directory, "listing"), []byte(id+"|"+name+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, remote := range []string{expected, "foreign-" + name} {
		raw, err = json.Marshal(map[string]any{"agentId": 123, "agentName": remote, "gitHubUrl": "https://github.com/" + testRegistrationOrganization})
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(directory, "identity.json"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
		mock := "#!/bin/sh\ncase \"$1\" in ps) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "listing")) + ";; inspect) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "inspect")) + ";; exec) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "identity.json")) + ";; *) exit 1;; esac\n"
		if err = os.WriteFile(filepath.Join(directory, "docker"), []byte(mock), 0o600); err != nil {
			t.Fatal(err)
		}
		// #nosec G302 -- owner-only executable fixture in t.TempDir.
		if err = os.Chmod(filepath.Join(directory, "docker"), 0o700); err != nil {
			t.Fatal(err)
		}
		runnerID, runnerName, readErr := LegacyRegistration(context.Background(), id, testRegistrationOrganization, name)
		if remote == expected {
			if readErr != nil || runnerID != 123 || runnerName != expected {
				t.Fatal("legacy immutable identity rejected", readErr)
			}
		} else if readErr == nil {
			t.Fatal("foreign legacy registration accepted")
		}
	}
}

// Projection fixtures model protected host observations, never a live host.
type projectionDocker struct {
	*fakeDocker
	current    *LocalWorkerIdentity
	observeErr error
}

func (d *projectionDocker) ObserveLocalOwner(_ context.Context, _ string) (*LocalWorkerIdentity, error) {
	if d.observeErr != nil {
		return nil, d.observeErr
	}
	sample := *d.current
	sample.Namespaces = map[string]string{}
	for key, value := range d.current.Namespaces {
		sample.Namespaces[key] = value
	}
	return &sample, nil
}

func projectionPendingFixture(t *testing.T) (*Controller, *projectionDocker, string) {
	t.Helper()
	c, d, id := fixture(t)
	c.Host, c.Epoch = "approved-host", strings.Repeat("e", 32)
	c.Broker.Path, _ = filepath.EvalSymlinks(c.Broker.Path)
	c.ReceiptRoot, _ = filepath.EvalSymlinks(filepath.Dir(c.ReceiptRoot))
	c.ReceiptRoot = filepath.Join(c.ReceiptRoot, "receipts")
	d.containers[id].NeverStarted = true
	d.containers[id].RegistrationIssuedAt = c.now().Unix()
	d.containers[id].RoutingGated = true
	d.containers[id].RegistrationName = ownerNameForRoutingTest
	d.containers[id].Confgen = "123456abcdef"
	d.containers[id].InitPID = 44
	current := &LocalWorkerIdentity{ContainerID: id, Name: testName, Confgen: "123456abcdef", BootID: "11111111-1111-4111-8111-111111111111", InitPID: 44, InitBirth: "123", Namespaces: map[string]string{"pid": "pid:[11]", "mnt": "mnt:[12]", "user": "user:[13]", "cgroup": "cgroup:[14]", "net": "net:[15]"}}
	pd := &projectionDocker{fakeDocker: d, current: current}
	c.Docker = pd
	if err := c.Start(t.Context(), testName, id); err != nil {
		t.Fatal(err)
	}
	d.containers[id].NeverStarted = false
	d.containers[id].RoutingGated = true
	return c, pd, id
}

func projectionFixture(t *testing.T) (*Controller, *projectionDocker, string) {
	t.Helper()
	c, d, id := projectionPendingFixture(t)
	if err := c.RecordRegistration(testName, id, 123, ownerNameForRoutingTest); err != nil {
		t.Fatal(err)
	}
	return c, d, id
}

func TestOriginalProjectionCompleteAndImmutableWithoutStatusWrites(t *testing.T) {
	c, _, id := projectionFixture(t)
	path := filepath.Join(c.ReceiptRoot, testName+".json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	ledgerBefore, err := os.ReadFile(c.Broker.Path)
	if err != nil {
		t.Fatal(err)
	}
	diag, err := c.Broker.Diagnose(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := c.ObserveOwners(t.Context(), diag)
	if err != nil || len(rows) != 1 || rows[0].State != "complete" || rows[0].RunnerID != 123 || rows[0].Original.ContainerID != id {
		t.Fatal(rows, err)
	}
	if err = c.RecordRegistration(testName, id, 123, ownerNameForRoutingTest); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	ledgerAfter, _ := os.ReadFile(c.Broker.Path)
	if string(before) != string(after) || string(ledgerBefore) != string(ledgerAfter) {
		t.Fatal("readonly observation or unchanged retry wrote durable state")
	}
	raw, _ := json.Marshal(rows)
	owned, _ := c.load(testName)
	if strings.Contains(string(raw), owned.Fence) {
		t.Fatal("raw release fence exposed")
	}
}

func TestOriginalProjectionRefusesRestartRebootNamespaceAndTamperedJoin(t *testing.T) {
	for _, kind := range []string{"pid reuse", "reboot", "namespace", "config", "fence", "epoch", "registration", "grant cost", "missing namespace"} {
		t.Run(kind, func(t *testing.T) {
			c, d, _ := projectionFixture(t)
			diag, err := c.Broker.Diagnose(&c.Policy)
			if err != nil {
				t.Fatal(err)
			}
			owned, _ := c.load(testName)
			switch kind {
			case "pid reuse":
				d.current.InitBirth = "124"
			case "reboot":
				d.current.BootID = "22222222-2222-4222-8222-222222222222"
			case "namespace":
				d.current.Namespaces["pid"] = "pid:[99]"
			case "config":
				d.current.Confgen = "abcdef123456"
			case "fence":
				owned.Fence = "changed"
				if err := c.save(testName, owned); err != nil {
					t.Fatal(err)
				}
			case "epoch":
				c.Epoch = strings.Repeat("f", 32)
			case "registration":
				owned.Withdrawal.RunnerID = 124
				if err := c.save(testName, owned); err != nil {
					t.Fatal(err)
				}
			case "grant cost":
				diag.Grants[0].Cost.MemoryMiB++
			case "missing namespace":
				delete(d.current.Namespaces, "net")
			}
			rows, err := c.ObserveOwners(t.Context(), diag)
			if err == nil && len(rows) == 1 && rows[0].State == "complete" {
				t.Fatal("changed identity became complete", kind)
			}
		})
	}
}

func TestProjectionNeverBackfillsLegacyRegistrationAndRejectsTamperedReceipt(t *testing.T) {
	c, d, id := fixture(t)
	if err := c.Start(t.Context(), testName, id); err != nil {
		t.Fatal(err)
	}
	if err := c.RecordRegistration(testName, id, 123, ownerNameForRoutingTest); err != nil {
		t.Fatal(err)
	}
	c.Host, c.Epoch = "approved-host", strings.Repeat("e", 32)
	if err := c.RecordRegistration(testName, id, 123, ownerNameForRoutingTest); err != nil {
		t.Fatal(err)
	}
	owned, _ := c.load(testName)
	if owned.OriginalRegistration != nil {
		t.Fatal("legacy history was fabricated")
	}
	d.containers[id].RoutingGated = true
	d.containers[id].RoutingLabels = []string{HostSelectorLabel(c.Host)}
	if err := c.requireHostRouting(t.Context(), owned, d.containers[id]); err == nil {
		t.Fatal("legacy missing origin accepted targeted routing")
	}

	c, _, _ = projectionFixture(t)
	path := filepath.Join(c.ReceiptRoot, testName+".json")
	raw, _ := os.ReadFile(path)
	var value map[string]any
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	value["originalRegistration"].(map[string]any)["unrecognized"] = true
	raw, _ = json.Marshal(value)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	diag, _ := c.Broker.Diagnose(&c.Policy)
	rows, err := c.ObserveOwners(t.Context(), diag)
	if err == nil && rows[0].State == "complete" {
		t.Fatal("unknown original field accepted")
	}
}

func TestProjectionBoundsDuplicateRunnerIDsAndUnsafeReceiptEntries(t *testing.T) {
	c, _, _ := projectionFixture(t)
	diag, _ := c.Broker.Diagnose(&c.Policy)
	path := filepath.Join(c.ReceiptRoot, testName+".json")
	raw, _ := os.ReadFile(path)
	other := filepath.Join(c.ReceiptRoot, "ci-runner-build-2.json")
	if err := os.WriteFile(other, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	rows, err := c.ObserveOwners(t.Context(), diag)
	if err != nil || len(rows) != 2 {
		t.Fatal(rows, err)
	}
	for _, row := range rows {
		if row.State == "complete" || row.Reason != "ambiguous_runner_id" {
			t.Fatal("duplicate registration accepted", rows)
		}
	}
	if err := os.Remove(other); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, other); err != nil {
		t.Fatal(err)
	}
	rows, err = c.ObserveOwners(t.Context(), diag)
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.Slot == "ci-runner-build-2" && row.State == "complete" {
			t.Fatal("symlink receipt accepted")
		}
	}
	if err := os.Remove(other); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(other, []byte(strings.Repeat("x", 4097)), 0o600); err != nil {
		t.Fatal(err)
	}
	rows, err = c.ObserveOwners(t.Context(), diag)
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.Slot == "ci-runner-build-2" && row.State == "complete" {
			t.Fatal("oversized receipt accepted")
		}
	}
}

func TestUnknownInitialObservationIsNotBackfilledOnRegistrationRetry(t *testing.T) {
	c, d, id := projectionPendingFixture(t)
	d.observeErr = errors.New("injected observation refused")
	if err := c.RecordRegistration(testName, id, 123, ownerNameForRoutingTest); err != nil {
		t.Fatal("untargeted registration behavior changed", err)
	}
	d.observeErr = nil
	if err := c.RecordRegistration(testName, id, 123, ownerNameForRoutingTest); err != nil {
		t.Fatal(err)
	}
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	if owned.OriginalRegistration == nil || owned.OriginalRegistration.Runtime != nil {
		t.Fatal("unknown original was backfilled")
	}
	diag, err := c.Broker.Diagnose(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := c.ObserveOwners(t.Context(), diag)
	if err != nil || rows[0].State != "unknown" {
		t.Fatal(rows, err)
	}
}

func TestOwnerStatusFIFOAndBrokenSymlinkAreBoundedUnknown(t *testing.T) {
	c, _, _ := projectionFixture(t)
	diag, err := c.Broker.Diagnose(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(c.ReceiptRoot, "ci-runner-build-2.json")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	rows, err := c.ObserveOwners(t.Context(), diag)
	if err != nil || len(rows) != 2 || rows[1].State != "unknown" {
		t.Fatal(rows, err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(c.ReceiptRoot, "missing"), path); err != nil {
		t.Fatal(err)
	}
	rows, err = c.ObserveOwners(t.Context(), diag)
	if err != nil || rows[1].State != "unknown" {
		t.Fatal(rows, err)
	}
}

func TestOptionalOriginalSamplingHonorsExistingRequestCancellation(t *testing.T) {
	c, _, id := projectionPendingFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	c.OwnerContext = ctx
	if err := c.RecordRegistration(testName, id, 123, ownerNameForRoutingTest); err != nil {
		t.Fatal("ordinary registration gained an optional sampling requirement", err)
	}
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	if owned.OriginalRegistration.Runtime != nil {
		t.Fatal("canceled source observation became original proof")
	}
}

func TestQueuedReplacementRepreparesOnlyUnstartedOriginAcrossReceiptCrashWindow(t *testing.T) {
	c, _, _, now := pressureFixture(t)
	c.Host, c.Epoch = "approved-host", strings.Repeat("e", 32)
	d := c.Docker.(*fakeDocker)
	oldID, newID := strings.Repeat("e", 64), strings.Repeat("f", 64)
	name := queuedBuilderSix
	item := &Container{ID: oldID, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix(), Confgen: "123456abcdef"}
	d.containers[oldID] = item
	if err := c.Start(t.Context(), name, oldID); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.PrepareQueuedReplacement(t.Context(), name, oldID); err != nil {
		t.Fatal(err)
	}
	replacement := *item
	replacement.ID = newID
	d.containers[newID] = &replacement
	owned, err := c.load(name)
	if err != nil {
		t.Fatal(err)
	}
	// The pre-existing replacement primitive durably changes the container ID.
	// Reproduce a crash immediately after that save, before the next Start.
	if err := c.finishQueuedReplacement(t.Context(), name, &replacement, owned, &before); err != nil {
		t.Fatal(err)
	}
	if err := c.Start(t.Context(), name, newID); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	owned, err = c.load(name)
	if err != nil {
		t.Fatal(err)
	}
	if owned.OriginalRegistration == nil || owned.OriginalRegistration.ContainerID != newID || owned.OriginalRegistration.Runtime != nil || owned.OriginalRegistration.IncarnationSHA256 != "" {
		t.Fatal("unstarted replacement kept a foreign or fabricated original", owned)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if !before.Pending["build:"+name].QueuedAt.Equal(after.Pending["build:"+name].QueuedAt) || len(after.Grants) != len(before.Grants) {
		t.Fatal("metadata preparation changed queue age or grants")
	}
}

func TestOwnerObservationErrorIsUnknownNotAnAssertedIdentityChange(t *testing.T) {
	c, d, _ := projectionFixture(t)
	d.observeErr = errors.New("injected transport error")
	diag, err := c.Broker.Diagnose(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := c.ObserveOwners(t.Context(), diag)
	if err != nil || len(rows) != 1 || rows[0].State != "unknown" || rows[0].Reason != "observation_unavailable" {
		t.Fatal(rows, err)
	}
}
