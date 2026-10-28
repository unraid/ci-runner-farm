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

// installFailingDocker answers inspection with an exact never-started owner and
// fails every start or removal with the supplied daemon output.
func installFailingDocker(t *testing.T, id, stderr string) {
	t.Helper()
	directory := t.TempDir()
	inspect, err := json.Marshal([]map[string]any{{"Id": id, "Name": "/" + testName, "State": map[string]any{"Status": nativeCreatedStatus, "Running": false, "Paused": false, "Pid": 0, "StartedAt": "0001-01-01T00:00:00Z"}}})
	if err != nil {
		t.Fatal(err)
	}
	for file, data := range map[string][]byte{"listing": []byte(id + "|" + testName + "\n"), "inspect": inspect, "stderr": []byte(stderr)} {
		if err = os.WriteFile(filepath.Join(directory, file), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	script := "#!/bin/sh\ncase \"$1\" in ps) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "listing")) + ";; inspect) exec /bin/cat " + strconv.Quote(filepath.Join(directory, "inspect")) + ";; start|rm) /bin/cat " + strconv.Quote(filepath.Join(directory, "stderr")) + " >&2; exit 1;; *) exit 1;; esac\n"
	if err = os.WriteFile(filepath.Join(directory, "docker"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	// #nosec G302 -- owner-only executable test fixture in t.TempDir.
	if err = os.Chmod(filepath.Join(directory, "docker"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func TestNativeDockerFailuresKeepStablePrefixAndBoundedDaemonReason(t *testing.T) {
	id := strings.Repeat("a", 64)
	for _, test := range []struct {
		name, stderr, reason string
	}{
		{"endpoint collision", "Error response from daemon: failed to set up container networking: endpoint with name ci-runner-build-9 already exists in network ci-runner-net\nError: failed to start containers: " + id + "\n", "failed to set up container networking: endpoint with name ci-runner-build-9 already exists in network ci-runner-net"},
		{"silent", "", ""},
		{"control characters", "\n\x1b[31mbind\tsource\r\x00 missing\xff\n", "[31mbind source missing"},
		{"unbounded", strings.Repeat("x", 4*dockerReasonLimit), strings.Repeat("x", dockerReasonLimit) + "..."},
		{"multibyte boundary", strings.Repeat("x", dockerReasonLimit-1) + "état", strings.Repeat("x", dockerReasonLimit-1) + "..."},
	} {
		t.Run(test.name, func(t *testing.T) {
			installFailingDocker(t, id, test.stderr)
			for prefix, err := range map[string]error{
				"Docker build start did not complete":   (NativeDocker{}).Start(context.Background(), id),
				"inert native removal did not complete": (NativeDocker{}).RemoveCreated(context.Background(), id),
			} {
				want := prefix
				if test.reason != "" {
					want += ": " + test.reason
				}
				if err == nil || err.Error() != want {
					t.Fatalf("Docker failure %q, want %q", err, want)
				}
			}
		})
	}
}
