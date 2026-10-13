// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestPoisonMaintenancePersistsAcrossMarkerLossAndCacheFailure(t *testing.T) {
	c, owners, bind, now := pressureFixtureCount(t, 4)
	native, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("expected fake Docker")
	}
	id := strings.Repeat("1", 64)
	name := "ci-runner-build-1"
	native.containers[id].DockerRoot = "/mnt/data/cache/docker/" + name
	c.Poisoned = func(_, candidate string) (bool, error) { return candidate == id, nil }
	repaired := false
	c.RepairCache = func(context.Context, string, string) error {
		if !owners[id].gone || native.containers[id] != nil {
			t.Fatal("cache repaired before owned removal")
		}
		if !repaired {
			return errors.New("cache unavailable")
		}
		return nil
	}
	if err := c.Rebalance(context.Background(), bind); !errors.Is(err, sharedcapacity.ErrWithdrawalWaiting) {
		t.Fatal(err)
	}
	owned, err := c.load(name)
	if err != nil || !owned.Maintenance || owned.DockerRoot == "" {
		t.Fatal("repair intent was not durable")
	}
	// Restart with the same durable state, after the transient flag disappears.
	restarted := *c
	restarted.Poisoned = func(string, string) (bool, error) { return false, nil }
	*now = now.Add(80 * time.Second)
	if rebalanceErr := restarted.Rebalance(context.Background(), bind); rebalanceErr == nil {
		t.Fatal("cache failure released allocation")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 4 {
		t.Fatal("uncertain repair lost its charge")
	}
	repaired = true
	if rebalanceErr := restarted.Rebalance(context.Background(), bind); rebalanceErr != nil {
		t.Fatal(rebalanceErr)
	}
	snapshot, err = c.Broker.Status(&c.Policy)
	if err != nil || len(snapshot.Grants) != 3 {
		t.Fatal("completed maintenance did not release exact owner")
	}
	if _, loadErr := c.load(name); loadErr == nil {
		t.Fatal("finished receipt remains")
	}
}

func TestPoisonMaintenancePreservesBusyAndUnknownOwners(t *testing.T) {
	for _, unknown := range []bool{false, true} {
		c, owners, bind, _ := pressureFixtureCount(t, 4)
		native, ok := c.Docker.(*fakeDocker)
		if !ok {
			t.Fatal("expected fake Docker")
		}
		id := strings.Repeat("1", 64)
		owners[id].busy = !unknown
		owners[id].unknown = unknown
		c.Poisoned = func(_, candidate string) (bool, error) { return candidate == id, nil }
		if rebalanceErr := c.Rebalance(context.Background(), bind); rebalanceErr == nil {
			t.Fatal("busy or unknown owner accepted for withdrawal")
		}
		if owners[id].gone || native.containers[id] == nil {
			t.Fatal("busy/unknown owner removed")
		}
		snapshot, err := c.Broker.Status(&c.Policy)
		if err != nil || len(snapshot.Grants) != 4 {
			t.Fatal("busy/unknown charge lost")
		}
	}
}

func TestCacheOverlapIncludesAncestorsAndDescendants(t *testing.T) {
	root := "/mnt/data/cache/docker/ci-runner-build-1"
	for _, source := range []string{root, root + "/buildkit", "/mnt/data", "/"} {
		if !overlapsCache(root, source) {
			t.Fatal("overlapping writer accepted", source)
		}
	}
	for _, source := range []string{"", "volume-name", root + "-other", "/mnt/other"} {
		if overlapsCache(root, source) {
			t.Fatal("unrelated writer rejected", source)
		}
	}
}

func TestPoisonMarkerRejectsSymlinkAndUncertainFile(t *testing.T) {
	id := strings.Repeat("1", 64)
	path := filepath.Join(t.TempDir(), "marker")
	if writeErr := os.WriteFile(path, []byte(id+"\n"), 0o600); writeErr != nil {
		t.Fatal(writeErr)
	}
	if poisoned, readErr := readNativePoisonMarker(path, id); readErr != nil || !poisoned {
		t.Fatal("exact marker not accepted", readErr)
	}
	if poisoned, readErr := readNativePoisonMarker(path, strings.Repeat("2", 64)); readErr != nil || poisoned {
		t.Fatal("stale marker accepted", readErr)
	}
	link := path + "-link"
	if linkErr := os.Symlink(path, link); linkErr != nil {
		t.Fatal(linkErr)
	}
	if _, readErr := readNativePoisonMarker(link, id); readErr == nil {
		t.Fatal("symlink marker accepted")
	}
	if _, readErr := readNativePoisonMarker(filepath.Dir(path), id); readErr == nil {
		t.Fatal("directory marker accepted")
	}
	if writeErr := os.WriteFile(path, []byte(strings.Repeat("x", 67)), 0o600); writeErr != nil {
		t.Fatal(writeErr)
	}
	if _, readErr := readNativePoisonMarker(path, id); readErr == nil {
		t.Fatal("oversized marker accepted")
	}
	if poisoned, readErr := readNativePoisonMarker(path+"-absent", id); readErr != nil || poisoned {
		t.Fatal("absent marker not inert", readErr)
	}
}

func TestNativeCacheRejectsUnsafeRootsBeforeEffects(t *testing.T) {
	for _, root := range []string{"", "/", "/mnt/data/docker/another-owner", "/mnt/data/docker/../ci-runner-build-1", "relative/docker/ci-runner-build-1"} {
		if repairErr := RepairNativeCache(context.Background(), "ci-runner-build-1", root); repairErr == nil {
			t.Fatal("unsafe root accepted", root)
		}
	}
}
