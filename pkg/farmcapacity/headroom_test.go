package farmcapacity

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func headroomFixture(t *testing.T) (*Controller, *fakeDocker, string) {
	t.Helper()
	c, d, id := fixture(t)
	old := c.Policy
	c.Policy.CPUAdmission = sharedcapacity.CPUAdmissionSoft
	c.Policy.BuildMemoryOvercommit = &sharedcapacity.BuildMemoryOvercommit{AdditionalMiB: 12288, MinimumAvailableMiB: 1024}
	c.Policy.SharedMemoryHeadroom = true
	if err := c.Broker.ReconcilePolicy(&old, &c.Policy); err != nil {
		t.Fatal(err)
	}
	return c, d, id
}

func TestNativeDispatchRechecksPhysicalHeadroomAfterAdmission(t *testing.T) {
	c, d, id := headroomFixture(t)
	observations := 0
	c.Broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		observations++
		available := uint64(32768)
		if observations > 1 {
			available = 1024
		}
		return sharedcapacity.MemoryObservation{AvailableMiB: available, ObservedAt: time.Now().UTC()}, nil
	}
	err := c.Start(context.Background(), testName, id)
	if !errors.Is(err, ErrQueued) || d.starts != 0 {
		t.Fatal("native dispatch bypassed the fresh memory guard", err, d.starts)
	}
}

func TestNativeStartReservationSurvivesUnknownUntilDurableRunningProof(t *testing.T) {
	c, d, id := headroomFixture(t)
	c.Broker.ObserveMemory = func() (sharedcapacity.MemoryObservation, error) {
		return sharedcapacity.MemoryObservation{AvailableMiB: 32768, ObservedAt: time.Now().UTC()}, nil
	}
	d.startErr = errors.New("unknown Docker start outcome")
	if err := c.Start(context.Background(), testName, id); err == nil {
		t.Fatal("unknown start reported success")
	}
	before, err := c.Broker.Status(&c.Policy)
	if err != nil {
		t.Fatal(err)
	}
	start := before.Starts["build:"+testName]
	if start.MemoryMiB != 12288 || start.Started {
		t.Fatal("unknown start lost reservation")
	}
	d.startErr = nil
	if err := c.Start(context.Background(), testName, id); err != nil {
		t.Fatal(err)
	}
	if err := c.ConfirmStarted(context.Background(), testName, id); err == nil {
		t.Fatal("start confirmed before registration receipt")
	}
	if err := c.RecordRegistration(testName, id, 42, "host-"+testName); err != nil {
		t.Fatal(err)
	}
	d.inspectErr = errors.New("unknown execution")
	if err := c.ConfirmStarted(context.Background(), testName, id); err == nil {
		t.Fatal("unknown running proof cleared charge")
	}
	d.inspectErr = nil
	d.containers[id].Paused = true
	if err := c.ConfirmStarted(context.Background(), testName, id); err == nil {
		t.Fatal("paused execution cleared charge")
	}
	after, err := c.Broker.Status(&c.Policy)
	if err != nil || after.Starts["build:"+testName] != start {
		t.Fatal("failed proofs changed reservation", err)
	}
	d.containers[id].Paused = false
	if err := c.ConfirmStarted(context.Background(), testName, id); err != nil {
		t.Fatal(err)
	}
	after, err = c.Broker.Status(&c.Policy)
	if err != nil || !after.Starts["build:"+testName].Started || after.Starts["build:"+testName].MemoryMiB != 0 {
		t.Fatal("durable running proof did not settle start", err)
	}
	if after.Grants["build:"+testName] != before.Grants["build:"+testName] {
		t.Fatal("confirmation changed existing grant")
	}
}
