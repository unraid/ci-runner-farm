package farmcapacity

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type CurrentImage struct {
	ID          string   `json:"id"`
	Reference   string   `json:"reference"`
	Revision    string   `json:"revision,omitempty"`
	RepoDigests []string `json:"repoDigests"`
	Entrypoint  string   `json:"entrypoint"`
}
type CurrentLimits struct {
	MemoryBytes     uint64 `json:"memoryBytes"`
	MemorySwapBytes int64  `json:"memorySwapBytes"`
	NanoCPUs        uint64 `json:"nanoCPUs"`
}
type CurrentFileMetadata struct {
	UID              uint32 `json:"uid"`
	GID              uint32 `json:"gid"`
	Mode             string `json:"mode"`
	Size             int64  `json:"size"`
	Device           uint64 `json:"device"`
	Inode            uint64 `json:"inode"`
	Links            uint64 `json:"links"`
	ModifiedUnixNano int64  `json:"modifiedUnixNano"`
}
type CurrentMemoryFile struct {
	State       string               `json:"state"`
	ContentRead bool                 `json:"contentRead"`
	Metadata    *CurrentFileMetadata `json:"metadata,omitempty"`
}

// CurrentMetadata contains no environment, argv, credential, raw receipt,
// writable capability, or assertion about historical effective memory.
type CurrentMetadata struct {
	Runtime    *LocalWorkerIdentity `json:"runtime"`
	RunnerID   int64                `json:"runnerId"`
	RunnerName string               `json:"runnerName"`
	RootDevice uint64               `json:"rootDevice"`
	RootInode  uint64               `json:"rootInode"`
	Image      CurrentImage         `json:"image"`
	Limits     CurrentLimits        `json:"hardLimits"`
	MemoryFile CurrentMemoryFile    `json:"memoryFile"`
	container  *Container
}

var currentImageID = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
var currentImageRef = regexp.MustCompile(`^(ghcr\.io/unraid/ci-runner-image(:[A-Za-z0-9_.-]+|@sha256:[0-9a-f]{64})|ci-runner-farm-runner(:[A-Za-z0-9_.-]+)?)$`)
var currentRepoDigest = regexp.MustCompile(`^ghcr\.io/unraid/ci-runner-image@sha256:[0-9a-f]{64}$`)
var currentRevision = regexp.MustCompile(`^[0-9a-f]{40}$`)

func validCurrentMetadata(m *CurrentMetadata, id string, runnerID int64, name string) bool {
	if m == nil || m.container == nil || !validLocalIdentity(m.Runtime) || m.Runtime.ContainerID != id ||
		m.Runtime.Name != m.container.Name || m.Runtime.InitPID != m.container.InitPID || m.Runtime.Confgen != m.container.Confgen ||
		m.RunnerID != runnerID || m.RunnerName != name || m.container.ID != id || !m.container.Running || m.container.Paused ||
		m.RootInode == 0 || !currentImageID.MatchString(m.Image.ID) || !currentImageRef.MatchString(m.Image.Reference) ||
		(m.Image.Revision != "" && !currentRevision.MatchString(m.Image.Revision)) ||
		(m.Image.Entrypoint != "/entrypoint.sh" && m.Image.Entrypoint != "/usr/local/bin/unraid-runner-entrypoint.sh") ||
		len(m.Image.RepoDigests) > 16 || m.Limits.MemoryBytes != m.container.MemoryBytes ||
		m.Limits.NanoCPUs != m.container.NanoCPUs || m.Limits.MemorySwapBytes < -1 || m.MemoryFile.ContentRead {
		return false
	}
	for _, digest := range m.Image.RepoDigests {
		if !currentRepoDigest.MatchString(digest) {
			return false
		}
	}
	switch m.MemoryFile.State {
	case "not-observed; absence-or-access-unknown":
		return m.MemoryFile.Metadata == nil
	case "root0444-regular-present":
		s := m.MemoryFile.Metadata
		return s != nil && s.UID == 0 && s.GID == 0 && s.Mode == "0444" && s.Size > 0 && s.Size <= 32 && s.Links == 1 && s.Inode > 0
	default:
		return false
	}
}

type currentInspect struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Image      string   `json:"image"`
	Reference  string   `json:"reference"`
	Entrypoint []string `json:"entrypoint"`
	PID        int      `json:"pid"`
	Running    bool     `json:"running"`
	Paused     bool     `json:"paused"`
	Restarting bool     `json:"restarting"`
	Managed    string   `json:"managed"`
	Provider   string   `json:"provider"`
	Role       string   `json:"role"`
	Pool       string   `json:"pool"`
	Index      string   `json:"index"`
	Confgen    string   `json:"confgen"`
	Memory     uint64   `json:"memory"`
	MemorySwap int64    `json:"memorySwap"`
	NanoCPUs   uint64   `json:"nanoCPUs"`
}

const currentInspectFormat = `{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Image}},"reference":{{json .Config.Image}},"entrypoint":{{json .Config.Entrypoint}},"pid":{{json .State.Pid}},"running":{{json .State.Running}},"paused":{{json .State.Paused}},"restarting":{{json .State.Restarting}},"memory":{{json .HostConfig.Memory}},"memorySwap":{{json .HostConfig.MemorySwap}},"nanoCPUs":{{json .HostConfig.NanoCpus}},"managed":{{json (index .Config.Labels "net.unraid.ci-runner-farm.managed")}},"provider":{{json (index .Config.Labels "net.unraid.ci-runner-farm.provider")}},"role":{{json (index .Config.Labels "net.unraid.ci-runner-farm.role")}},"pool":{{json (index .Config.Labels "net.unraid.ci-runner-farm.pool")}},"index":{{json (index .Config.Labels "net.unraid.ci-runner-farm.index")}},"confgen":{{json (index .Config.Labels "net.unraid.ci-runner-farm.confgen")}}}`
const currentImageFormat = `{"id":{{json .Id}},"entrypoint":{{json .Config.Entrypoint}},"revision":{{json (index .Config.Labels "org.opencontainers.image.revision")}},"digests":{{json .RepoDigests}}}`

type boundedCurrentOutput struct {
	bytes.Buffer
	limit int
}

func (b *boundedCurrentOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.limit {
		return 0, errors.New("current metadata output exceeds bound")
	}
	return b.Buffer.Write(p)
}
func currentDockerRead(ctx context.Context, limit int, args ...string) ([]byte, error) {
	child, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	command := nativeReadCommand(child, true, args...)
	var output boundedCurrentOutput
	output.limit = limit
	command.Stdout, command.Stderr, command.WaitDelay = &output, io.Discard, time.Second
	if err := command.Run(); err != nil {
		return nil, errors.New("closed current Docker read failed")
	}
	if err := child.Err(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}
func currentJSONFields(raw []byte) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	first, err := decoder.Token()
	if err != nil || first != json.Delim('{') {
		return nil, errors.New("current metadata requires one object")
	}
	fields := map[string]json.RawMessage{}
	for decoder.More() {
		key, err := decoder.Token()
		name, ok := key.(string)
		if err != nil || !ok || len(name) > 128 || len(fields) >= 64 {
			return nil, errors.New("current metadata fields exceed their bound")
		}
		if _, exists := fields[name]; exists {
			return nil, errors.New("current metadata has duplicate fields")
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, errors.New("current metadata field is malformed")
		}
		fields[name] = value
	}
	if end, err := decoder.Token(); err != nil || end != json.Delim('}') {
		return nil, errors.New("current metadata object is incomplete")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, errors.New("current metadata has trailing data")
	}
	return fields, nil
}

type currentImageInspect struct {
	ID         string   `json:"id"`
	Entrypoint []string `json:"entrypoint"`
	Revision   *string  `json:"revision"`
	Digests    []string `json:"digests"`
}

func decodeCurrentJSON(raw []byte, value any) error {
	fields, err := currentJSONFields(raw)
	if err != nil {
		return err
	}
	var required []string
	allowNull := map[string]bool{}
	switch value.(type) {
	case *currentInspect:
		required = []string{"id", "name", "image", "reference", "entrypoint", "pid", "running", "paused", "restarting", "managed", "provider", "role", "pool", "index", "confgen", "memory", "memorySwap", "nanoCPUs"}
	case *currentImageInspect:
		required = []string{"id", "entrypoint", "revision", "digests"}
		allowNull["revision"], allowNull["digests"] = true, true
	default:
		return errors.New("unselected current JSON projection")
	}
	if len(fields) != len(required) {
		return errors.New("current metadata fields differ")
	}
	for _, name := range required {
		raw, exists := fields[name]
		if !exists || (!allowNull[name] && bytes.Equal(bytes.TrimSpace(raw), []byte("null"))) {
			return errors.New("current metadata field is missing or null")
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return errors.New("closed current metadata is malformed")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return errors.New("closed current metadata has trailing data")
	}
	return nil
}
func inspectCurrent(ctx context.Context, id string) (currentInspect, error) {
	var out currentInspect
	raw, err := currentDockerRead(ctx, 8192, "container", "inspect", "--format", currentInspectFormat, id)
	if err != nil {
		return out, err
	}
	if err = decodeCurrentJSON(raw, &out); err != nil {
		return out, err
	}
	index := out.Name[strings.LastIndex(out.Name, "-")+1:]
	if out.ID != id || !namePattern.MatchString(strings.TrimPrefix(out.Name, "/")) ||
		out.Name != "/"+strings.TrimPrefix(out.Name, "/") || !out.Running || out.Paused || out.Restarting || out.PID <= 1 ||
		out.Managed != "true" || out.Provider != githubProvider || out.Role != runnerRole || !ownedBuildPool(out.Pool, strings.TrimPrefix(out.Name, "/")) ||
		out.Index != index || !confgenPattern.MatchString(out.Confgen) || !currentImageID.MatchString(out.Image) ||
		!currentImageRef.MatchString(out.Reference) || len(out.Entrypoint) != 1 ||
		(out.Entrypoint[0] != "/entrypoint.sh" && out.Entrypoint[0] != "/usr/local/bin/unraid-runner-entrypoint.sh") ||
		out.MemorySwap < -1 || out.Memory == 0 || out.NanoCPUs == 0 {
		return out, errors.New("current Docker identity differs")
	}
	return out, nil
}
func currentContainer(i currentInspect, runnerName string) *Container {
	return &Container{ID: i.ID, Name: strings.TrimPrefix(i.Name, "/"), Confgen: i.Confgen, InitPID: i.PID,
		Managed: true, Provider: i.Provider, Role: i.Role, Pool: i.Pool, Running: i.Running, Paused: i.Paused,
		MemoryBytes: i.Memory, NanoCPUs: i.NanoCPUs, RegistrationName: runnerName}
}
func currentIdle(ctx context.Context, id string) error {
	raw, err := currentDockerRead(ctx, 32768, "top", id, "-eo", "pid,comm")
	if err != nil {
		return err
	}
	if len(bytes.Split(raw, []byte("\n"))) > 513 {
		return errors.New("current process inventory exceeds bound")
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) < 2 || strings.Join(strings.Fields(lines[0]), " ") != "PID COMMAND" {
		return errors.New("current process inventory header is unproved")
	}
	idle, err := nativeProcessesIdle(string(raw))
	if err != nil || !idle {
		return errors.New("current runner is busy or unproved")
	}
	return nil
}

// No path or UID override is exposed by the native CLI. These roots allow the
// same descriptor-based code to run against isolated process fixtures in tests.
type currentReadRoots struct {
	proc                        string
	rootUID, rootGID, runnerUID uint32
}

func openCurrentPath(root int, components []string) (*os.File, error) {
	if len(components) == 0 || len(components) > 3 {
		return nil, errors.New("unselected current path")
	}
	parent := root
	var opened *os.File
	for index, component := range components {
		if component == "" || component == "." || component == ".." || strings.ContainsAny(component, "/\x00") {
			if opened != nil {
				_ = opened.Close()
			}
			return nil, errors.New("noncanonical current path")
		}
		flags := unix.O_RDONLY | unix.O_NOFOLLOW | unix.O_NONBLOCK | unix.O_CLOEXEC
		if index != len(components)-1 {
			flags |= unix.O_DIRECTORY
		}
		fd, err := unix.Openat(parent, component, flags, 0)
		if opened != nil {
			_ = opened.Close()
		}
		if err != nil {
			return nil, err
		}
		opened = os.NewFile(uintptr(fd), "selected-current-metadata")
		parent = fd
	}
	return opened, nil
}
func currentPublicRegistration(root int, runnerID int64, name, organization string, uid uint32) error {
	directory, err := openCurrentPath(root, []string{"actions-runner"})
	if err != nil {
		return errors.New("current public registration parent is unavailable")
	}
	defer directory.Close()
	parent, err := directory.Stat()
	if err != nil {
		return errors.New("current public registration parent is unavailable")
	}
	ps, ok := currentStamp(parent)
	if !ok || !parent.IsDir() || (ps.UID != 0 && ps.UID != uint64(uid)) || parent.Mode().Perm()&0o022 != 0 {
		return errors.New("current public registration parent is unsafe")
	}
	file, err := openCurrentPath(int(directory.Fd()), []string{".runner"})
	if err != nil {
		return errors.New("current public registration is unavailable")
	}
	defer file.Close()
	before, err := file.Stat()
	if err != nil {
		return errors.New("current public registration is unavailable")
	}
	stamp, ok := currentStamp(before)
	if !ok || !before.Mode().IsRegular() || stamp.UID != uint64(uid) || stamp.Links != 1 ||
		before.Mode().Perm()&0o022 != 0 || before.Size() <= 0 || before.Size() > 16384 {
		return errors.New("current public registration is unsafe")
	}
	raw, err := io.ReadAll(io.LimitReader(file, 16385))
	if err != nil || len(raw) != int(before.Size()) {
		return errors.New("current public registration changed")
	}
	var identity struct {
		AgentID   int64  `json:"agentId"`
		AgentName string `json:"agentName"`
		GitHubURL string `json:"gitHubUrl"`
	}
	// GitHub adds other noncredential fields to .runner. Only these three bind identity.
	fields, fieldErr := currentJSONFields(bytes.TrimPrefix(raw, []byte{0xef, 0xbb, 0xbf}))
	for _, name := range []string{"agentId", "agentName", "gitHubUrl"} {
		if value, exists := fields[name]; !exists || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			fieldErr = errors.New("current public registration field is missing")
		}
	}
	if fieldErr != nil {
		return errors.New("current public registration is ambiguous")
	}
	if err := json.Unmarshal(bytes.TrimPrefix(raw, []byte{0xef, 0xbb, 0xbf}), &identity); err != nil ||
		identity.AgentID != runnerID || identity.AgentName != name || identity.GitHubURL != "https://github.com/"+organization {
		return errors.New("current public registration differs")
	}
	after, err := file.Stat()
	if err != nil {
		return errors.New("current public registration changed")
	}
	next, ok := currentStamp(after)
	named, err := openCurrentPath(root, []string{"actions-runner", ".runner"})
	if err != nil {
		return errors.New("current public registration changed")
	}
	defer named.Close()
	namedInfo, namedErr := named.Stat()
	if !ok || stamp != next || namedErr != nil || !os.SameFile(before, namedInfo) {
		return errors.New("current public registration changed")
	}
	return nil
}
func currentMemoryMetadata(root int, roots currentReadRoots) (CurrentMemoryFile, error) {
	out := CurrentMemoryFile{State: "not-observed; absence-or-access-unknown"}
	directory, err := openCurrentPath(root, []string{"etc", "unraid-ci"})
	if err != nil {
		if errors.Is(err, syscall.ELOOP) || errors.Is(err, syscall.ENOTDIR) {
			return out, errors.New("canonical memory parent is unsafe")
		}
		return out, nil
	}
	defer directory.Close()
	parent, err := directory.Stat()
	if err != nil {
		return out, errors.New("canonical memory parent changed")
	}
	ps, ok := currentStamp(parent)
	if !ok || !parent.IsDir() || ps.UID != uint64(roots.rootUID) || ps.GID != uint64(roots.rootGID) || parent.Mode().Perm()&0o022 != 0 {
		return out, errors.New("canonical memory parent is unsafe")
	}
	// O_PATH is unnecessary: an O_RDONLY descriptor is only statted, never read.
	file, err := openCurrentPath(int(directory.Fd()), []string{"runtime-memory-max"})
	if err != nil {
		if errors.Is(err, syscall.ELOOP) {
			return out, errors.New("canonical memory file is unsafe")
		}
		return out, nil
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return out, errors.New("canonical memory file changed")
	}
	s, ok := currentStamp(info)
	if !ok || !info.Mode().IsRegular() || s.UID != uint64(roots.rootUID) || s.GID != uint64(roots.rootGID) ||
		info.Mode().Perm() != 0o444 || info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 || s.Links != 1 || info.Size() < 1 || info.Size() > 32 {
		return out, errors.New("canonical memory file metadata is unsafe")
	}
	out.State = "root0444-regular-present"
	out.Metadata = &CurrentFileMetadata{UID: uint32(s.UID), GID: uint32(s.GID), Mode: "0444", Size: info.Size(), Device: s.Device, Inode: s.Inode, Links: s.Links, ModifiedUnixNano: s.Modified}
	return out, nil
}
func currentRoot(proc string, pid int) (*os.File, currentFileStamp, error) {
	file, err := os.OpenFile(filepath.Join(proc, strconv.Itoa(pid), "root"), os.O_RDONLY|syscall.O_DIRECTORY, 0)
	if err != nil {
		return nil, currentFileStamp{}, errors.New("current process root is unavailable")
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, currentFileStamp{}, errors.New("current process root is unavailable")
	}
	s, ok := currentStamp(info)
	if !ok || !info.IsDir() {
		_ = file.Close()
		return nil, currentFileStamp{}, errors.New("current process root differs")
	}
	return file, s, nil
}
func (d NativeDocker) observeCurrentMetadata(ctx context.Context, id string, runnerID int64, name, organization string) (*CurrentMetadata, error) {
	return d.observeCurrentMetadataAt(ctx, id, runnerID, name, organization, currentReadRoots{proc: "/proc", rootUID: 0, rootGID: 0, runnerUID: 1001})
}
func (NativeDocker) observeCurrentMetadataAt(parent context.Context, id string, runnerID int64, name, organization string, roots currentReadRoots) (*CurrentMetadata, error) {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	if !idPattern.MatchString(id) || runnerID <= 0 || name == "" || organization == "" {
		return nil, errors.New("current metadata selector is incomplete")
	}
	if endpoint := os.Getenv("DOCKER_HOST"); endpoint != "" && endpoint != localDockerEndpoint {
		return nil, errors.New("current metadata requires local Docker")
	}
	// Preserve the existing endpoint preflight, but bound its output and deadline too.
	child, stop := context.WithTimeout(ctx, 3*time.Second)
	command := nativeReadCommand(child, false, "context", "inspect", "--format", `{{(index .Endpoints "docker").Host}}`)
	var endpoint boundedCurrentOutput
	endpoint.limit = 1024
	command.Stdout, command.Stderr, command.WaitDelay = &endpoint, io.Discard, time.Second
	endpointErr := command.Run()
	stop()
	if endpointErr != nil || strings.TrimSpace(endpoint.String()) != localDockerEndpoint {
		return nil, errors.New("current local Docker endpoint is unproved")
	}
	first, err := inspectCurrent(ctx, id)
	if err != nil {
		return nil, err
	}
	if err = currentIdle(ctx, id); err != nil {
		return nil, err
	}
	item := currentContainer(first, name)
	runtime, err := readLocalIdentity(item, roots.proc)
	if err != nil {
		return nil, errors.New("current process identity is unavailable")
	}
	root, rootStamp, err := currentRoot(roots.proc, first.PID)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	if err = currentPublicRegistration(int(root.Fd()), runnerID, name, organization, roots.runnerUID); err != nil {
		return nil, err
	}
	memory, err := currentMemoryMetadata(int(root.Fd()), roots)
	if err != nil {
		return nil, err
	}
	var image currentImageInspect
	raw, err := currentDockerRead(ctx, 8192, "image", "inspect", "--format", currentImageFormat, first.Image)
	if err != nil {
		return nil, err
	}
	if err = decodeCurrentJSON(raw, &image); err != nil {
		return nil, err
	}
	if image.ID != first.Image || !reflect.DeepEqual(image.Entrypoint, first.Entrypoint) || len(image.Digests) > 16 {
		return nil, errors.New("current image binding differs")
	}
	projected := CurrentImage{ID: image.ID, Reference: first.Reference, Entrypoint: first.Entrypoint[0], RepoDigests: []string{}}
	if image.Revision != nil {
		projected.Revision = *image.Revision
	}
	for _, digest := range image.Digests {
		if len(digest) > 256 {
			return nil, errors.New("current image digest exceeds bound")
		}
		if currentRepoDigest.MatchString(digest) {
			projected.RepoDigests = append(projected.RepoDigests, digest)
		}
	}
	if err = currentIdle(ctx, id); err != nil {
		return nil, err
	}
	last, err := inspectCurrent(ctx, id)
	if err != nil {
		return nil, err
	}
	afterRuntime, err := readLocalIdentity(currentContainer(last, name), roots.proc)
	if err != nil {
		return nil, errors.New("current process changed")
	}
	afterRoot, afterRootStamp, err := currentRoot(roots.proc, last.PID)
	if err != nil {
		return nil, err
	}
	defer afterRoot.Close()
	if !reflect.DeepEqual(first, last) {
		return nil, errors.New("current container changed")
	}
	if !sameLocalIdentity(runtime, afterRuntime) || rootStamp.Device != afterRootStamp.Device || rootStamp.Inode != afterRootStamp.Inode {
		return nil, errors.New("current process root changed")
	}
	if err = currentPublicRegistration(int(afterRoot.Fd()), runnerID, name, organization, roots.runnerUID); err != nil {
		return nil, err
	}
	afterMemory, err := currentMemoryMetadata(int(afterRoot.Fd()), roots)
	if err != nil || !reflect.DeepEqual(memory, afterMemory) {
		return nil, errors.New("current memory file metadata changed")
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	result := &CurrentMetadata{Runtime: runtime, RunnerID: runnerID, RunnerName: name, RootDevice: rootStamp.Device, RootInode: rootStamp.Inode,
		Image: projected, Limits: CurrentLimits{first.Memory, first.MemorySwap, first.NanoCPUs}, MemoryFile: memory, container: item}
	if !validCurrentMetadata(result, id, runnerID, name) {
		return nil, errors.New("current metadata projection is unqualified")
	}
	return result, nil
}
