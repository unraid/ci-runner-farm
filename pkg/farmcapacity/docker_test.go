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

func localProcFixture(t *testing.T, root string, pid int, birth string) {
	t.Helper()
	path := filepath.Join(root, strconv.Itoa(pid), "ns")
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
	fields := append([]string{"S", "1", strconv.Itoa(pid)}, make([]string, 17)...)
	for n := 3; n < len(fields); n++ {
		fields[n] = "0"
	}
	fields[19] = birth
	if err := os.WriteFile(filepath.Join(filepath.Dir(path), "stat"), []byte(strconv.Itoa(pid)+" (fixture) "+strings.Join(fields, " ")), 0o600); err != nil {
		t.Fatal(err)
	}
	for n, key := range []string{"pid", "mnt", "user", "cgroup", "net"} {
		if err := os.Symlink(key+":["+strconv.Itoa(n+10)+"]", filepath.Join(path, key)); err != nil {
			t.Fatal(err)
		}
	}
	boot := filepath.Join(root, "sys/kernel/random")
	if err := os.MkdirAll(boot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(boot, "boot_id"), []byte("11111111-1111-4111-8111-111111111111"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestNativeOwnerSamplesDetectInspectAndKernelIdentityRaces(t *testing.T) {
	for _, mode := range []string{"stable", "replacement", "pid", "birth", "boot", "namespace", "resources", "missing"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			proc := filepath.Join(root, "proc")
			localProcFixture(t, proc, 44, "100")
			localProcFixture(t, proc, 45, "101")
			id := strings.Repeat("a", 64)
			first := map[string]any{"Id": id, "Name": "/" + testName, "State": map[string]any{"Status": "running", "Running": true, "Paused": false, "Pid": 44}, "HostConfig": map[string]any{"Memory": uint64(12288 * 1024 * 1024), "NanoCpus": uint64(1000000000)}, "Config": map[string]any{"Labels": map[string]string{"net.unraid.ci-runner-farm.confgen": "123456abcdef"}}}
			raw, _ := json.Marshal([]any{first})
			if err := os.WriteFile(filepath.Join(root, "first"), raw, 0o600); err != nil {
				t.Fatal(err)
			}
			switch mode {
			case "replacement":
				first["Id"] = strings.Repeat("b", 64)
			case "pid":
				first["State"].(map[string]any)["Pid"] = 45
			case "resources":
				first["HostConfig"].(map[string]any)["Memory"] = uint64(16384 * 1024 * 1024)
			}
			raw, _ = json.Marshal([]any{first})
			if err := os.WriteFile(filepath.Join(root, "second"), raw, 0o600); err != nil {
				t.Fatal(err)
			}
			mutation := ""
			switch mode {
			case "birth":
				data, err := os.ReadFile(filepath.Join(proc, "44/stat"))
				if err != nil {
					t.Fatal(err)
				}
				data = []byte(strings.TrimSuffix(string(data), "100") + "999")
				if err = os.WriteFile(filepath.Join(root, "changed"), data, 0o600); err != nil {
					t.Fatal(err)
				}
				mutation = "/bin/cp " + strconv.Quote(filepath.Join(root, "changed")) + " " + strconv.Quote(filepath.Join(proc, "44/stat")) + "; "
			case "boot":
				mutation = "echo 22222222-2222-4222-8222-222222222222 > " + strconv.Quote(filepath.Join(proc, "sys/kernel/random/boot_id")) + "; "
			case "namespace":
				mutation = "/bin/rm " + strconv.Quote(filepath.Join(proc, "44/ns/pid")) + "; /bin/ln -s 'pid:[99]' " + strconv.Quote(filepath.Join(proc, "44/ns/pid")) + "; "
			case "missing":
				mutation = "/bin/rm " + strconv.Quote(filepath.Join(proc, "44/stat")) + "; "
			}
			script := "#!/bin/sh\ncase \"$1\" in --host) [ \"$2\" = unix:///var/run/docker.sock ] || exit 2; shift 2;; esac\ncase \"$1\" in\ncontext) echo unix:///var/run/docker.sock;;\nps) echo '" + id + "|" + testName + "';;\ninspect) if [ -f " + strconv.Quote(filepath.Join(root, "seen")) + " ]; then " + mutation + "exec /bin/cat " + strconv.Quote(filepath.Join(root, "second")) + "; fi; /usr/bin/touch " + strconv.Quote(filepath.Join(root, "seen")) + "; exec /bin/cat " + strconv.Quote(filepath.Join(root, "first")) + ";;\n*) exit 1;;\nesac\n"
			if err := os.WriteFile(filepath.Join(root, "docker"), []byte(script), 0o600); err != nil {
				t.Fatal(err)
			}
			// #nosec G302 -- private executable Docker fixture in t.TempDir, no host calls.
			if err := os.Chmod(filepath.Join(root, "docker"), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH"))
			row, err := (NativeDocker{}).observeLocalOwner(t.Context(), id, proc)
			switch {
			case mode == "stable":
				if err != nil || !validLocalIdentity(row) {
					t.Fatal(row, err)
				}
			case err == nil:
				t.Fatal("racing native identity accepted", mode, row)
			case mode != "missing" && err.Error() != "native owner changed during identity observation":
				t.Fatal("fixture failed for the wrong reason", mode, err)
			}
		})
	}
}

func TestOwnerObservationCannotJoinRemoteDockerPIDsToLocalProc(t *testing.T) {
	for _, mode := range []string{"environment override", "context endpoint"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			marker := filepath.Join(root, "inspected")
			script := "#!/bin/sh\ncase \"$1\" in context) echo ssh://remote-fixture;; *) /usr/bin/touch " + strconv.Quote(marker) + "; exit 1;; esac\n"
			if err := os.WriteFile(filepath.Join(root, "docker"), []byte(script), 0o600); err != nil {
				t.Fatal(err)
			}
			// #nosec G302 -- private executable endpoint fixture, no Docker daemon contacted.
			if err := os.Chmod(filepath.Join(root, "docker"), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH"))
			t.Setenv("DOCKER_HOST", "")
			if mode == "environment override" {
				t.Setenv("DOCKER_HOST", "tcp://remote-fixture:2376")
			}
			if _, err := (NativeDocker{}).observeLocalOwner(t.Context(), strings.Repeat("a", 64), filepath.Join(root, "no-proc")); err == nil {
				t.Fatal("remote daemon was treated as local")
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatal("probed a container before establishing local endpoint", err)
			}
		})
	}
}

// Source-only review control: a context changes after the initial endpoint read.
// Every Docker command is a private shell fixture. No daemon is contacted.
func TestLocalEndpointContextFlipCannotAuthorizeRemotePIDJoin(t *testing.T) {
	root := t.TempDir()
	proc := filepath.Join(root, "proc")
	localProcFixture(t, proc, 44, "100")
	id := strings.Repeat("a", 64)
	data, _ := json.Marshal([]any{map[string]any{
		"Id": id, "Name": "/" + testName,
		"State":      map[string]any{"Status": "running", "Running": true, "Paused": false, "Pid": 44},
		"HostConfig": map[string]any{"Memory": uint64(12288 * 1024 * 1024), "NanoCpus": uint64(1000000000)},
		"Config":     map[string]any{"Labels": map[string]string{"net.unraid.ci-runner-farm.confgen": "123456abcdef"}},
	}})
	identity := filepath.Join(root, "identity.json")
	if err := os.WriteFile(identity, data, 0o600); err != nil {
		t.Fatal(err)
	}
	switched := strconv.Quote(filepath.Join(root, "context-switched"))
	remote := filepath.Join(root, "remote-command")
	script := "#!/bin/sh\npinned=0\n" +
		"if [ \"${DOCKER_HOST-}\" = unix:///var/run/docker.sock ] && [ -z \"${DOCKER_CONTEXT-}\" ]; then pinned=1; fi\n" +
		"case \"$1\" in --host|-H) [ \"$2\" = unix:///var/run/docker.sock ] || exit 2; pinned=1; shift 2;; --host=unix:///var/run/docker.sock) pinned=1; shift;; esac\n" +
		"case \"$1\" in\ncontext) if [ -f " + switched + " ]; then echo ssh://remote-fixture; else echo unix:///var/run/docker.sock; /usr/bin/touch " + switched + "; fi;;\n" +
		"ps|inspect) if [ \"$pinned\" = 0 ] && [ -f " + switched + " ]; then /usr/bin/touch " + strconv.Quote(remote) + "; fi; " +
		"if [ \"$1\" = ps ]; then echo '" + id + "|" + testName + "'; else /bin/cat " + strconv.Quote(identity) + "; fi;;\n*) exit 1;;\nesac\n"
	if err := os.WriteFile(filepath.Join(root, "docker"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DOCKER_HOST", "")
	t.Setenv("DOCKER_CONTEXT", "")
	row, err := (NativeDocker{}).observeLocalOwner(t.Context(), id, proc)
	if _, remoteErr := os.Stat(remote); remoteErr == nil && err == nil {
		t.Fatalf("accepted local provenance after unpinned Docker commands followed a changed remote context: %+v", row)
	}
}

func TestPinnedLocalReadsVerifyRegistrationAndPreserveParentEnvironment(t *testing.T) {
	for _, mode := range []string{"complete", "local environment", "foreign runner", "foreign organization", "unavailable", "init changed after public read"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			proc := filepath.Join(root, "proc")
			localProcFixture(t, proc, 44, "100")
			id := strings.Repeat("a", 64)
			runnerName := "approved-host-" + testName
			data, _ := json.Marshal([]any{map[string]any{"Id": id, "Name": "/" + testName, "State": map[string]any{"Status": "running", "Running": true, "Paused": false, "Pid": 44}, "HostConfig": map[string]any{"Memory": uint64(12288 * 1024 * 1024), "NanoCpus": uint64(1000000000)}, "Config": map[string]any{"Env": []string{"RUNNER_NAME=" + runnerName}, "Labels": map[string]string{"net.unraid.ci-runner-farm.confgen": "123456abcdef", "net.unraid.ci-runner-farm.managed": "true", "net.unraid.ci-runner-farm.provider": "github", "net.unraid.ci-runner-farm.role": "runner", "net.unraid.ci-runner-farm.pool": "build"}}}})
			inspection := filepath.Join(root, "inspection")
			if err := os.WriteFile(inspection, data, 0o600); err != nil {
				t.Fatal(err)
			}
			publicID := int64(123)
			organization := testRegistrationOrganization
			if mode == "foreign runner" {
				publicID = 987
			}
			if mode == "foreign organization" {
				organization = "foreign"
			}
			data, _ = json.Marshal(map[string]any{"agentId": publicID, "agentName": runnerName, "gitHubUrl": "https://github.com/" + organization})
			publicFile := filepath.Join(root, "public-identity")
			if err := os.WriteFile(publicFile, append([]byte{0xef, 0xbb, 0xbf}, data...), 0o600); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(root, "unpinned")
			switched := filepath.Join(root, "switched")
			execBranch := "exec /bin/cat " + strconv.Quote(publicFile)
			if mode == "unavailable" {
				execBranch = "exit 1"
			}
			if mode == "init changed after public read" {
				statPath := filepath.Join(proc, "44/stat")
				statData, err := os.ReadFile(statPath)
				if err != nil {
					t.Fatal(err)
				}
				changed := filepath.Join(root, "changed-stat")
				if err = os.WriteFile(changed, []byte(strings.TrimSuffix(string(statData), "100")+"999"), 0o600); err != nil {
					t.Fatal(err)
				}
				execBranch = "/bin/cp " + strconv.Quote(changed) + " " + strconv.Quote(statPath) + "; " + execBranch
			}
			script := "#!/bin/sh\npinned=0\ncase \"$1\" in --host) [ \"$2\" = unix:///var/run/docker.sock ] || exit 2; pinned=1; shift 2;; esac\nif [ \"$1\" != context ]; then\n if [ \"$pinned\" != 1 ] || [ -n \"${DOCKER_CONTEXT-}${DOCKER_HOST-}${DOCKER_TLS_VERIFY-}${DOCKER_CERT_PATH-}\" ]; then /usr/bin/touch " + strconv.Quote(marker) + "; exit 3; fi\nfi\ncase \"$1\" in\ncontext) if [ -f " + strconv.Quote(switched) + " ]; then echo ssh://remote-fixture; else /usr/bin/touch " + strconv.Quote(switched) + "; echo unix:///var/run/docker.sock; fi;;\nps) echo '" + id + "|" + testName + "';;\ninspect) exec /bin/cat " + strconv.Quote(inspection) + ";;\nexec) " + execBranch + ";;\n*) exit 1;;\nesac\n"
			if err := os.WriteFile(filepath.Join(root, "docker"), []byte(script), 0o600); err != nil {
				t.Fatal(err)
			}
			// #nosec G302 -- private executable Docker fixture; no daemon or credential contacted.
			if err := os.Chmod(filepath.Join(root, "docker"), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH"))
			parent := map[string]string{"DOCKER_HOST": "", "DOCKER_CONTEXT": "operator-context", "DOCKER_TLS_VERIFY": "1", "DOCKER_CERT_PATH": "/private/not-read-fixture"}
			if mode == "local environment" {
				parent["DOCKER_HOST"] = localDockerEndpoint
			}
			for key, value := range parent {
				t.Setenv(key, value)
			}
			d := NativeDocker{}
			row, err := d.observeLocalOwner(t.Context(), id, proc)
			if err != nil {
				t.Fatal(err)
			}
			err = d.verifyLocalRegistrationAt(t.Context(), row, testRegistrationOrganization, 123, runnerName, proc)
			if (err == nil) != (mode == "complete" || mode == "local environment") {
				t.Fatal("pinned public identity result differs", mode, err)
			}
			if _, err = d.inspectLocalOwner(t.Context(), id); err != nil {
				t.Fatal("final local reinspection was not pinned", err)
			}
			if _, err = os.Stat(marker); !os.IsNotExist(err) {
				t.Fatal("optional provenance used conflicting endpoint state", err)
			}
			for key, value := range parent {
				if os.Getenv(key) != value {
					t.Fatal("operator environment was mutated", key)
				}
			}
		})
	}
}

func TestOrdinaryInspectRetainsOperatorContextAndEnvironment(t *testing.T) {
	id := strings.Repeat("a", 64)
	installFailingDocker(t, id, "")
	// Ordinary Inspect must keep using the operator's endpoint and environment.
	// The existing fixture accepts only the original plain ps/inspect argv.
	t.Setenv("DOCKER_CONTEXT", "ordinary-operator-context")
	t.Setenv("DOCKER_HOST", "tcp://ordinary-fixture:2376")
	if _, err := (NativeDocker{}).Inspect(t.Context(), id); err != nil {
		t.Fatal("ordinary Inspect was changed", err)
	}
	if os.Getenv("DOCKER_CONTEXT") != "ordinary-operator-context" || os.Getenv("DOCKER_HOST") != "tcp://ordinary-fixture:2376" {
		t.Fatal("operator endpoint was mutated")
	}
}
