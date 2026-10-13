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
	host, err := os.Hostname()
	if err != nil {
		t.Fatal(err)
	}
	expectedName := strings.Split(host, ".")[0] + "-" + testName
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
			directory := t.TempDir()
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
			mock := "#!/bin/sh\nexec /bin/cat " + strconv.Quote(fixture) + "\n"
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
