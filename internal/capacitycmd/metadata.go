// Package capacitycmd exposes Farm's protected native admission commands.
package capacitycmd

import (
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
)

// runMetadata emits only noncredential routing and limits from the protected
// owner contract. It neither opens the ledger nor mutates workload owners.
func runMetadata(config *hostcapacity.Config, action string, output io.Writer) error {
	switch action {
	case "build-limits":
		pool := config.Policy.Pools["build"]
		if pool.Minimum == 0 || pool.Maximum < pool.Minimum || pool.Maximum > 64 || pool.Cost.MemoryMiB < 12288 || pool.Cost.MemoryMiB > 16384 || pool.Cost.VCPUs == 0 || pool.Cost.VCPUs > 64 {
			return errors.New("native build limits do not support the configured pools")
		}
		_, err := fmt.Fprintf(output, "%d|%d|%d|%d", pool.Minimum, pool.Maximum, pool.Cost.MemoryMiB, pool.Cost.VCPUs)
		return err
	case "scan-repositories":
		if len(config.ScanRepositories) == 0 {
			return errors.New("native Farm scan repository inventory is undeclared")
		}
		_, err := fmt.Fprint(output, strings.Join(config.ScanRepositories, " "))
		return err
	default:
		return errors.New("unknown native Farm metadata action")
	}
}
