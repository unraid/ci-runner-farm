package farmcapacity

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func currentShellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }

type currentDockerFixture struct {
	root, proc, id, record string
	inspect                currentInspect
	roots                  currentReadRoots
}

func currentWriteJSON(t *testing.T, path string, v any) {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}
func installCurrentMetadataFixture(t *testing.T) currentDockerFixture {
	t.Helper()
	root := t.TempDir()
	proc := filepath.Join(root, "proc")
	localProcFixture(t, proc, 44, "100")
	localProcFixture(t, proc, 45, "101")
	fakeRoot := filepath.Join(root, "container-root")
	if err := os.MkdirAll(filepath.Join(fakeRoot, "actions-runner"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(fakeRoot, filepath.Join(proc, "44", "root")); err != nil {
		t.Fatal(err)
	}
	currentWriteJSON(t, filepath.Join(fakeRoot, "actions-runner", ".runner"), map[string]any{"agentId": 123, "agentName": ownerNameForRoutingTest, "gitHubUrl": "https://github.com/" + testRegistrationOrganization})
	id := strings.Repeat("a", 64)
	row := currentInspect{ID: id, Name: "/" + testName, Image: "sha256:" + strings.Repeat("b", 64), Reference: "ci-runner-farm-runner:latest", Entrypoint: []string{"/entrypoint.sh"}, PID: 44, Running: true, Managed: "true", Provider: "github", Role: "runner", Pool: "build", Index: "1", Confgen: "123456abcdef", Memory: 12288 * 1024 * 1024, MemorySwap: -1, NanoCPUs: 1000000000}
	currentWriteJSON(t, filepath.Join(root, "before"), row)
	currentWriteJSON(t, filepath.Join(root, "after"), row)
	currentWriteJSON(t, filepath.Join(root, "image"), map[string]any{"id": row.Image, "entrypoint": row.Entrypoint, "revision": nil, "digests": []string{}})
	for name, value := range map[string]string{"endpoint": localDockerEndpoint + "\n", "top-before": "PID COMMAND\n11 Runner.Listener\n", "top-after": "PID COMMAND\n11 Runner.Listener\n", "hook": ""} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	q := func(n string) string { return currentShellQuote(filepath.Join(root, n)) }
	script := "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> " + q("commands") + "\n"
	script += "if [ \"$1\" = context ]; then exec /bin/cat " + q("endpoint") + "; fi\n"
	script += "[ \"$1\" = --host ] && [ \"$2\" = " + currentShellQuote(localDockerEndpoint) + " ] || exit 90\nshift 2\n"
	script += "case \"$1\" in\ncontainer) n=0; [ ! -f " + q("count") + " ] || n=$(/bin/cat " + q("count") + "); printf '%s' \"$((n+1))\" > " + q("count") + "; if [ \"$n\" = 0 ]; then exec /bin/cat " + q("before") + "; fi; /bin/sh " + q("hook") + "; exec /bin/cat " + q("after") + ";;\n"
	script += "top) n=0; [ ! -f " + q("top-count") + " ] || n=$(/bin/cat " + q("top-count") + "); printf '%s' \"$((n+1))\" > " + q("top-count") + "; if [ \"$n\" = 0 ]; then exec /bin/cat " + q("top-before") + "; fi; exec /bin/cat " + q("top-after") + ";;\n"
	script += "image) exec /bin/cat " + q("image") + ";;\n*) exit 91;;\nesac\n"
	// #nosec G302 -- private executable fake Docker; never a host service.
	if err := os.WriteFile(filepath.Join(root, "docker"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DOCKER_HOST", "")
	t.Setenv("DOCKER_CONTEXT", "")
	return currentDockerFixture{root: root, proc: proc, id: id, record: filepath.Join(root, "commands"), inspect: row, roots: currentReadRoots{proc: proc, rootUID: uint32(os.Geteuid()), rootGID: uint32(os.Getegid()), runnerUID: uint32(os.Geteuid())}}
}
func (f currentDockerFixture) read(ctx context.Context) (*CurrentMetadata, error) {
	return (NativeDocker{}).observeCurrentMetadataAt(ctx, f.id, 123, ownerNameForRoutingTest, testRegistrationOrganization, f.roots)
}
func TestCurrentMetadataUsesOnlyClosedCommandsAndPublicIdentity(t *testing.T) {
	f := installCurrentMetadataFixture(t)
	result, err := f.read(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if result.Runtime.InitBirth != "100" || result.Image.ID != f.inspect.Image || result.Limits.MemoryBytes != f.inspect.Memory ||
		result.MemoryFile.State != "not-observed; absence-or-access-unknown" || result.MemoryFile.ContentRead {
		t.Fatal("current projection differs", result)
	}
	commands, err := os.ReadFile(f.record)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(commands)), "\n")
	if len(lines) != 6 {
		t.Fatal("unexpected command count", len(lines), string(commands))
	}
	if !strings.Contains(lines[1], currentInspectFormat) || !strings.Contains(lines[3], currentImageFormat) {
		t.Fatal("closed formats changed", string(commands))
	}
	for _, bad := range []string{".Config.Env", ".Config.Cmd", " exec ", " start ", " stop ", " rm ", " pause ", " unpause ", " update "} {
		if strings.Contains(string(commands), bad) {
			t.Fatal("forbidden metadata command", bad)
		}
	}
	raw, _ := json.Marshal(result)
	if strings.Contains(string(raw), "container-root") || strings.Contains(string(raw), "TokenPath") || strings.Contains(string(raw), "environment") {
		t.Fatal("private data leaked", string(raw))
	}
}
func TestCurrentMetadataRefusesSpoofedFieldsAndBusyWorkers(t *testing.T) {
	for _, kind := range []string{"foreign ID", "wrong name", "not running", "paused", "restarting", "invalid PID", "provider", "managed", "pool", "index", "confgen", "imageID", "private image", "entrypoint args", "negative swap", "worker before", "worker after", "bad public identity", "public parent mode", "public symlink", "public mode", "image mismatch", "image entrypoint", "image revision", "oversized", "nonlocal context", "nonlocal HOST", "missing birth", "memory symlink", "memory mode"} {
		t.Run(kind, func(t *testing.T) {
			f := installCurrentMetadataFixture(t)
			row := f.inspect
			switch kind {
			case "foreign ID":
				row.ID = strings.Repeat("c", 64)
			case "wrong name":
				row.Name = "/foreign"
			case "not running":
				row.Running = false
			case "paused":
				row.Paused = true
			case "restarting":
				row.Restarting = true
			case "invalid PID":
				row.PID = 0
			case "provider":
				row.Provider = "foreign"
			case "managed":
				row.Managed = "false"
			case "pool":
				row.Pool = "foreign"
			case "index":
				row.Index = "2"
			case "confgen":
				row.Confgen = "bad"
			case "imageID":
				row.Image = "invalid"
			case "private image":
				row.Reference = "private.invalid/SYNTHETIC_SECRET:latest"
			case "entrypoint args":
				row.Entrypoint = append(row.Entrypoint, "SYNTHETIC_SECRET")
			case "negative swap":
				row.MemorySwap = -2
			case "worker before":
				if err := os.WriteFile(filepath.Join(f.root, "top-before"), []byte("PID COMMAND\n11 Runner.Listener\n12 Runner.Worker\n"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "worker after":
				if err := os.WriteFile(filepath.Join(f.root, "top-after"), []byte("PID COMMAND\n11 Runner.Listener\n12 Runner.Worker\n"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "bad public identity":
				currentWriteJSON(t, filepath.Join(f.root, "container-root/actions-runner/.runner"), map[string]any{"agentId": 124})
			case "public parent mode":
				if err := os.Chmod(filepath.Join(f.root, "container-root/actions-runner"), 0o777); err != nil {
					t.Fatal(err)
				}
			case "public symlink":
				p := filepath.Join(f.root, "container-root/actions-runner/.runner")
				if err := os.Remove(p); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(f.root, "image"), p); err != nil {
					t.Fatal(err)
				}
			case "public mode":
				if err := os.Chmod(filepath.Join(f.root, "container-root/actions-runner/.runner"), 0o666); err != nil {
					t.Fatal(err)
				}
			case "image mismatch":
				currentWriteJSON(t, filepath.Join(f.root, "image"), map[string]any{"id": "sha256:" + strings.Repeat("c", 64), "entrypoint": row.Entrypoint})
			case "image entrypoint":
				currentWriteJSON(t, filepath.Join(f.root, "image"), map[string]any{"id": row.Image, "entrypoint": []string{"/foreign"}})
			case "image revision":
				currentWriteJSON(t, filepath.Join(f.root, "image"), map[string]any{"id": row.Image, "entrypoint": row.Entrypoint, "revision": "SYNTHETIC_SECRET"})
			case "nonlocal context":
				if err := os.WriteFile(filepath.Join(f.root, "endpoint"), []byte("tcp://foreign:2376\n"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "nonlocal HOST":
				t.Setenv("DOCKER_HOST", "tcp://foreign:2376")
			case "missing birth":
				if err := os.Remove(filepath.Join(f.proc, "44", "stat")); err != nil {
					t.Fatal(err)
				}
			case "memory symlink":
				etc := filepath.Join(f.root, "container-root/etc")
				if err := os.MkdirAll(etc, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(f.root, filepath.Join(etc, "unraid-ci")); err != nil {
					t.Fatal(err)
				}
			case "memory mode":
				p := filepath.Join(f.root, "container-root/etc/unraid-ci")
				if err := os.MkdirAll(p, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(p, "runtime-memory-max"), []byte("123"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			currentWriteJSON(t, filepath.Join(f.root, "before"), row)
			if kind == "oversized" {
				if err := os.WriteFile(filepath.Join(f.root, "before"), []byte(strings.Repeat("x", 8193)), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			result, err := f.read(t.Context())
			if err == nil || result != nil {
				t.Fatal("unproved metadata accepted", result)
			}
			if strings.Contains(err.Error(), "SYNTHETIC_SECRET") {
				t.Fatal("raw private error escaped", err)
			}
			if kind == "nonlocal HOST" {
				if _, statErr := os.Stat(f.record); !os.IsNotExist(statErr) {
					t.Fatal("nonlocal HOST reached Docker")
				}
			}
		})
	}
}
func TestCurrentMetadataDetectsContainerAndKernelRaces(t *testing.T) {
	for _, kind := range []string{"container", "PID", "birth", "boot", "namespace", "registration", "root", "memory"} {
		t.Run(kind, func(t *testing.T) {
			f := installCurrentMetadataFixture(t)
			after := f.inspect
			hook := ""
			q := currentShellQuote
			switch kind {
			case "container":
				after.Image = "sha256:" + strings.Repeat("c", 64)
			case "PID":
				after.PID = 45
			case "birth":
				original, err := os.ReadFile(filepath.Join(f.proc, "44/stat"))
				if err != nil {
					t.Fatal(err)
				}
				if err = os.WriteFile(filepath.Join(f.root, "newstat"), []byte(strings.TrimSuffix(string(original), "100")+"101"), 0o600); err != nil {
					t.Fatal(err)
				}
				hook = "exec /bin/cp " + q(filepath.Join(f.root, "newstat")) + " " + q(filepath.Join(f.proc, "44/stat"))
			case "boot":
				hook = "printf '%s' 22222222-2222-4222-8222-222222222222 > " + q(filepath.Join(f.proc, "sys/kernel/random/boot_id"))
			case "namespace":
				p := filepath.Join(f.proc, "44/ns/mnt")
				hook = "/bin/rm " + q(p) + "; /bin/ln -s 'mnt:[99]' " + q(p)
			case "registration":
				currentWriteJSON(t, filepath.Join(f.root, "changed-public"), map[string]any{"agentId": 124})
				hook = "exec /bin/cp " + q(filepath.Join(f.root, "changed-public")) + " " + q(filepath.Join(f.root, "container-root/actions-runner/.runner"))
			case "root":
				other := filepath.Join(f.root, "other-root")
				if err := os.MkdirAll(other, 0o755); err != nil {
					t.Fatal(err)
				}
				p := filepath.Join(f.proc, "44/root")
				hook = "/bin/rm " + q(p) + "; /bin/ln -s " + q(other) + " " + q(p)
			case "memory":
				p := filepath.Join(f.root, "container-root/etc/unraid-ci")
				hook = "/bin/mkdir -p " + q(p) + "; printf '%s' 123 > " + q(filepath.Join(p, "runtime-memory-max")) + "; /bin/chmod 444 " + q(filepath.Join(p, "runtime-memory-max"))
			}
			currentWriteJSON(t, filepath.Join(f.root, "after"), after)
			if err := os.WriteFile(filepath.Join(f.root, "hook"), []byte(hook), 0o600); err != nil {
				t.Fatal(err)
			}
			if result, err := f.read(t.Context()); err == nil || result != nil {
				t.Fatal("raced metadata accepted", result)
			}
		})
	}
}
func TestCurrentMemoryMetadataNeverReadsContents(t *testing.T) {
	f := installCurrentMetadataFixture(t)
	root, _, err := currentRoot(f.proc, 44)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	p := filepath.Join(f.root, "container-root/etc/unraid-ci")
	if err = os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
	secret := "SYNTHETIC_MEMORY_SECRET"
	if err = os.WriteFile(filepath.Join(p, "runtime-memory-max"), []byte(secret), 0o444); err != nil {
		t.Fatal(err)
	}
	result, err := currentMemoryMetadata(int(root.Fd()), f.roots)
	if err != nil || result.State != "root0444-regular-present" || result.ContentRead || result.Metadata.Size != int64(len(secret)) {
		t.Fatal(result, err)
	}
	raw, _ := json.Marshal(result)
	if strings.Contains(string(raw), secret) {
		t.Fatal("memory content leaked")
	}
	for _, parts := range [][]string{{".."}, {"etc", "../foreign"}, {"etc", "unraid-ci", "runtime-memory-max", "extra"}} {
		file, err := openCurrentPath(int(root.Fd()), parts)
		if file != nil {
			_ = file.Close()
		}
		if err == nil {
			t.Fatal("unselected path accepted", parts)
		}
	}
}
func TestCurrentMetadataCancellationIsBounded(t *testing.T) {
	f := installCurrentMetadataFixture(t)
	// #nosec G302 -- bounded private process fixture; exec avoids orphaned children.
	if err := os.WriteFile(filepath.Join(f.root, "docker"), []byte("#!/bin/sh\nexec /bin/sleep 20\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Millisecond)
	defer cancel()
	start := time.Now()
	if result, err := f.read(ctx); err == nil || result != nil {
		t.Fatal("cancellation succeeded")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("current read did not cancel promptly")
	}
}
func TestCurrentMetadataJSONBoundsAndSelector(t *testing.T) {
	for _, raw := range []string{"{} {}", "{\"unexpected\":true}", "not-json"} {
		var value currentInspect
		if err := decodeCurrentJSON([]byte(raw), &value); err == nil {
			t.Fatal("unclosed JSON accepted", raw)
		}
	}
	f := installCurrentMetadataFixture(t)
	for _, id := range []string{"name", strings.Repeat("a", 63), strings.Repeat("A", 64)} {
		if result, err := (NativeDocker{}).observeCurrentMetadataAt(t.Context(), id, 123, ownerNameForRoutingTest, testRegistrationOrganization, f.roots); err == nil || result != nil {
			t.Fatal("unbound Docker selector accepted")
		}
	}
}

func TestCurrentMetadataRejectsMissingNullAndDuplicateFields(t *testing.T) {
	for _, key := range []string{"paused", "restarting", "memorySwap", "running", "pid"} {
		for _, kind := range []string{"missing", "null", "duplicate"} {
			t.Run(key+"/"+kind, func(t *testing.T) {
				f := installCurrentMetadataFixture(t)
				raw, err := json.Marshal(f.inspect)
				if err != nil {
					t.Fatal(err)
				}
				var fields map[string]json.RawMessage
				if err := json.Unmarshal(raw, &fields); err != nil {
					t.Fatal(err)
				}
				if kind == "missing" {
					delete(fields, key)
				} else if kind == "null" {
					fields[key] = json.RawMessage("null")
				}
				raw, err = json.Marshal(fields)
				if err != nil {
					t.Fatal(err)
				}
				if kind == "duplicate" {
					raw = []byte(strings.Replace(string(raw), `"`+key+`":`, `"`+key+`":null,"`+key+`":`, 1))
				}
				if err := os.WriteFile(filepath.Join(f.root, "before"), raw, 0o600); err != nil {
					t.Fatal(err)
				}
				if result, err := f.read(t.Context()); err == nil || result != nil {
					t.Fatal("ambiguous state field accepted")
				}
			})
		}
	}
	f := installCurrentMetadataFixture(t)
	path := filepath.Join(f.root, "container-root/actions-runner/.runner")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	raw = []byte(strings.Replace(string(raw), `"agentId":123`, `"agentId":999,"agentId":123`, 1))
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if result, err := f.read(t.Context()); err == nil || result != nil {
		t.Fatal("duplicate public registration accepted")
	}
}

func TestCurrentMetadataDropsUnselectedImageDigestsAndRejectsUnknownProcesses(t *testing.T) {
	f := installCurrentMetadataFixture(t)
	currentWriteJSON(t, filepath.Join(f.root, "image"), map[string]any{"id": f.inspect.Image, "entrypoint": f.inspect.Entrypoint, "revision": nil, "digests": []string{"private.invalid/SYNTHETIC_SECRET@sha256:" + strings.Repeat("c", 64)}})
	result, err := f.read(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(result)
	if strings.Contains(string(raw), "SYNTHETIC_SECRET") || len(result.Image.RepoDigests) != 0 {
		t.Fatal("unselected image metadata escaped")
	}
	for _, table := range []string{"11 Runner.Listener\n", "PID COMMAND\n", "PID COMMAND\n11 Runner.Listener\n12 Runner.Listener\n"} {
		t.Run(strings.ReplaceAll(table, "\n", "_"), func(t *testing.T) {
			f := installCurrentMetadataFixture(t)
			if err := os.WriteFile(filepath.Join(f.root, "top-before"), []byte(table), 0o600); err != nil {
				t.Fatal(err)
			}
			if result, err := f.read(t.Context()); err == nil || result != nil {
				t.Fatal("unproved worker table accepted")
			}
		})
	}
}
