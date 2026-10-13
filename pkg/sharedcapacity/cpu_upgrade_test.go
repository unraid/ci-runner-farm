package sharedcapacity

import (
	"reflect"
	"testing"
)

func TestDefaultCPUIncreaseKeepsChargedOwnersAndNewFloor(t *testing.T) {
	old := selectedBuildPolicy()
	pool := old.Pools[buildPool]
	pool.Cost.VCPUs = 1
	old.Pools[buildPool] = pool
	b := newBroker(t, &old)
	first := requireGrant(t, b, &old, standardFloorOne, buildPool)
	revised := selectedBuildPolicy()
	before, err := b.Status(&old)
	if err != nil {
		t.Fatal(err)
	}
	if err = b.CheckPolicyChange(&old, &revised); err != nil {
		t.Fatal(err)
	}
	if err = b.ReconcilePolicy(&old, &revised); err != nil {
		t.Fatal(err)
	}
	restarted := &Broker{Path: b.Path}
	after, err := restarted.Status(&revised)
	if err != nil || !reflect.DeepEqual(before.Grants, after.Grants) {
		t.Fatal("CPU increase changed a charged owner", err)
	}
	if replay := requireGrant(t, restarted, &revised, standardFloorOne, buildPool); replay != first {
		t.Fatal("replay changed immutable allocation")
	}
	if _, err := restarted.Admit(&revised, Request{ID: standardFloorTwo, Pool: buildPool, Resources: first.Cost}); err == nil {
		t.Fatal("new floor accepted old CPU cost")
	}
	next := requireGrant(t, restarted, &revised, standardFloorTwo, buildPool)
	if next.Cost.VCPUs != 4 {
		t.Fatal("new builder did not receive four CPUs")
	}
	releaseGrant(t, restarted, &revised, &first)
	if replacement := requireGrant(t, restarted, &revised, standardFloorOne, buildPool); replacement.Cost.VCPUs != 4 || replacement.Fence == first.Fence {
		t.Fatal("replacement reused old allocation")
	}
}
