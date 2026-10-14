package hostcapacity

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestActivationRequiresExclusiveLiveUnchangedClosedOwner(t *testing.T) {
	root := testRoot(t)
	path := filepath.Join(root, "host-capacity.json")
	config := testConfig(root)
	config.Mode = "closed"
	writeConfig(t, path, config)
	owner := uint32(os.Geteuid())
	reader, err := acquire(t.Context(), path, false, config.Host, owner)
	if err != nil {
		t.Fatal(err)
	}
	if err := reader.Activate(); err == nil {
		t.Fatal("shared consumer activated the owner")
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	writer, err := acquire(t.Context(), path, true, config.Host, owner)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	if err := writer.Activate(); err != nil {
		t.Fatal(err)
	}
	actual, err := load(path, config.Host, owner)
	config.Mode = "active"
	if err != nil || !reflect.DeepEqual(actual, &config) {
		t.Fatal("activation changed the policy or identity", actual, err)
	}
}

func TestActivationRejectsChangedPolicyAndClosedLease(t *testing.T) {
	root := testRoot(t)
	path := filepath.Join(root, "host-capacity.json")
	config := testConfig(root)
	config.Mode = "closed"
	writeConfig(t, path, config)
	writer, err := acquire(context.Background(), path, true, config.Host, uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	config.Organization = "changed-org"
	writeConfig(t, path, config)
	if err := writer.Activate(); err == nil {
		t.Fatal("changed owner was activated")
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := writer.Activate(); err == nil {
		t.Fatal("closed lease retained activation authority")
	}
}

func TestActivationRejectsReplacedLockIdentity(t *testing.T) {
	root := testRoot(t)
	path := filepath.Join(root, "host-capacity.json")
	config := testConfig(root)
	config.Mode = "closed"
	writeConfig(t, path, config)
	writer, err := acquire(t.Context(), path, true, config.Host, uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	if err := os.Rename(config.LockPath, config.LockPath+".old"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(config.LockPath, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writer.Activate(); err == nil {
		t.Fatal("detached lock retained policy publication authority")
	}
}
