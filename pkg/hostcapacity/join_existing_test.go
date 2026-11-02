package hostcapacity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestJoinExistingNeverInitializesLeasePaths(t *testing.T) {
	for _, missing := range []string{"parent", "file"} {
		t.Run(missing, func(t *testing.T) {
			root := testRoot(t)
			config := testConfig(root)
			config.LockPath = filepath.Join(root, "selected-lock", "policy.lock")
			path := filepath.Join(root, "host-capacity.json")
			writeConfig(t, path, config)
			if missing == "file" {
				if err := os.Mkdir(filepath.Dir(config.LockPath), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			lease, err := joinExisting(t.Context(), path, "test-host", uint32(os.Geteuid()))
			if err == nil || lease != nil {
				t.Fatal("missing lease was initialized")
			}
			if _, err := os.Lstat(config.LockPath); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("read created lock file", err)
			}
			if missing == "parent" {
				if _, err := os.Lstat(filepath.Dir(config.LockPath)); !errors.Is(err, os.ErrNotExist) {
					t.Fatal("read created lock parent", err)
				}
			}
			after, _ := os.ReadFile(path)
			if string(before) != string(after) {
				t.Fatal("read changed configuration")
			}
		})
	}
}
func TestJoinExistingIsReadOnlyAndCannotActivate(t *testing.T) {
	root := testRoot(t)
	config := testConfig(root)
	path := filepath.Join(root, "host-capacity.json")
	writeConfig(t, path, config)
	initialized, err := acquire(t.Context(), path, false, "test-host", uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	if err = initialized.Close(); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(config.LockPath, []byte("retained"), 0o600); err != nil {
		t.Fatal(err)
	}
	lease, err := joinExisting(t.Context(), path, "test-host", uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	flags, err := unix.FcntlInt(lease.file.Fd(), unix.F_GETFL, 0)
	if err != nil || flags&unix.O_ACCMODE != unix.O_RDONLY {
		t.Fatal("join did not open read-only", flags, err)
	}
	if _, err := lease.file.Write([]byte("forbidden")); err == nil {
		t.Fatal("read-only lease was writable")
	}
	if err := lease.Activate(); err == nil {
		t.Fatal("shared read-only lease gained writer authority")
	}
	raw, _ := os.ReadFile(config.LockPath)
	if string(raw) != "retained" {
		t.Fatal("read changed lock contents")
	}
}
func TestJoinExistingPreservesExclusiveWaitAndCancellation(t *testing.T) {
	root := testRoot(t)
	config := testConfig(root)
	path := filepath.Join(root, "host-capacity.json")
	writeConfig(t, path, config)
	writer, err := acquire(t.Context(), path, true, "test-host", uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Millisecond)
	defer cancel()
	if lease, err := joinExisting(ctx, path, "test-host", uint32(os.Geteuid())); !errors.Is(err, context.DeadlineExceeded) || lease != nil {
		t.Fatal("read crossed exclusive writer", err)
	}
	if err = writer.Close(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel = context.WithCancel(t.Context())
	cancel()
	if lease, err := joinExisting(ctx, path, "test-host", uint32(os.Geteuid())); !errors.Is(err, context.Canceled) || lease != nil {
		t.Fatal("cancelled read acquired lease", err)
	}
}

type leaseWaitContext struct {
	context.Context
	waiting chan struct{}
	once    sync.Once
}

func (c *leaseWaitContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.waiting) })
	return c.Context.Done()
}
func TestJoinExistingRejectsEpochAndLockReplacementWhileWaiting(t *testing.T) {
	for _, kind := range []string{"epoch", "lock"} {
		t.Run(kind, func(t *testing.T) {
			root := testRoot(t)
			config := testConfig(root)
			path := filepath.Join(root, "host-capacity.json")
			writeConfig(t, path, config)
			writer, err := acquire(t.Context(), path, true, "test-host", uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			defer writer.Close()
			parent, cancel := context.WithTimeout(t.Context(), time.Second)
			defer cancel()
			ctx := &leaseWaitContext{Context: parent, waiting: make(chan struct{})}
			result := make(chan error, 1)
			go func() {
				lease, err := joinExisting(ctx, path, "test-host", uint32(os.Geteuid()))
				if lease != nil {
					_ = lease.Close()
				}
				result <- err
			}()
			select {
			case <-ctx.waiting:
			case <-parent.Done():
				t.Fatal("join did not reach existing locked inode")
			}
			if kind == "epoch" {
				config.Epoch = "22222222222222222222222222222222"
				writeConfig(t, path, config)
			} else {
				if err = os.Rename(config.LockPath, config.LockPath+".old"); err != nil {
					t.Fatal(err)
				}
				if err = os.WriteFile(config.LockPath, nil, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if err = writer.Close(); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-result:
				if err == nil {
					t.Fatal("changed lease admitted")
				}
			case <-parent.Done():
				t.Fatal("join did not retire")
			}
		})
	}
}
func TestJoinExistingRejectsUnsafeOrSymlinkedLock(t *testing.T) {
	for _, kind := range []string{"parent", "mode", "symlink", "hardlink"} {
		t.Run(kind, func(t *testing.T) {
			root := testRoot(t)
			config := testConfig(root)
			path := filepath.Join(root, "host-capacity.json")
			writeConfig(t, path, config)
			first, err := acquire(t.Context(), path, false, "test-host", uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			_ = first.Close()
			switch kind {
			case "parent":
				err = os.Chmod(filepath.Dir(config.LockPath), 0o777)
			case "mode":
				err = os.Chmod(config.LockPath, 0o644)
			case "symlink":
				err = os.Rename(config.LockPath, config.LockPath+".old")
				if err == nil {
					err = os.Symlink(config.LockPath+".old", config.LockPath)
				}
			case "hardlink":
				err = os.Link(config.LockPath, filepath.Join(t.TempDir(), "alias"))
			}
			if err != nil {
				t.Fatal(err)
			}
			if lease, err := joinExisting(t.Context(), path, "test-host", uint32(os.Geteuid())); err == nil || lease != nil {
				t.Fatal("unsafe existing lease accepted")
			}
		})
	}
}
