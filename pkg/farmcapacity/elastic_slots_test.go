// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"testing"
)

// Exercise the native owner lifecycle, not just the shell pool parser.
func TestElasticClassMultiDigitSlotLifecycle(t *testing.T) {
	for _, name := range []string{"ci-runner-build-small-9", "ci-runner-build-small-24", "ci-runner-build-small-64"} {
		t.Run(name, func(t *testing.T) {
			c, d, id := fixture(t)
			item := d.containers[id]
			item.Name = name
			item.Pool = smallClassPool
			item.MemoryBytes = 4096 * 1024 * 1024
			if err := c.Start(context.Background(), name, id); err != nil {
				t.Fatal(err)
			}
			adopted, err := c.AdoptionRequests([]Container{*item})
			if err != nil {
				t.Fatal(err)
			}
			if checkErr := c.Broker.Adopt(&c.Policy, adopted, func() error { return nil }); checkErr != nil {
				t.Fatal(checkErr)
			}
			snapshot, err := c.Broker.Status(&c.Policy)
			if err != nil {
				t.Fatal(err)
			}
			grant := snapshot.Grants["build:"+name]
			if grant.Cost.MemoryMiB != 4096 || grant.Cost.VCPUs != 1 || grant.Fence == "" {
				t.Fatal("native slot lost exact allocation")
			}
			delete(d.containers, id)
			if checkErr := c.Release(context.Background(), name, id); checkErr != nil {
				t.Fatal(checkErr)
			}
			snapshot, err = c.Broker.Status(&c.Policy)
			if err != nil {
				t.Fatal(err)
			}
			if len(snapshot.Grants) != 0 || len(snapshot.Pending) != 0 {
				t.Fatal("native release retained allocation")
			}
		})
	}
}

func TestElasticSlotBoundsAndPoolBinding(t *testing.T) {
	for _, name := range []string{"ci-runner-build-small-0", "ci-runner-build-small-09", "ci-runner-build-small-65", "ci-runner-build-small-100", "ci-runner-build-small-24/"} {
		c, d, id := fixture(t)
		item := d.containers[id]
		item.Name = name
		item.Pool = smallClassPool
		item.MemoryBytes = 4096 * 1024 * 1024
		if err := c.Start(context.Background(), name, id); err == nil {
			t.Fatalf("accepted invalid slot %q", name)
		}
		if item.Running {
			t.Fatalf("started invalid slot %q", name)
		}
	}
	if ownedBuildPool("build-small", "ci-runner-build-large-24") || ownedBuildPool("build", "ci-runner-build-small-24") {
		t.Fatal("multi-digit slot accepted foreign pool")
	}
}
