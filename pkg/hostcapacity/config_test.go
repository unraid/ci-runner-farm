package hostcapacity

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func testRoot(t *testing.T) string {
	t.Helper()
	path, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func testConfig(root string) Config {
	return Config{
		Schema: 1, Host: "test-host", Epoch: strings.Repeat("a", 32), Organization: "test-org", Mode: "active",
		LedgerPath: filepath.Join(root, "admission.bolt"), ReceiptRoot: filepath.Join(root, "receipts"),
		TokenPath: filepath.Join(root, "token"), LockPath: filepath.Join(root, "locks", "capacity.lock"),
		Policy: sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 32768, VCPUs: 8}, AgingSeconds: 60,
			Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 8192, VCPUs: 2}, Minimum: 1, Maximum: 4}}},
	}
}

func writeConfig(t *testing.T, path string, config Config) {
	t.Helper()
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestHostConfigRequiresExplicitBoundedOwnership(t *testing.T) {
	for _, change := range []func(*Config){
		func(c *Config) { c.Mode = "" },
		func(c *Config) { c.Host = "other-host" },
		func(c *Config) { c.Epoch = "" },
		func(c *Config) { c.Policy.Budget.MemoryMiB = 0 },
		func(c *Config) { c.LedgerPath = "relative" },
		func(c *Config) { c.ReceiptRoot = c.LedgerPath },
		func(c *Config) { c.Consumers = map[string]Consumer{"other": {Pools: []string{"build"}}} },
		func(c *Config) { c.Policy.Pools["unowned"] = c.Policy.Pools["build"] },
	} {
		config := testConfig(testRoot(t))
		change(&config)
		if err := config.Validate("test-host"); err == nil {
			t.Fatal("invalid host ownership was accepted", config)
		}
	}
}

func TestHostConfigLoadsWithoutConsumerConfiguration(t *testing.T) {
	root := testRoot(t)
	config := testConfig(root)
	path := filepath.Join(root, "host-capacity.json")
	writeConfig(t, path, config)
	got, err := load(path, "test-host", uint32(os.Geteuid()))
	if err != nil || got.LedgerPath != config.LedgerPath || got.Epoch != config.Epoch {
		t.Fatal("standalone host configuration did not load", got, err)
	}
	if _, err := load(path, "test-host", uint32(os.Geteuid()+1)); err == nil {
		t.Fatal("foreign-owned policy was accepted")
	}
	config.Policy.Pools["guest"] = sharedcapacity.Pool{Cost: sharedcapacity.Resources{MemoryMiB: 4096, VCPUs: 2}, Maximum: 2}
	config.Consumers = map[string]Consumer{"guest-provider": {Pools: []string{"guest"}, OverheadMiB: 1024}}
	if err := config.Validate("test-host"); err != nil {
		t.Fatal("declared consumer was rejected", err)
	}
}

func TestHostConfigRejectsUnsafeFilesAndAmbiguousJSON(t *testing.T) {
	for _, mode := range []string{"symlink", "public", "oversize", "trailing", "unknown", "directory"} {
		t.Run(mode, func(t *testing.T) {
			root := testRoot(t)
			path := filepath.Join(root, "host-capacity.json")
			writeConfig(t, path, testConfig(root))
			switch mode {
			case "symlink":
				if err := os.Rename(path, path+".real"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(path+".real", path); err != nil {
					t.Fatal(err)
				}
			case "public":
				if err := os.Chmod(path, 0o644); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(path, 0o700); err != nil {
					t.Fatal(err)
				}
			default:
				data, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				switch mode {
				case "oversize":
					data = []byte(strings.Repeat(" ", 65537))
				case "trailing":
					data = append(data, []byte("{}")...)
				default:
					data = []byte(strings.TrimSuffix(string(data), "}") + `,"unknown":true}`)
				}
				if err := os.WriteFile(path, data, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := load(path, "test-host", uint32(os.Geteuid())); err == nil {
				t.Fatal("unsafe policy was accepted")
			}
		})
	}
}
