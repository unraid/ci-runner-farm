package farmcapacity

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestStandaloneInitializationChargesBusyInventoryAndRetainsFences(t *testing.T) {
	c, docker, id := fixture(t)
	c.Broker.Path = filepath.Join(t.TempDir(), "standalone.bolt")
	docker.containers[id].Running = true
	if err := c.InitializeStandalone(t.Context()); err != nil {
		t.Fatal(err)
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil || len(before.Grants) != 1 || docker.starts != 0 {
		t.Fatal(before, err)
	}
	if err := c.InitializeStandalone(t.Context()); err != nil {
		t.Fatal(err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || !reflect.DeepEqual(before, after) || docker.starts != 0 {
		t.Fatal("initialization changed live ownership", err)
	}
	owned, err := c.load(testName)
	if err != nil || owned.ID != id || owned.Fence != before.Grants["build:"+testName].Fence {
		t.Fatal("initialization did not persist the exact owner fence", err)
	}
}

type changingInitializationDocker struct {
	*fakeDocker
	observations int
}

func (d *changingInitializationDocker) Owned(ctx context.Context) ([]Container, error) {
	d.observations++
	if d.observations > 1 {
		return nil, errors.New("inventory became unavailable")
	}
	return d.fakeDocker.Owned(ctx)
}

func TestStandaloneInitializationRejectsIncompleteInventoryAndConsumerClasses(t *testing.T) {
	c, docker, _ := fixture(t)
	c.Broker.Path = filepath.Join(t.TempDir(), "standalone.bolt")
	c.Docker = &changingInitializationDocker{fakeDocker: docker}
	if err := c.InitializeStandalone(t.Context()); err == nil {
		t.Fatal("changed inventory was initialized")
	}
	if _, err := c.Broker.Status(&c.Policy); !errors.Is(err, sharedcapacity.ErrUninitialized) {
		t.Fatal("failed inventory committed ownership", err)
	}
	c.Policy.Pools["qa"] = c.Policy.Pools[buildPool]
	if err := c.InitializeStandalone(t.Context()); err == nil {
		t.Fatal("standalone initializer accepted a consumer")
	}
}
