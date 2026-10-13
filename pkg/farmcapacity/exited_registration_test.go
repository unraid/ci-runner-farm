// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestExitedRegistrationUsesOnlyCompleteUnambiguousRunnerSettings(t *testing.T) {
	const runnerLog = "_diag/Runner_20261007.log"
	const settings = "[2026-10-07 INFO BrokerMessageListener] {\n\"AgentId\":123,\"AgentName\":\"owned-runner\",\"GitHubUrl\":\"https://github.com/test-org\"\n}\n"
	for _, test := range []struct {
		name, file, data string
		valid            bool
	}{
		{"native settings", runnerLog, settings, true},
		{"consistent repeated settings", runnerLog, settings + settings, true},
		{"worker log", "_diag/Worker_20261007.log", settings, false},
		{"incomplete settings", runnerLog, settings[:len(settings)-3], false},
		{"ambiguous settings", runnerLog, settings + "[INFO BrokerMessageListener] {\n\"AgentId\":124,\"AgentName\":\"other\",\"GitHubUrl\":\"https://github.com/test-org\"\n}\n", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			var buffer bytes.Buffer
			archive := tar.NewWriter(&buffer)
			if err := archive.WriteHeader(&tar.Header{Name: test.file, Mode: 0o600, Size: int64(len(test.data)), Typeflag: tar.TypeReg}); err != nil {
				t.Fatal(err)
			}
			if _, err := archive.Write([]byte(test.data)); err != nil {
				t.Fatal(err)
			}
			if err := archive.Close(); err != nil {
				t.Fatal(err)
			}
			identity, err := diagnosticRegistration(&buffer)
			if test.valid {
				if err != nil || identity.AgentID != 123 || identity.AgentName != "owned-runner" {
					t.Fatalf("identity %v, error %v", identity, err)
				}
			} else if err == nil {
				t.Fatal("unproved diagnostics accepted")
			}
		})
	}
}

const (
	testExitedStatus  = "exited"
	testRunningStatus = "running"
)

func TestExitedRegistrationRequiresPositiveNativeExitAndExactIdentity(t *testing.T) {
	host, err := os.Hostname()
	if err != nil {
		t.Fatal(err)
	}
	id := strings.Repeat("a", 64)
	expected := strings.Split(host, ".")[0] + "-" + testName
	for _, test := range []struct {
		name, status, remoteName, organization string
		pid                                    int
		running, valid                         bool
	}{
		{name: "exited owner", status: testExitedStatus, remoteName: expected, organization: testRegistrationOrganization, valid: true},
		{name: "live owner", status: testRunningStatus, remoteName: expected, organization: testRegistrationOrganization, running: true, pid: 123},
		{name: "unknown exit", status: testExitedStatus, remoteName: expected, organization: testRegistrationOrganization, pid: 123},
		{name: "foreign registration", status: testExitedStatus, remoteName: "other-owner", organization: testRegistrationOrganization},
		{name: "foreign organization", status: testExitedStatus, remoteName: expected, organization: "foreign-org"},
	} {
		t.Run(test.name, func(t *testing.T) {
			installExitedRegistrationFixture(t, id, test.status, test.running, test.pid, test.remoteName, test.organization)
			runnerID, runnerName, readErr := exitedRegistration(context.Background(), id, testRegistrationOrganization, testName)
			if test.valid {
				if readErr != nil || runnerID != 123 || runnerName != expected {
					t.Fatalf("registration %d %q %v", runnerID, runnerName, readErr)
				}
			} else if readErr == nil {
				t.Fatal("unproved native owner accepted")
			}
		})
	}
}

func installExitedRegistrationFixture(t *testing.T, id, status string, running bool, pid int, remoteName, organization string, registrationNames ...string) string {
	t.Helper()
	directory := t.TempDir()
	host, hostErr := os.Hostname()
	if hostErr != nil {
		t.Fatal(hostErr)
	}
	registrationName := strings.Split(host, ".")[0] + "-" + testName
	if len(registrationNames) > 0 {
		registrationName = registrationNames[0]
	}
	labels := map[string]string{"net.unraid.ci-runner-farm.managed": strconv.FormatBool(true), "net.unraid.ci-runner-farm.provider": githubProvider, "net.unraid.ci-runner-farm.role": runnerRole, "net.unraid.ci-runner-farm.pool": buildPool}
	environment := []string{"RUNNER_NAME=" + registrationName}
	if len(registrationNames) > 1 && registrationNames[1] == startupGated {
		labels["net.unraid.ci-runner-farm.routing-labels"] = "unraid,build"
		environment = append(environment, "NO_DEFAULT_LABELS=true", "LABELS="+awaitingIdentityLabel, "RUNNER_LABELS=")
	}
	inspect, encodeErr := json.Marshal([]map[string]any{{"Id": id, "Name": "/" + testName, "Config": map[string]any{"Labels": labels, "Env": environment}, "State": map[string]any{"Status": status, "Running": running, "Pid": pid}}})
	if encodeErr != nil {
		t.Fatal(encodeErr)
	}
	settings, encodeErr := json.MarshalIndent(diagnosticIdentity{AgentID: 123, AgentName: remoteName, GitHubURL: "https://github.com/" + organization}, "", "  ")
	if encodeErr != nil {
		t.Fatal(encodeErr)
	}
	var buffer bytes.Buffer
	archive := tar.NewWriter(&buffer)
	logData := append([]byte("[INFO BrokerMessageListener] "), settings...)
	if writeErr := archive.WriteHeader(&tar.Header{Name: "_diag/Runner_native.log", Mode: 0o600, Size: int64(len(logData)), Typeflag: tar.TypeReg}); writeErr != nil {
		t.Fatal(writeErr)
	}
	if _, writeErr := archive.Write(logData); writeErr != nil {
		t.Fatal(writeErr)
	}
	if closeErr := archive.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
	for file, data := range map[string][]byte{"listing": []byte(id + "|" + testName + "\n"), "inspect": inspect, "archive": buffer.Bytes()} {
		if writeErr := os.WriteFile(filepath.Join(directory, file), data, 0o600); writeErr != nil {
			t.Fatal(writeErr)
		}
	}
	mock := "#!/bin/sh\ncase \"$1\" in ps) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "listing")) + ";; inspect) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "inspect")) + ";; cp) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "archive")) + ";; *) exit 1;; esac\n"
	executable := filepath.Join(directory, "docker")
	if writeErr := os.WriteFile(executable, []byte(mock), 0o600); writeErr != nil {
		t.Fatal(writeErr)
	}
	// #nosec G302 -- owner-only executable test fixture in t.TempDir.
	if chmodErr := os.Chmod(executable, 0o700); chmodErr != nil {
		t.Fatal(chmodErr)
	}
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
	return directory
}

func TestExitedRegistrationSurvivesHostRenameWithoutTrustingForeignDiagnostics(t *testing.T) {
	id := strings.Repeat("a", 64)
	expected := "Tower-" + testName
	for _, remote := range []string{expected, "foreign-" + testName} {
		t.Run(remote, func(t *testing.T) {
			installExitedRegistrationFixture(t, id, testExitedStatus, false, 0, remote, testRegistrationOrganization, expected)
			_, name, err := exitedRegistration(context.Background(), id, testRegistrationOrganization, testName)
			if remote == expected {
				if err != nil || name != expected {
					t.Fatalf("historical owner rejected: %v", err)
				}
			} else if err == nil {
				t.Fatal("foreign diagnostic identity accepted")
			}
		})
	}
}
