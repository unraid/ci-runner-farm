// Package hostcapacity defines Farm's protected host admission contract.
package hostcapacity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Lease pins configuration through one admission or lifecycle transaction.
// Policy changes and ownership handoffs take an exclusive lease. Participants
// take shared leases before loading policy and retain them through effects.
type Lease struct {
	Config    *Config
	file      *os.File
	path      string
	owner     uint32
	exclusive bool
}

// Close releases this participant's policy lease.
func (l *Lease) Close() error { return l.file.Close() }

// Acquire uses the same protected lock for Farm and every capacity consumer.
func Acquire(ctx context.Context, path string, exclusive bool) (*Lease, error) {
	host, err := os.Hostname()
	if err != nil {
		return nil, err
	}
	return acquire(ctx, path, exclusive, host, 0)
}

func acquire(ctx context.Context, path string, exclusive bool, host string, owner uint32) (*Lease, error) {
	return acquireLease(ctx, path, exclusive, host, owner, true)
}

// JoinExisting takes a shared lease on an existing protected lock. Unlike
// Acquire, it never creates a lock file or directory and opens the file read-only.
func JoinExisting(ctx context.Context, path string) (*Lease, error) {
	host, err := os.Hostname()
	if err != nil {
		return nil, err
	}
	return joinExisting(ctx, path, host, 0)
}

func joinExisting(ctx context.Context, path, host string, owner uint32) (*Lease, error) {
	return acquireLease(ctx, path, false, host, owner, false)
}

func acquireLease(ctx context.Context, path string, exclusive bool, host string, owner uint32, initialize bool) (*Lease, error) {
	if !initialize {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
	initial, err := load(path, host, owner)
	if err != nil {
		return nil, err
	}
	if initialize {
		if err := os.MkdirAll(filepath.Dir(initial.LockPath), 0o700); err != nil {
			return nil, err
		}
	}
	canonical, err := filepath.EvalSymlinks(filepath.Dir(initial.LockPath))
	if err != nil || canonical != filepath.Dir(initial.LockPath) {
		return nil, errors.New("farm capacity lock parent is symlinked")
	}
	parent, err := os.Stat(canonical)
	if err != nil {
		return nil, err
	}
	parentStat, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || parentStat.Uid != owner || !parent.IsDir() || parent.Mode().Perm()&0o022 != 0 {
		return nil, errors.New("farm capacity lock parent is not protected from replacement")
	}
	flags := unix.O_RDONLY | unix.O_NOFOLLOW | unix.O_NONBLOCK | unix.O_CLOEXEC
	if initialize {
		flags = unix.O_RDWR | unix.O_CREAT | unix.O_NOFOLLOW | unix.O_NONBLOCK | unix.O_CLOEXEC
	}
	fd, err := unix.Open(initial.LockPath, flags, 0o600)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), initial.LockPath)
	keep := false
	defer func() {
		if !keep {
			file.Close()
		}
	}()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != owner || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || (!initialize && stat.Nlink != 1) {
		return nil, errors.New("farm capacity lock is not a private root-owned regular file")
	}
	operation := unix.LOCK_SH
	if exclusive {
		operation = unix.LOCK_EX
	}
	for {
		if !initialize {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
		}
		err := unix.Flock(fd, operation|unix.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, unix.EWOULDBLOCK) && !errors.Is(err, unix.EAGAIN) {
			return nil, err
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
	current, err := load(path, host, owner)
	if err != nil {
		return nil, err
	}
	if current.LockPath != initial.LockPath || current.Epoch != initial.Epoch {
		return nil, errors.New("farm capacity ownership changed while acquiring its lock")
	}
	observed, err := os.Lstat(current.LockPath)
	if err != nil || !os.SameFile(info, observed) {
		return nil, errors.New("farm capacity lock identity changed")
	}
	keep = true
	return &Lease{Config: current, file: file, path: path, owner: owner, exclusive: exclusive}, nil
}
