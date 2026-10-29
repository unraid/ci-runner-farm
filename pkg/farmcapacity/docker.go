// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
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
		InitPID: nativePID(item.State.PID), Confgen: labels[prefix+"confgen"],
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

// LocalWorkerIdentity is host-observed provenance, not a hardware certificate.
// It contains no argv, environment, mount path, credential or release capability.
type LocalWorkerIdentity struct {
	ContainerID string            `json:"containerId"`
	Name        string            `json:"name"`
	Confgen     string            `json:"confgen"`
	BootID      string            `json:"bootId"`
	InitPID     int               `json:"initPid"`
	InitBirth   string            `json:"initBirth"`
	Namespaces  map[string]string `json:"namespaces"`
}

var bootPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var confgenPattern = regexp.MustCompile(`^[0-9a-f]{12}$`)
var birthPattern = regexp.MustCompile(`^[1-9][0-9]*$`)
var namespacePattern = regexp.MustCompile(`^(pid|mnt|user|cgroup|net):\[[1-9][0-9]*\]$`)

func nativePID(pid *int) int {
	if pid == nil {
		return 0
	}
	return *pid
}

func validLocalIdentity(row *LocalWorkerIdentity) bool {
	if row == nil || !idPattern.MatchString(row.ContainerID) || !namePattern.MatchString(row.Name) || !confgenPattern.MatchString(row.Confgen) || !bootPattern.MatchString(row.BootID) || row.InitPID <= 0 || !birthPattern.MatchString(row.InitBirth) || len(row.Namespaces) != 5 {
		return false
	}
	for _, key := range []string{"pid", "mnt", "user", "cgroup", "net"} {
		value := row.Namespaces[key]
		if !strings.HasPrefix(value, key+":") || !namespacePattern.MatchString(value) {
			return false
		}
	}
	return true
}

func sameLocalIdentity(a, b *LocalWorkerIdentity) bool {
	return validLocalIdentity(a) && validLocalIdentity(b) && a.ContainerID == b.ContainerID && a.Name == b.Name && a.Confgen == b.Confgen && a.BootID == b.BootID && a.InitPID == b.InitPID && a.InitBirth == b.InitBirth && maps.Equal(a.Namespaces, b.Namespaces)
}

// ObserveLocalOwner rechecks Docker and /proc around a bounded local sample.
// Ordinary Inspect keeps its existing behavior when optional provenance is absent.
func (d NativeDocker) ObserveLocalOwner(ctx context.Context, id string) (*LocalWorkerIdentity, error) {
	return d.observeLocalOwner(ctx, id, "/proc")
}

func (d NativeDocker) observeLocalOwner(ctx context.Context, id, proc string) (*LocalWorkerIdentity, error) {
	const localEndpoint = "unix:///var/run/docker.sock"
	if endpoint := os.Getenv("DOCKER_HOST"); endpoint != "" && endpoint != localEndpoint {
		return nil, errors.New("native owner observation requires the local Docker endpoint")
	}
	// The active context may otherwise redirect plain docker inspect to another
	// machine whose PID numbers have no relationship to this host's /proc.
	endpoint, endpointErr := exec.CommandContext(ctx, "docker", "context", "inspect", "--format", `{{(index .Endpoints "docker").Host}}`).Output()
	if endpointErr != nil || strings.TrimSpace(string(endpoint)) != localEndpoint {
		return nil, errors.New("native owner local Docker endpoint is unproved")
	}

	first, err := d.Inspect(ctx, id)
	if err != nil {
		return nil, err
	}
	if first.ID != id || !first.Running || first.Paused || first.InitPID <= 0 {
		return nil, errors.New("native owner is not a stable running identity")
	}
	before, err := readLocalIdentity(first, proc)
	if err != nil {
		return nil, err
	}
	last, err := d.Inspect(ctx, id)
	if err != nil {
		return nil, err
	}
	after, err := readLocalIdentity(last, proc)
	if err != nil {
		return nil, err
	}
	if !sameLocalIdentity(before, after) || !last.Running || last.Paused || first.Managed != last.Managed || first.Provider != last.Provider || first.Role != last.Role || first.Pool != last.Pool || first.MemoryBytes != last.MemoryBytes || first.NanoCPUs != last.NanoCPUs || first.RegistrationName != last.RegistrationName {
		return nil, errors.New("native owner changed during identity observation")
	}
	return before, nil
}

func readLocalIdentity(item *Container, proc string) (*LocalWorkerIdentity, error) {
	if item == nil || item.InitPID <= 0 {
		return nil, errors.New("positive native init PID required")
	}
	// /proc stat and boot_id are kernel records; cap reads rather than following
	// arbitrary input paths. The alternate root is used only by local tests.
	read := func(path string) (string, error) {
		f, err := os.Open(path)
		if err != nil {
			return "", err
		}
		defer f.Close()
		data, err := io.ReadAll(io.LimitReader(f, 8193))
		if err != nil {
			return "", err
		}
		if len(data) > 8192 {
			return "", errors.New("kernel identity record exceeds bound")
		}
		return strings.TrimSpace(string(data)), nil
	}
	boot, err := read(filepath.Join(proc, "sys/kernel/random/boot_id"))
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(proc, strconv.Itoa(item.InitPID))
	data, err := read(filepath.Join(directory, "stat"))
	if err != nil {
		return nil, err
	}
	end := strings.LastIndexByte(data, ')')
	if end < 0 {
		return nil, errors.New("native process stat is incomplete")
	}
	fields := strings.Fields(data[end+1:])
	if len(fields) < 20 || fields[0] == "Z" || fields[0] == "X" {
		return nil, errors.New("native process is absent or terminated")
	}
	row := &LocalWorkerIdentity{ContainerID: item.ID, Name: item.Name, Confgen: item.Confgen, BootID: boot, InitPID: item.InitPID, InitBirth: fields[19], Namespaces: map[string]string{}}
	for _, key := range []string{"pid", "mnt", "user", "cgroup", "net"} {
		value, err := os.Readlink(filepath.Join(directory, "ns", key))
		if err != nil {
			return nil, err
		}
		row.Namespaces[key] = value
	}
	if !validLocalIdentity(row) {
		return nil, errors.New("native process provenance is incomplete")
	}
	return row, nil
}
