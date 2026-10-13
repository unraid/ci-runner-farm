// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
