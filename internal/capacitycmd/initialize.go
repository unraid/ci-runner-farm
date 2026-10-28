// Package capacitycmd composes Farm's native controller without a QA runtime.
package capacitycmd

import (
	"context"
	"errors"
	"os"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
)

func initializeStandalone(ctx context.Context, config *hostcapacity.Config, controller *farmcapacity.Controller) error {
	if config.Mode != "closed" || len(config.Consumers) != 0 || len(config.Policy.Pools) != 1 {
		return errors.New("standalone initialization requires closed build-only ownership")
	}
	path := "/boot/config/plugins/ci-runner-farm/shared-capacity.closed"
	info, err := os.Lstat(path)
	if err != nil {
		return errors.New("standalone initialization requires native starts to be closed")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0o022 != 0 {
		return errors.New("native start closure is not a protected root-owned regular file")
	}
	return controller.InitializeStandalone(ctx)
}
