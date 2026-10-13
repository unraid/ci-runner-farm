package sharedcapacity

import (
	"errors"
	"fmt"
	"path/filepath"
	"testing"
)

func TestAdoptBusyWorkloadsIsAtomicAndPreservesFences(t *testing.T) {
	policy := hostPolicy()
	broker := Broker{Path: filepath.Join(t.TempDir(), "admission.db")}
	if err := broker.Initialize(&policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	workloads := []Request{}
	for index := range 8 {
		workloads = append(workloads, Request{ID: fmt.Sprintf("build-%d", index), Pool: buildPool})
	}
	if err := broker.Adopt(&policy, workloads, func() error { return errors.New("owner inventory changed") }); err == nil {
		t.Fatal("unattested adoption succeeded")
	}
	empty, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if len(empty.Grants) != 0 {
		t.Fatal("failed adoption committed partial grants")
	}
	if adoptionErr := broker.Adopt(&policy, workloads, func() error { return nil }); adoptionErr != nil {
		t.Fatal(adoptionErr)
	}
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if len(before.Grants) != 8 {
		t.Fatal("busy workload adoption lost an owner")
	}
	if adoptionErr := broker.Adopt(&policy, workloads, func() error { return nil }); adoptionErr != nil {
		t.Fatal(adoptionErr)
	}
	after, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	for id, grant := range before.Grants {
		if after.Grants[id].Fence != grant.Fence {
			t.Fatal("adoption retry reset a grant fence")
		}
	}
	if err := broker.Adopt(&policy, workloads[:7], func() error { return nil }); err == nil {
		t.Fatal("adoption omitted a charged owner")
	}
}

func TestAdoptRejectsOverBudgetInventoryWithoutPartialCommit(t *testing.T) {
	policy := hostPolicy()
	broker := Broker{Path: filepath.Join(t.TempDir(), "admission.db")}
	if err := broker.Initialize(&policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	workloads := []Request{}
	for index := range 9 {
		workloads = append(workloads, Request{ID: fmt.Sprintf("build-%d", index), Pool: buildPool})
	}
	if err := broker.Adopt(&policy, workloads, func() error { return nil }); err == nil {
		t.Fatal("over-budget adoption succeeded")
	}
	snapshot, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Grants) != 0 {
		t.Fatal("over-budget adoption partially committed")
	}
}

func TestAdoptionResumesExactQueuedOwnersWithoutResettingDemandOrGrants(t *testing.T) {
	policy := hostPolicy()
	broker := Broker{Path: filepath.Join(t.TempDir(), "admission.db")}
	if err := broker.Initialize(&policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	owners := []Request{}
	for i := range 8 {
		r := Request{ID: fmt.Sprintf("build-%d", i), Pool: buildPool}
		owners = append(owners, r)
		if d, err := broker.Admit(&policy, r); err != nil || !d.Admitted {
			t.Fatal(d, err)
		}
	}
	queued := Request{ID: "waiting-build", Pool: buildPool}
	if d, err := broker.Admit(&policy, queued); err != nil || d.Admitted {
		t.Fatal(d, err)
	}
	before, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	owners = append(owners, queued)
	if adoptErr := broker.Adopt(&policy, owners, func() error { return nil }); adoptErr != nil {
		t.Fatal(adoptErr)
	}
	after, err := broker.Status(&policy)
	if err != nil {
		t.Fatal(err)
	}
	if after.Pending[queued.ID] != before.Pending[queued.ID] || len(after.Grants) != 8 {
		t.Fatal("queued intent was replaced or charged")
	}
	for id, g := range before.Grants {
		if after.Grants[id] != g {
			t.Fatal("grant changed")
		}
	}
	altered := append([]Request(nil), owners...)
	altered[len(altered)-1].Pool = "qa"
	if err := broker.Adopt(&policy, altered, func() error { return nil }); err == nil {
		t.Fatal("changed pending identity accepted")
	}
	if err := broker.Adopt(&policy, owners[1:], func() error { return nil }); err == nil {
		t.Fatal("charged owner omitted")
	}
}
