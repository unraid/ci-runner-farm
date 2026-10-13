// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

const queuedBuilderSix = "ci-runner-build-6"

func (d *fakeDocker) RemoveCreated(_ context.Context, id string) error {
	item := d.containers[id]
	if item == nil || !item.NeverStarted || item.Running {
		return errors.New("not inert")
	}
	delete(d.containers, id)
	return nil
}

func TestQueuedCredentialReplacementPreservesAgeAcrossCrash(t *testing.T) {
	c, owners, _, now := pressureFixture(t)
	id := strings.Repeat("e", 64)
	name := queuedBuilderSix
	docker, ok := c.Docker.(*fakeDocker)
	if !ok {
		t.Fatal("fixture Docker owner differs")
	}
	docker.containers[id] = &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix()}
	if err := c.Start(context.Background(), name, id); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	before, statusErr := c.Broker.Status(&c.Policy)
	if statusErr != nil {
		t.Fatal(statusErr)
	}
	*now = now.Add(time.Hour)
	if err := c.Start(context.Background(), name, id); !errors.Is(err, ErrCredentialsExpired) {
		t.Fatal(err)
	}
	if err := c.PrepareQueuedReplacement(context.Background(), name, id); err != nil {
		t.Fatal(err)
	}
	// Retry after a crash between native removal and fresh creation.
	if err := c.PrepareQueuedReplacement(context.Background(), name, id); err != nil {
		t.Fatal(err)
	}
	replacement := strings.Repeat("f", 64)
	docker.containers[replacement] = &Container{ID: replacement, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix()}
	if err := c.Start(context.Background(), name, replacement); !errors.Is(err, ErrQueued) {
		t.Fatal(err)
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	if !before.Pending["build:"+name].QueuedAt.Equal(after.Pending["build:"+name].QueuedAt) {
		t.Fatal("replacement reset stable demand age")
	}
	if len(after.Grants) != len(owners) || docker.starts != len(owners) {
		t.Fatal("queued replacement started or changed existing grants")
	}
	owned, err := c.load(name)
	if err != nil || owned.ID != replacement || owned.ReplacementPrepared {
		t.Fatal("replacement did not bind the new immutable owner")
	}
}

func TestQueuedReplacementRejectsChargedStartedOrUnknownOwners(t *testing.T) {
	for _, mode := range []string{"charged", "started", "unknown"} {
		c, _, _, now := pressureFixture(t)
		docker, ok := c.Docker.(*fakeDocker)
		if !ok {
			t.Fatal("fixture Docker owner differs")
		}
		id := strings.Repeat("e", 64)
		name := queuedBuilderSix
		item := &Container{ID: id, Name: name, Managed: true, Provider: githubProvider, Role: runnerRole, Pool: buildPool, MemoryBytes: 12288 * 1024 * 1024, NanoCPUs: 1_000_000_000, NeverStarted: true, RoutingGated: true, RegistrationIssuedAt: now.Unix()}
		docker.containers[id] = item
		if err := c.Start(context.Background(), name, id); !errors.Is(err, ErrQueued) {
			t.Fatal(err)
		}
		switch mode {
		case "charged":
			owned, err := c.load(name)
			if err != nil {
				t.Fatal(err)
			}
			owned.Fence = "uncertain"
			if err := c.save(name, owned); err != nil {
				t.Fatal(err)
			}
		case "started":
			item.NeverStarted = false
		case "unknown":
			docker.inspectErr = errors.New("daemon unavailable")
		}
		if err := c.PrepareQueuedReplacement(context.Background(), name, id); err == nil {
			t.Fatal(mode + " owner was replaced")
		}
		if docker.containers[id] == nil {
			t.Fatal("uncertain owner was removed")
		}
	}
}
