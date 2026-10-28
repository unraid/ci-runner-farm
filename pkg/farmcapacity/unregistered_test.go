// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const (
	startupRunnerName   = "native-" + testName
	startupGated        = "gated"
	startupPresentLater = "present-later"
	startupNetwork      = "network"
	startupTruncated    = "truncated"
	startupUnauthorized = "unauthorized"
)

func TestRegisteredCollisionNameProofUsesCompleteScopeWithoutChangingOwner(t *testing.T) {
	for _, test := range []string{"scope-absent", startupPresentLater, startupTruncated, startupUnauthorized, startupNetwork} {
		t.Run(test, func(t *testing.T) {
			owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
				return startupPage(t, test, request)
			})
			owner.Name, owner.RunnerName = testName, startupRunnerName
			gone, err := owner.RegistrationNameGone(context.Background())
			if test == "scope-absent" {
				if err != nil || !gone {
					t.Fatal("complete name absence rejected", err)
				}
			} else if gone || (test != startupPresentLater && err == nil) {
				t.Fatal("unproved name absence accepted", err)
			}
			if owner.RunnerID != 123 || owner.Unregistered {
				t.Fatal("name proof changed immutable registration")
			}
		})
	}
}

func TestNativeInertRemovalRequiresPositiveNeverStartedState(t *testing.T) {
	for _, mode := range []string{nativeCreatedStatus, "running-observed", collisionPaused, testExitedStatus, "pid", "missing-pid", "native-started", "missing-started", "null-started"} {
		t.Run(mode, func(t *testing.T) {
			id := strings.Repeat("a", 64)
			directory := installExitedRegistrationFixture(t, id, nativeCreatedStatus, false, 0, "", testRegistrationOrganization, startupRunnerName, startupGated)
			state := map[string]any{"Status": nativeCreatedStatus, "Running": false, "Paused": false, "Pid": 0, "StartedAt": "0001-01-01T00:00:00Z"}
			switch mode {
			case "running-observed":
				state["Running"] = true
			case collisionPaused:
				state["Paused"] = true
			case testExitedStatus:
				state["Status"] = testExitedStatus
			case "pid":
				state["Pid"] = 123
			case "missing-pid":
				delete(state, "Pid")
			case "native-started":
				state["StartedAt"] = "2026-01-01T00:00:00Z"
			case "missing-started":
				delete(state, "StartedAt")
			case "null-started":
				state["StartedAt"] = nil
			}
			data, err := json.Marshal([]map[string]any{{"Id": id, "Name": "/" + testName, "State": state}})
			if err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(filepath.Join(directory, "inspect"), data, 0o600); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(directory, "removed")
			script := "#!/bin/sh\ncase \"$1\" in ps) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "listing")) + ";; inspect) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "inspect")) + ";; rm) test \"$#\" = 2 && test \"$2\" = " + strconv.Quote(id) + " || exit 1; : > " + strconv.Quote(marker) + ";; *) exit 1;; esac\n"
			if err = os.WriteFile(filepath.Join(directory, "docker"), []byte(script), 0o600); err != nil {
				t.Fatal(err)
			}
			// #nosec G302 -- owner-only executable test fixture in t.TempDir.
			if err = os.Chmod(filepath.Join(directory, "docker"), 0o700); err != nil {
				t.Fatal(err)
			}
			err = (NativeDocker{}).RemoveCreated(context.Background(), id)
			_, removed := os.Stat(marker)
			if mode == nativeCreatedStatus {
				if err != nil || removed != nil {
					t.Fatal("attested inert removal rejected", err)
				}
			} else if err == nil || !errors.Is(removed, os.ErrNotExist) {
				t.Fatal("unproved native state removed", err)
			}
		})
	}
}

func TestUnregisteredAbsenceRequiresCompleteAuthorizedPagination(t *testing.T) {
	for _, test := range []string{"absent", startupPresentLater, startupTruncated, startupUnauthorized, "malformed", "changed-total", "duplicate", startupNetwork} {
		t.Run(test, func(t *testing.T) {
			calls := 0
			owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
				calls++
				return startupPage(t, test, request)
			})
			owner.ID, owner.Name, owner.RunnerID, owner.RunnerName, owner.Unregistered = strings.Repeat("a", 64), testName, 0, startupRunnerName, true
			gone, err := owner.RemoteGone(context.Background())
			if test == "absent" {
				if !gone || err != nil || calls != 2 {
					t.Fatalf("absence: %v %v calls=%d", gone, err, calls)
				}
			} else if gone || (test != startupPresentLater && err == nil) {
				t.Fatalf("uncertain absence accepted: %v %v", gone, err)
			}
		})
	}
}

func TestUnregisteredBindingRequiresPositiveExitedGatedOwnership(t *testing.T) {
	for _, test := range []struct {
		name, status, registration, gate string
		pid                              int
		valid                            bool
	}{
		{"positive-exit", testExitedStatus, startupRunnerName, startupGated, 0, true},
		{"live", testRunningStatus, startupRunnerName, startupGated, 123, false},
		{"unknown-pid", testExitedStatus, startupRunnerName, startupGated, 123, false},
		{"inert", "created", startupRunnerName, startupGated, 0, false},
		{"ungated", testExitedStatus, startupRunnerName, "", 0, false},
		{"foreign-name", testExitedStatus, "foreign-registration", startupGated, 0, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			id := strings.Repeat("a", 64)
			installExitedRegistrationFixture(t, id, test.status, test.status == testRunningStatus, test.pid, "", testRegistrationOrganization, test.registration, test.gate)
			owner := remoteFixture(t, func(*http.Request) (*http.Response, error) {
				return ownerResponse(http.StatusOK, `{"total_count":0,"runners":[]}`), nil
			})
			previous := http.DefaultTransport
			http.DefaultTransport = owner.client.Transport
			t.Cleanup(func() { http.DefaultTransport = previous })
			bound, err := BindUnregistered(context.Background(), id, testName, testRegistrationOrganization, owner.TokenPath)
			if test.valid {
				if err != nil || !bound.Unregistered || bound.RunnerID != 0 || bound.RunnerName != startupRunnerName {
					t.Fatalf("binding: %+v %v", bound, err)
				}
			} else if err == nil {
				t.Fatal("unsafe native owner bound")
			}
		})
	}
}

func TestUnregisteredWithdrawalRecoversAfterUncertainRemovalAndRetainsGrant(t *testing.T) {
	testUnregisteredRemovalRecovery(t, false)
}
func TestRetirementRecoversUnregisteredWithdrawalAfterUncertainRemoval(t *testing.T) {
	testUnregisteredRemovalRecovery(t, true)
}
func testUnregisteredRemovalRecovery(t *testing.T, retirement bool) {
	t.Helper()
	c, d, id := fixture(t)
	ctx := context.Background()
	if err := c.Start(ctx, testName, id); err != nil {
		t.Fatal(err)
	}
	d.containers[id].Running = false
	d.containers[id].Exited = true
	directory := installExitedRegistrationFixture(t, id, testExitedStatus, false, 0, "", testRegistrationOrganization, startupRunnerName, startupGated)
	// The exact immutable native removal disappears before its result is known.
	script := "#!/bin/sh\ncase \"$1\" in ps) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "listing")) + ";; inspect) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "inspect")) + ";; rm) : > " + strconv.Quote(filepath.Join(directory, "listing")) + ";; *) exit 1;; esac\n"
	if err := os.WriteFile(filepath.Join(directory, "docker"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	// #nosec G302 -- owner-only executable fixture in t.TempDir.
	if err := os.Chmod(filepath.Join(directory, "docker"), 0o700); err != nil {
		t.Fatal(err)
	}
	remotePresent := false
	owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
		if request.Method != http.MethodGet {
			t.Fatal("remote mutation")
		}
		if remotePresent {
			return ownerResponse(http.StatusOK, `{"total_count":1,"runners":[{"id":99,"name":"`+startupRunnerName+`"}]}`), nil
		}
		return ownerResponse(http.StatusOK, `{"total_count":0,"runners":[]}`), nil
	})
	owner.ID, owner.Name, owner.RunnerID, owner.RunnerName, owner.Unregistered = id, testName, 0, startupRunnerName, true
	owned, err := c.load(testName)
	if err != nil {
		t.Fatal(err)
	}
	owned.CacheCaptured = true
	if err = c.save(testName, owned); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if retirement {
		freshBind := func(_ context.Context, _, _ string, _ int64, _ string) (OwnerBinding, error) {
			return OwnerBinding{Owner: owner, RunnerName: startupRunnerName}, nil
		}
		c.Broker.Now = func() time.Time { return now }
		err = c.Retire(ctx, freshBind)
	} else {
		err = c.Withdraw(ctx, testName, id, owner, 0, startupRunnerName, now)
	}
	if !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	owned, err = c.load(testName)
	if err != nil || !owned.Withdrawal.Unregistered {
		t.Fatal("mode not durable", err)
	}
	requireStartupGrants(t, c, 1)
	c.Docker = NativeDocker{}
	// Name reappearance blocks even after the exact native owner was removed.
	remotePresent = true
	if err = owner.RemoveFrozen(ctx); err == nil {
		t.Fatal("post-removal remote presence accepted")
	}
	owned.Withdrawal.Phase = "remove_intent"
	if err = c.save(testName, owned); err != nil {
		t.Fatal(err)
	}
	bind := func(_ context.Context, _, _ string, runnerID int64, runnerName string) (OwnerBinding, error) {
		if runnerID != 0 || runnerName != startupRunnerName {
			t.Fatal("durable binding lost")
		}
		return OwnerBinding{Owner: owner, RunnerName: runnerName}, nil
	}
	c.Broker.Now = func() time.Time { return now.Add(80 * time.Second) }
	recoverOwner := func() error {
		if retirement {
			return c.Retire(ctx, bind)
		}
		return c.Rebalance(ctx, bind)
	}
	if err = recoverOwner(); err == nil {
		t.Fatal("remote presence released allocation")
	}
	requireStartupGrants(t, c, 1)
	// Also replay a completed removal whose fenced release previously failed.
	owned.Withdrawal.Phase = withdrawalRemovedPhase
	if err = c.save(testName, owned); err != nil {
		t.Fatal(err)
	}
	if err = recoverOwner(); err == nil {
		t.Fatal("saved removal skipped fresh remote proof")
	}
	requireStartupGrants(t, c, 1)
	remotePresent = false
	if err = recoverOwner(); err != nil {
		t.Fatal(err)
	}
	requireStartupGrants(t, c, 0)
	if err = recoverOwner(); err != nil {
		t.Fatal("repeat recovery", err)
	}
}

func startupPage(t *testing.T, test string, request *http.Request) (*http.Response, error) {
	t.Helper()
	if request.Method != http.MethodGet || request.URL.Query().Get("per_page") != "100" {
		t.Fatal("unregistered recovery attempted remote mutation")
	}
	if test == startupUnauthorized {
		return ownerResponse(http.StatusForbidden, `{}`), nil
	}
	if test == startupNetwork {
		return nil, errors.New(startupNetwork)
	}
	if test == "malformed" {
		return ownerResponse(http.StatusOK, `{"runners":[]}`), nil
	}
	page, parseErr := strconv.Atoi(request.URL.Query().Get("page"))
	if parseErr != nil {
		t.Fatal(parseErr)
	}
	runners := []remoteRunner{}
	for index := (page-1)*100 + 1; index <= min(page*100, 101); index++ {
		id := int64(index)
		if test == "duplicate" && page == 2 {
			id = 1
		}
		name := fmt.Sprintf("other-%d", index)
		if test == startupPresentLater && index == 101 {
			name = startupRunnerName
		}
		runners = append(runners, remoteRunner{ID: id, Name: name})
	}
	total := 101
	if test == startupTruncated {
		runners = runners[:0]
	}
	if test == "changed-total" && page == 2 {
		total++
	}
	data, err := json.Marshal(map[string]any{"total_count": total, "runners": runners})
	if err != nil {
		t.Fatal(err)
	}
	return ownerResponse(http.StatusOK, string(data)), nil
}

func requireStartupGrants(t *testing.T, c *Controller, count int) {
	t.Helper()
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != count {
		t.Fatalf("expected %d charged grants: %+v %v", count, snapshot.Grants, err)
	}
}
