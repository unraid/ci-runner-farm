//go:build unix

package sharedcapacity

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// This fixture is an actual local process, not Docker, QEMU, or host cgroup
// qualification. Its private process group cannot contain a peer workload.
func TestInterchangeableProcessFixture(t *testing.T) {
	if os.Getenv("FARM_INTERCHANGEABLE_PROCESS_FIXTURE") != "1" {
		return
	}
	fmt.Println("ready")
	_, _ = io.Copy(io.Discard, os.Stdin)
	os.Exit(0)
}

func startInterchangeableProcess(t *testing.T) (*exec.Cmd, func()) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	t.Cleanup(cancel)
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestInterchangeableProcessFixture$")
	command.Env = append(os.Environ(), "FARM_INTERCHANGEABLE_PROCESS_FIXTURE=1")
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	stopped := false
	stop := func() {
		if stopped {
			return
		}
		stopped = true
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
		_ = input.Close()
		_ = command.Wait()
	}
	t.Cleanup(stop)
	if line, err := bufio.NewReader(output).ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("fixture readiness: %q %v", line, err)
	}
	return command, stop
}

func TestInterchangeableWorkerLocalChildFailureCannotReleaseLiveListener(t *testing.T) {
	policy := interchangeablePolicy()
	broker := newBroker(t, &policy)
	grant := requireGrant(t, broker, &policy, "local-process-owner", "worker")
	listener, stopListener := startInterchangeableProcess(t)
	child, stopChild := startInterchangeableProcess(t)
	stopChild()
	if child.ProcessState == nil {
		t.Fatal("failed child was not reaped")
	}
	proveStopped := func(Grant) error {
		if listener.ProcessState == nil {
			if err := listener.Process.Signal(syscall.Signal(0)); err != nil {
				return fmt.Errorf("listener state is unknown: %w", err)
			}
			return errors.New("listener survived child failure")
		}
		return nil
	}
	if err := broker.Release(&policy, grant.ID, grant.Fence, proveStopped); err == nil {
		t.Fatal("actual child exit released actual live listener")
	}
	snapshot, err := broker.Status(&policy)
	if err != nil || snapshot.Grants[grant.ID] != grant {
		t.Fatal("listener fence or charge lost", err)
	}
	stopListener()
	if err := broker.Release(&policy, grant.ID, grant.Fence, proveStopped); err != nil {
		t.Fatal("reaped listener prevented exact fenced release", err)
	}
}
