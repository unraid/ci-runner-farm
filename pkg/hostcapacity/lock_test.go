package hostcapacity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSharedConsumersExcludePolicyMutation(t *testing.T) {
	root := testRoot(t)
	path := filepath.Join(root, "host-capacity.json")
	writeConfig(t, path, testConfig(root))
	owner := uint32(os.Geteuid())
	first, err := acquire(context.Background(), path, false, "test-host", owner)
	if err != nil {
		t.Fatal(err)
	}
	second, err := acquire(context.Background(), path, false, "test-host", owner)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if lease, err := acquire(ctx, path, true, "test-host", owner); !errors.Is(err, context.DeadlineExceeded) || lease != nil {
		t.Fatal("policy writer crossed active consumer leases", err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}
	writer, err := acquire(context.Background(), path, true, "test-host", owner)
	if err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestLockRejectsReplacementAndSymlinks(t *testing.T) {
	for _, symlink := range []bool{false, true} {
		root := testRoot(t)
		config := testConfig(root)
		path := filepath.Join(root, "host-capacity.json")
		writeConfig(t, path, config)
		lease, err := acquire(context.Background(), path, false, "test-host", uint32(os.Geteuid()))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(config.LockPath, config.LockPath+".old"); err != nil {
			t.Fatal(err)
		}
		if symlink {
			if err := os.Symlink(config.LockPath+".old", config.LockPath); err != nil {
				t.Fatal(err)
			}
		} else if err := os.WriteFile(config.LockPath, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if other, err := acquire(context.Background(), path, false, "test-host", uint32(os.Geteuid())); err == nil || other != nil {
			t.Fatal("unsafe replacement lock was accepted")
		}
		if err := lease.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLockRejectsWritableParent(t *testing.T) {
	root := testRoot(t)
	config := testConfig(root)
	path := filepath.Join(root, "host-capacity.json")
	writeConfig(t, path, config)
	if err := os.MkdirAll(filepath.Dir(config.LockPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Dir(config.LockPath), 0o777); err != nil {
		t.Fatal(err)
	}
	if lease, err := acquire(context.Background(), path, false, "test-host", uint32(os.Geteuid())); err == nil || lease != nil {
		t.Fatal("a participant could use a lock whose directory permits replacement")
	}
}
