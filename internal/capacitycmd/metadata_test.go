package capacitycmd

import (
	"bytes"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestNativeMetadataRequiresNoQAOrCredentialRead(t *testing.T) {
	config := &hostcapacity.Config{
		TokenPath: "/missing-credential", LedgerPath: "/missing-ledger",
		ScanRepositories: []string{"unraid/core", "unraid/ci-runner-farm"},
		Policy: sharedcapacity.Policy{Pools: map[string]sharedcapacity.Pool{
			"build": {Minimum: 4, Maximum: 26, Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 4}},
		}},
	}
	for action, expected := range map[string]string{"build-limits": "4|26|12288|4", "scan-repositories": "unraid/core unraid/ci-runner-farm"} {
		var output bytes.Buffer
		if err := runMetadata(config, action, &output); err != nil || output.String() != expected {
			t.Fatal("native metadata depended on external runtime", action, output.String(), err)
		}
	}
	config.ScanRepositories = nil
	if err := runMetadata(config, "scan-repositories", &bytes.Buffer{}); err == nil {
		t.Fatal("undeclared native inventory silently scanned zero repositories")
	}
}
