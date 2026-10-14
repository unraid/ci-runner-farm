// Package capacitycmd composes Farm's native controller without a QA runtime.
package capacitycmd

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"golang.org/x/sys/unix"
)

func expandPools(lease *hostcapacity.Lease, epoch, path string) error {
	if lease.Config.Epoch != epoch {
		return errors.New("pool expansion ownership epoch changed")
	}
	expansion, err := readPoolExpansion(path)
	if err != nil {
		return err
	}
	return lease.ExpandPools(expansion)
}

func readPoolExpansion(path string) (hostcapacity.PoolExpansion, error) {
	var result hostcapacity.PoolExpansion
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return result, errors.New("pool expansion request requires a canonical absolute path")
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return result, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return result, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || stat.Nlink != 1 || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || info.Size() > 256*1024 {
		return result, errors.New("pool expansion request is not a bounded private root file")
	}
	decoder := json.NewDecoder(io.LimitReader(file, 256*1024+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return result, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return result, errors.New("pool expansion request has trailing data")
	}
	return result, result.Validate()
}
