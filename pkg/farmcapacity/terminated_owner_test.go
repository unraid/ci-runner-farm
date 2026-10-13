// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestNativeTerminationRequiresCompleteClosedState(t *testing.T) {
	for _, mode := range []string{"closed", "live-owner", "paused-owner", "restarting", "automatic-restart", "live-pid", "created-owner", "missing-running", "missing-paused", "missing-restarting", "pid-omitted", "missing-restart-policy"} {
		t.Run(mode, func(t *testing.T) {
			zero := 0
			no := false
			yes := true
			policy := "no"
			status := testExitedStatus
			pid := &zero
			running, paused, restarting := &no, &no, &no
			restartPolicy := &policy
			switch mode {
			case "live-owner":
				running = &yes
			case "paused-owner":
				paused = &yes
			case "restarting":
				restarting = &yes
			case "automatic-restart":
				policy = "always"
			case "live-pid":
				zero = 123
			case "created-owner":
				status = nativeCreatedStatus
			case "missing-running":
				running = nil
			case "missing-paused":
				paused = nil
			case "missing-restarting":
				restarting = nil
			case "pid-omitted":
				pid = nil
			case "missing-restart-policy":
				restartPolicy = nil
			}
			if got := terminatedNative(status, pid, running, paused, restarting, restartPolicy); got != (mode == "closed") {
				t.Fatal("incomplete or live Docker state established terminal removal")
			}
		})
	}
}

func terminalFixture(t *testing.T) (owner *FrozenOwner, directory string) {
	t.Helper()
	id := strings.Repeat("a", 64)
	directory = installExitedRegistrationFixture(t, id, testExitedStatus, false, 0, "unused", "test-org")
	data, err := os.ReadFile(filepath.Join(directory, "inspect"))
	if err != nil {
		t.Fatal(err)
	}
	var inspected []map[string]any
	if err = json.Unmarshal(data, &inspected); err != nil {
		t.Fatal(err)
	}
	state, ok := inspected[0]["State"].(map[string]any)
	if !ok {
		t.Fatal("native fixture state is not an object")
	}
	state["Paused"] = false
	state["Restarting"] = false
	policy := struct {
		Name string `json:"Name"`
	}{Name: "no"}
	inspected[0]["HostConfig"] = map[string]any{"RestartPolicy": policy}
	data, err = json.Marshal(inspected)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(directory, "inspect"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	return &FrozenOwner{ID: id, Name: testName}, directory
}

func TestNativeTerminalRemovalNeverForcesARestartedContainer(t *testing.T) {
	for _, restarted := range []bool{false, true} {
		t.Run(strconv.FormatBool(restarted), func(t *testing.T) {
			owner, directory := terminalFixture(t)
			original, err := os.ReadFile(filepath.Join(directory, "docker"))
			if err != nil {
				t.Fatal(err)
			}
			// The restart wins after the final inspect: non-forced Docker removal
			// refuses the now-running owner. Record exact argv to detect --force.
			script := "#!/bin/sh\nif [ \"$1\" = rm ]; then\n printf '%s\\n' \"$@\" > " + strconv.Quote(filepath.Join(directory, "remove-argv")) + "\n"
			if restarted {
				script += " exit 1\n"
			} else {
				script += ": > " + strconv.Quote(filepath.Join(directory, "listing")) + "\n exit 0\n"
			}
			script += "fi\n" + string(original)
			root, openErr := os.OpenRoot(directory)
			if openErr != nil {
				t.Fatal(openErr)
			}
			defer func() {
				if closeErr := root.Close(); closeErr != nil {
					t.Error(closeErr)
				}
			}()
			if err = root.WriteFile("docker", []byte(script), 0o600); err != nil {
				t.Fatal(err)
			}
			err = owner.RemoveTerminated(context.Background())
			if (err != nil) != restarted {
				t.Fatal("terminal restart race was not retained")
			}
			argv, readErr := os.ReadFile(filepath.Join(directory, "remove-argv"))
			if readErr != nil {
				t.Fatal(readErr)
			}
			if string(argv) != "rm\n"+owner.ID+"\n" {
				t.Fatal("terminal owner removal used a force or mutable-name target")
			}
		})
	}
}

func TestNativeTerminalProofRejectsReplacedIdentity(t *testing.T) {
	owner, directory := terminalFixture(t)
	if err := os.WriteFile(filepath.Join(directory, "listing"), []byte(strings.Repeat("b", 64)+"|"+testName+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if terminal, err := owner.Terminated(t.Context()); terminal || err == nil {
		t.Fatal("same-name replacement supplied terminal proof")
	}
	if err := owner.RemoveTerminated(t.Context()); err == nil {
		t.Fatal("same-name replacement authorized removal")
	}
}

type terminalPlanningOwner struct{ *fakePlanningOwner }

func (o *terminalPlanningOwner) Terminated(ctx context.Context) (bool, error) {
	item, err := o.docker.Inspect(ctx, o.id)
	if err != nil {
		return false, err
	}
	return item.Terminated, nil
}

func (o *terminalPlanningOwner) RemoveTerminated(ctx context.Context) error {
	return o.RemoveFrozen(ctx)
}

func TestCompletedNativeOwnerReleasesItsExactGrantInOnePass(t *testing.T) {
	controller, docker, id := fixture(t)
	if err := controller.Start(t.Context(), testName, id); err != nil {
		t.Fatal(err)
	}
	docker.containers[id].Running = false
	docker.containers[id].Exited = true
	docker.containers[id].Terminated = true
	owner := &terminalPlanningOwner{fakePlanningOwner: &fakePlanningOwner{docker: docker, id: id}}
	if err := controller.Withdraw(t.Context(), testName, id, owner, 123, testName, controller.now()); err != nil {
		t.Fatal(err)
	}
	after, err := controller.Broker.Status(&controller.Policy)
	if err != nil || len(after.Grants) != 0 || docker.containers[id] != nil {
		t.Fatal("completed native owner retained charged capacity")
	}
}
