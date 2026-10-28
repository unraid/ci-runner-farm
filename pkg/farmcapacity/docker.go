// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// NativeDocker uses immutable IDs and never interprets inspect failure as absence.
type NativeDocker struct{}

const (
	nativeCreatedStatus = "created"
	nativeExitedStatus  = "exited"
)

func neverStarted(status string, pid *int, startedAt *time.Time) bool {
	return status == nativeCreatedStatus && pid != nil && *pid == 0 && startedAt != nil && startedAt.IsZero()
}

// terminatedNative requires complete evidence that automatic restart and local
// execution are closed. Missing Docker fields never establish this fast path.
func terminatedNative(status string, pid *int, running, paused, restarting *bool, restartPolicy *string) bool {
	return status == nativeExitedStatus && pid != nil && *pid == 0 && running != nil && !*running &&
		paused != nil && !*paused && restarting != nil && !*restarting && restartPolicy != nil && *restartPolicy == "no"
}

func nativeFlag(value *bool) bool { return value != nil && *value }

// Inspect enumerates exact IDs/names before inspection so daemon failures fail closed.
func (NativeDocker) Inspect(ctx context.Context, identity string) (*Container, error) {
	listing, err := exec.CommandContext(ctx, "docker", "ps", "-a", "--no-trunc", "--format", "{{.ID}}|{{.Names}}").Output()
	if err != nil {
		return nil, errors.New("cannot enumerate Docker build ownership")
	}
	found := false
	for line := range strings.SplitSeq(string(listing), "\n") {
		id, name, ok := strings.Cut(line, "|")
		if ok && (id == identity || name == identity) {
			found = true
			break
		}
	}
	if !found {
		return nil, ErrContainerMissing
	}
	data, err := exec.CommandContext(ctx, "docker", "inspect", identity).Output()
	if err != nil {
		return nil, errors.New("cannot inspect Docker build ownership")
	}
	var inspected []struct {
		ID     string `json:"Id"`
		Name   string `json:"Name"`
		Config struct {
			Labels map[string]string `json:"Labels"`
			Env    []string          `json:"Env"`
		} `json:"Config"`
		HostConfig struct {
			Memory        uint64 `json:"Memory"`
			NanoCPUs      uint64 `json:"NanoCpus"`
			RestartPolicy struct {
				Name *string `json:"Name"`
			} `json:"RestartPolicy"`
		} `json:"HostConfig"`
		Mounts []struct {
			Type        string `json:"Type"`
			Source      string `json:"Source"`
			Destination string `json:"Destination"`
		} `json:"Mounts"`
		State struct {
			Running    *bool      `json:"Running"`
			Paused     *bool      `json:"Paused"`
			Restarting *bool      `json:"Restarting"`
			Status     string     `json:"Status"`
			PID        *int       `json:"Pid"`
			StartedAt  *time.Time `json:"StartedAt"`
		} `json:"State"`
	}
	if err := json.Unmarshal(data, &inspected); err != nil {
		return nil, err
	}
	if len(inspected) != 1 {
		return nil, errors.New("Docker ownership result is ambiguous")
	}
	item := &inspected[0]
	registrationName := ""
	registrationNameSeen := false
	for _, value := range item.Config.Env {
		if strings.HasPrefix(value, "RUNNER_NAME=") {
			if registrationNameSeen {
				return nil, errors.New("ambiguous native registration name")
			}
			registrationName = strings.TrimPrefix(value, "RUNNER_NAME=")
			registrationNameSeen = true
		}
	}
	labels := item.Config.Labels
	const prefix = "net.unraid.ci-runner-farm."
	issuedAt, parseErr := strconv.ParseInt(labels[prefix+"registration-issued"], 10, 64)
	if parseErr != nil {
		issuedAt = 0
	}
	routing := strings.Split(labels[prefix+"routing-labels"], ",")
	gated := routingEnvironment(item.Config.Env, routing)
	root := ""
	for _, mount := range item.Mounts {
		if mount.Type == "bind" && mount.Destination == "/var/lib/docker" {
			if root != "" {
				return nil, errors.New("ambiguous native Docker root")
			}
			root = mount.Source
		}
	}
	running := nativeFlag(item.State.Running)
	paused := nativeFlag(item.State.Paused)
	return &Container{
		Terminated:       terminatedNative(item.State.Status, item.State.PID, item.State.Running, item.State.Paused, item.State.Restarting, item.HostConfig.RestartPolicy.Name),
		RegistrationName: registrationName,
		DockerRoot:       root, ID: item.ID, Name: strings.TrimPrefix(item.Name, "/"), Managed: labels[prefix+"managed"] == "true",
		Provider: labels[prefix+"provider"], Role: labels[prefix+"role"], Pool: labels[prefix+"pool"],
		MemoryBytes: item.HostConfig.Memory, NanoCPUs: item.HostConfig.NanoCPUs, Running: running, Paused: paused, Exited: !running && !paused && item.State.Status == nativeExitedStatus && item.State.PID != nil && *item.State.PID == 0, NeverStarted: !running && !paused && neverStarted(item.State.Status, item.State.PID, item.State.StartedAt), RegistrationIssuedAt: issuedAt, RoutingLabels: routing, RoutingGated: gated,
	}, nil
}

// Start retains a grant on every failed or uncertain Docker outcome.
func (NativeDocker) Start(ctx context.Context, id string) error {
	if !idPattern.MatchString(id) {
		return errors.New("invalid immutable build container ID")
	}
	return nativeEffect(ctx, "Docker build start did not complete", "start", id)
}

// RemoveCreated refuses any container that might have started; no force or stop.
func (d NativeDocker) RemoveCreated(ctx context.Context, id string) error {
	item, err := d.Inspect(ctx, id)
	if err != nil {
		return err
	}
	if item.ID != id || !item.NeverStarted || item.Running {
		return errors.New("replacement requires an exact never-started container")
	}
	return nativeEffect(ctx, "inert native removal did not complete", "rm", id)
}

const dockerReasonLimit = 240

// nativeEffect keeps the stable failure prefix that logs match on and appends
// Docker's own reason. Daemon text is untrusted: only a bounded, single-line,
// printable excerpt is kept, and it never changes whether the effect failed.
func nativeEffect(ctx context.Context, failure string, arguments ...string) error {
	var stderr bytes.Buffer
	command := exec.CommandContext(ctx, "docker", arguments...)
	command.Stderr = &boundedWriter{buffer: &stderr, limit: 4096}
	if err := command.Run(); err != nil {
		if reason := dockerReason(stderr.String()); reason != "" {
			return fmt.Errorf("%s: %s", failure, reason)
		}
		return errors.New(failure)
	}
	return nil
}

func dockerReason(output string) string {
	reason := ""
	for line := range strings.SplitSeq(strings.ToValidUTF8(output, " "), "\n") {
		line = strings.Join(strings.FieldsFunc(line, func(r rune) bool { return unicode.IsSpace(r) || !unicode.IsPrint(r) }), " ")
		if line != "" {
			reason = strings.TrimPrefix(line, "Error response from daemon: ")
			break
		}
	}
	if len(reason) <= dockerReasonLimit {
		return reason
	}
	cut := dockerReasonLimit
	for cut > 0 && !utf8.RuneStart(reason[cut]) {
		cut--
	}
	return reason[:cut] + "..."
}

// boundedWriter keeps the first bytes of a stream and discards the rest, so a
// misbehaving daemon cannot grow broker memory or block the Docker CLI.
type boundedWriter struct {
	buffer *bytes.Buffer
	limit  int
}

func (w *boundedWriter) Write(data []byte) (int, error) {
	if room := w.limit - w.buffer.Len(); room > 0 {
		w.buffer.Write(data[:min(room, len(data))])
	}
	return len(data), nil
}

// ManagedNames lists every native managed container name without inspecting
// each one, so demand can find owners above a lowered class ceiling.
func (d NativeDocker) ManagedNames(ctx context.Context) ([]string, error) {
	const label = "net.unraid.ci-runner-farm.managed=true"
	output, err := exec.CommandContext(ctx, "docker", "ps", "-a", "--filter", "label="+label, "--format", "{{.Names}}").Output()
	if err != nil {
		return nil, errors.New("native managed names are unavailable")
	}
	names := []string{}
	for name := range strings.SplitSeq(strings.TrimSpace(string(output)), "\n") {
		if name != "" {
			names = append(names, name)
		}
	}
	return names, nil
}

// Owned includes every native managed identity, so adoption cannot miss an
// inert replacement, stopped container or unsupported managed provider.
func (d NativeDocker) Owned(ctx context.Context) ([]Container, error) {
	const label = "net.unraid.ci-runner-farm.managed=true"
	output, err := exec.CommandContext(ctx, "docker", "ps", "-a", "--no-trunc", "--filter", "label="+label, "--format", "{{.ID}}").Output()
	if err != nil {
		return nil, errors.New("native managed inventory is unavailable")
	}
	containers := []Container{}
	for id := range strings.SplitSeq(strings.TrimSpace(string(output)), "\n") {
		if id == "" {
			continue
		}
		if !idPattern.MatchString(id) {
			return nil, errors.New("native inventory identity is invalid")
		}
		item, err := d.Inspect(ctx, id)
		if err != nil {
			return nil, err
		}
		containers = append(containers, *item)
	}
	return containers, nil
}
