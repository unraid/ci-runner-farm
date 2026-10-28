// Package farmcapacity binds native farm container identities to shared grants.
package farmcapacity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const (
	buildPool      = "build"
	githubProvider = "github"
	runnerRole     = "runner"
)

var (
	// ErrContainerMissing distinguishes authoritative absence from Docker failure.
	ErrContainerMissing = errors.New("build container does not exist")
	// ErrQueued preserves the created container and its durable queue position.
	ErrQueued = errors.New("build admission queued")
	// ErrCredentialsExpired asks the native owner to refresh only inert demand.
	ErrCredentialsExpired = errors.New("inert build registration credential requires refresh")
	// ErrStartReplaced asks the native owner to recreate a slot whose exact
	// never-started container was removed and released after a proved failed start.
	ErrStartReplaced = errors.New("never-started build released after a failed start")
	namePattern      = regexp.MustCompile(`^ci-runner-build(-[a-z][a-z0-9-]{0,17})?-([1-9]|[1-5][0-9]|6[0-4])$`)
	idPattern        = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// Container is an immutable Docker identity and its enforced resource limits.
type Container struct {
	ID                   string
	Name                 string
	Managed              bool
	Provider             string
	Role                 string
	Pool                 string
	MemoryBytes          uint64
	NanoCPUs             uint64
	Running              bool
	Paused               bool
	Exited               bool
	Terminated           bool
	NeverStarted         bool
	RegistrationIssuedAt int64
	RoutingLabels        []string
	RoutingGated         bool
	DockerRoot           string
	RegistrationName     string
}

// Docker must distinguish a missing container from a failed Docker request.
type Docker interface {
	Inspect(context.Context, string) (*Container, error)
	Start(context.Context, string) error
}

type receipt struct {
	Start               *sharedcapacity.StartReservation `json:"start,omitempty"`
	ID                  string                           `json:"containerId"`
	DockerRoot          string                           `json:"dockerRoot,omitempty"`
	CacheCaptured       bool                             `json:"cacheCaptured,omitempty"`
	Retiring            bool                             `json:"retiring,omitempty"`
	PreserveCache       bool                             `json:"preserveCache,omitempty"`
	Maintenance         bool                             `json:"maintenance,omitempty"`
	Fence               string                           `json:"fence"`
	ReleasePending      bool                             `json:"releasePending,omitempty"`
	ReplacementPrepared bool                             `json:"replacementPrepared,omitempty"`
	Withdrawal          *sharedcapacity.Withdrawal       `json:"withdrawal,omitempty"`
}

// Controller is called only while the native farm's fleet lock is held.
// Receipts survive uncertain starts; neither grants nor receipts expire.
type Controller struct {
	Broker      sharedcapacity.Broker
	Policy      sharedcapacity.Policy
	ReceiptRoot string
	Docker      Docker
	RepairCache func(context.Context, string, string) error
	Poisoned    func(string, string) (bool, error)
}

func (c *Controller) validate(container *Container, name string) error {
	_, exists := c.Policy.Pools[buildPool]
	if !namePattern.MatchString(name) || !exists || container == nil || !idPattern.MatchString(container.ID) || container.Name != name ||
		!container.Managed || container.Provider != githubProvider || container.Role != runnerRole || !ownedBuildPool(container.Pool, name) {
		return errors.New("container is not an owned build slot")
	}
	resources, err := containerResources(container)
	if err != nil {
		return err
	}
	if _, err := sharedcapacity.RequestCost(&c.Policy, sharedcapacity.Request{Pool: buildPool, Resources: resources}); err != nil {
		return err
	}
	return nil
}

// Start admits an already-created, inert native farm container before starting
// its immutable ID. An uncertain start retains the exact receipt and grant.
func (c *Controller) Start(ctx context.Context, name, id string) error {
	container, err := c.Docker.Inspect(ctx, id)
	if err != nil {
		return err
	}
	if validationErr := c.validate(container, name); validationErr != nil {
		return validationErr
	}
	if container.ID != id {
		return errors.New("build container identity changed")
	}
	if container.NeverStarted && !container.RoutingGated {
		return errors.New("new build must register without job routing before identity binding")
	}
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	request, err := c.containerRequest(container, &snapshot)
	if err != nil {
		return err
	}
	owned, err := c.prepareStartReceipt(ctx, name, container, &snapshot)
	if err != nil {
		return err
	}
	if owned.Retiring {
		return errors.New("build owner is retiring")
	}
	if owned.ReleasePending {
		return errors.New("build has pending native removal")
	}
	decision, err := c.Broker.Admit(&c.Policy, request)
	if err != nil {
		return err
	}
	if !decision.Admitted {
		return ErrQueued
	}
	owned.Fence = decision.Grant.Fence
	if err := c.save(name, owned); err != nil {
		return err
	}
	if container.Running {
		return nil
	}
	if owned.Withdrawal != nil && owned.Withdrawal.Phase != "" {
		return errors.New("build is owned by idle withdrawal; finish recovery before start")
	}
	if c.Policy.SharedMemoryHeadroom {
		start, err := c.Broker.ReserveStart(&c.Policy, request.ID, owned.Fence)
		if errors.Is(err, sharedcapacity.ErrMemoryHeadroom) {
			return ErrQueued
		}
		if err != nil {
			return err
		}
		owned.Start = &start
		if err := c.save(name, owned); err != nil {
			return err
		}
	}
	if err := c.Docker.Start(ctx, id); err != nil {
		if c.failedStartProved(ctx, name, container) {
			return c.replaceFailedStart(ctx, name, owned, err)
		}
		// An unproved outcome is retried by warm recovery on every pass. Defer
		// it like a queued start so one broken container cannot fail every
		// tick and stall queue-driven planning; the receipt, grant and
		// reservation are retained exactly as before.
		if decision.Reason == "existing" && container.NeverStarted {
			return errors.Join(ErrQueued, fmt.Errorf("retained grant start failed: %w", err))
		}
		return err
	}
	return nil
}

// PrepareRelease preserves exact removal intent before the native owner disappears.
// It closes replacement starts but never stops a running job.
func (c *Controller) PrepareRelease(ctx context.Context, name, id string) error {
	if !namePattern.MatchString(name) || !idPattern.MatchString(id) {
		return errors.New("invalid build release identity")
	}
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned == nil || owned.ID != id {
		return errors.New("build release receipt differs")
	}
	item, err := c.Docker.Inspect(ctx, id)
	if err != nil {
		return err
	}
	if err := c.validate(item, name); err != nil {
		return err
	}
	if item.ID != id {
		return errors.New("build removal identity changed")
	}
	if captureErr := c.captureDockerRoot(ctx, name, owned); captureErr != nil {
		return captureErr
	}
	owned.ReleasePending = true
	return c.save(name, owned)
}

// Release requires the native owner to remove and deregister the old container
// first. Replacements, Docker errors and stale IDs retain their allocations.
func (c *Controller) Release(ctx context.Context, name, id string) error {
	if !namePattern.MatchString(name) || !idPattern.MatchString(id) {
		return errors.New("invalid build release identity")
	}
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned == nil || owned.ID != id {
		return errors.New("build release receipt differs")
	}
	requestID := "build:" + name
	snapshot, err := c.Broker.Status(&c.Policy)
	if err != nil {
		return err
	}
	prove := func() error {
		for _, identity := range []string{id, name} {
			container, inspectErr := c.Docker.Inspect(ctx, identity)
			if inspectErr != nil && !errors.Is(inspectErr, ErrContainerMissing) {
				return inspectErr
			}
			if container != nil {
				return errors.New("build container or replacement still exists")
			}
		}
		return nil
	}
	if err := prove(); err != nil {
		return err
	}
	if err := c.repairReleasedCache(ctx, name, owned); err != nil {
		return err
	}

	// A missing fenced grant requires intent that predates this observation.
	if _, charged := snapshot.Grants[requestID]; !charged && owned.Fence != "" && !completedRelease(requestID, owned, &snapshot) {
		return errors.New("build allocation disappeared before release")
	}
	// Persist intent before either ledger effect so receipt cleanup is replayable.
	if !owned.ReleasePending {
		owned.ReleasePending = true
		if err := c.save(name, owned); err != nil {
			return err
		}
	}
	if releaseErr := c.releaseAllocation(requestID, owned, &snapshot, prove); releaseErr != nil {
		return releaseErr
	}
	return os.Remove(filepath.Join(c.ReceiptRoot, name+".json"))
}

func (c *Controller) releaseAllocation(requestID string, owned *receipt, snapshot *sharedcapacity.Snapshot, prove func() error) error {
	grant, exists := snapshot.Grants[requestID]
	if !exists {
		if owned.Fence != "" {
			if completedRelease(requestID, owned, snapshot) {
				return nil
			}
			return errors.New("build allocation disappeared before release")
		}
		if pending, queued := snapshot.Pending[requestID]; queued {
			return c.Broker.Cancel(&c.Policy, pending.Request)
		}
		return nil
	}
	if owned.Fence != "" && owned.Fence != grant.Fence {
		return sharedcapacity.ErrFenceMismatch
	}
	return c.Broker.Release(&c.Policy, requestID, grant.Fence, func(sharedcapacity.Grant) error { return prove() })
}

func (c *Controller) load(name string) (*receipt, error) {
	if !filepath.IsAbs(c.ReceiptRoot) || !namePattern.MatchString(name) {
		return nil, errors.New("invalid build receipt path")
	}
	file, err := os.OpenFile(filepath.Join(c.ReceiptRoot, name+".json"), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil, os.ErrNotExist
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 4096 {
		return nil, errors.New("unsafe build receipt")
	}
	var owned receipt
	if err := json.NewDecoder(file).Decode(&owned); err != nil {
		return nil, err
	}
	if !idPattern.MatchString(owned.ID) {
		return nil, errors.New("invalid build receipt identity")
	}
	return &owned, nil
}

func (c *Controller) save(name string, owned *receipt) error {
	if err := os.MkdirAll(c.ReceiptRoot, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(c.ReceiptRoot)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 {
		return errors.New("unsafe build receipt directory")
	}
	file, err := os.CreateTemp(c.ReceiptRoot, ".receipt-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if encodeErr := json.NewEncoder(file).Encode(owned); encodeErr != nil {
		return encodeErr
	}
	if syncErr := file.Sync(); syncErr != nil {
		return syncErr
	}
	if closeErr := file.Close(); closeErr != nil {
		return closeErr
	}
	if renameErr := os.Rename(file.Name(), filepath.Join(c.ReceiptRoot, name+".json")); renameErr != nil {
		return renameErr
	}
	dir, err := os.Open(c.ReceiptRoot)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func (c *Controller) prepareStartReceipt(ctx context.Context, name string, container *Container, snapshot *sharedcapacity.Snapshot) (*receipt, error) {
	owned, err := c.load(name)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	grant, charged := snapshot.Grants["build:"+name]
	if owned != nil && owned.ID != container.ID {
		if replaceErr := c.finishQueuedReplacement(ctx, name, container, owned, snapshot); replaceErr != nil {
			return nil, replaceErr
		}
	}
	if owned != nil && owned.ReplacementPrepared {
		return nil, errors.New("queued replacement is prepared; finish native refresh before admission")
	}
	if owned == nil {
		if charged || container.Running {
			return nil, errors.New("running or charged build requires owner adoption")
		}
		owned = &receipt{ID: container.ID}
		if saveErr := c.save(name, owned); saveErr != nil {
			return nil, saveErr
		}
	}
	if charged && owned.Fence != "" && owned.Fence != grant.Fence {
		return nil, sharedcapacity.ErrFenceMismatch
	}
	if !charged && (owned.Fence != "" || container.Running) {
		return nil, errors.New("build lost its allocation; owner adoption required")
	}
	if container.Exited || (owned.Withdrawal != nil && owned.Withdrawal.Phase != "") {
		return nil, ErrQueued
	}
	if container.NeverStarted && !charged && (!c.registrationFresh(container) || c.queuedDefaultCPUUpgrade(container, snapshot)) {
		return nil, ErrCredentialsExpired
	}
	return owned, nil
}

func completedRelease(requestID string, owned *receipt, snapshot *sharedcapacity.Snapshot) bool {
	if _, charged := snapshot.Grants[requestID]; charged {
		return false
	}
	if _, pending := snapshot.Pending[requestID]; pending {
		return false
	}
	if owned.ReleasePending {
		return true
	}
	return owned.Withdrawal != nil && owned.Withdrawal.Phase == withdrawalRemovedPhase && owned.Withdrawal.Fence == owned.Fence && owned.Withdrawal.ContainerID == owned.ID
}

// ownedBuildPool binds a configured build size class to its exact native name.
func ownedBuildPool(pool, name string) bool {
	return namePattern.MatchString(name) && name == "ci-runner-"+pool+"-"+name[strings.LastIndexByte(name, '-')+1:] && (pool == buildPool || strings.HasPrefix(pool, "build-"))
}

func containerResources(item *Container) (sharedcapacity.Resources, error) {
	const mib = 1024 * 1024
	const cpu = 1_000_000_000
	cpus := item.NanoCPUs / cpu
	if item.MemoryBytes == 0 || item.MemoryBytes%mib != 0 || item.NanoCPUs == 0 || item.NanoCPUs%cpu != 0 || cpus > 64 {
		return sharedcapacity.Resources{}, errors.New("build hard limits require positive whole MiB and CPU units")
	}
	return sharedcapacity.Resources{MemoryMiB: item.MemoryBytes / mib, VCPUs: uint32(cpus)}, nil
}

func (c *Controller) containerRequest(item *Container, snapshot *sharedcapacity.Snapshot) (sharedcapacity.Request, error) {
	resources, err := containerResources(item)
	if err != nil {
		return sharedcapacity.Request{}, err
	}
	request := sharedcapacity.Request{ID: "build:" + item.Name, Pool: buildPool}
	if snapshot != nil {
		return c.existingContainerRequest(snapshot, request, item, resources)
	}
	return c.newContainerRequest(request, resources)
}

func (c *Controller) existingContainerRequest(snapshot *sharedcapacity.Snapshot, request sharedcapacity.Request, item *Container, resources sharedcapacity.Resources) (sharedcapacity.Request, error) {
	if grant, exists := snapshot.Grants[request.ID]; exists {
		if grant.Pool != buildPool || grant.Cost != resources {
			return request, errors.New("build hard limits differ from its immutable grant")
		}
		return grant.Request, nil
	}
	if pending, exists := snapshot.Pending[request.ID]; exists {
		cost, costErr := sharedcapacity.RequestCost(&c.Policy, pending.Request)
		if costErr != nil || pending.Pool != buildPool || (cost != resources && !c.queuedDefaultCPUUpgrade(item, snapshot)) {
			return request, errors.New("build hard limits differ from its stable pending request")
		}
		return pending.Request, nil
	}
	return c.newContainerRequest(request, resources)
}

// The existing credential-refresh owner can replace an inert default builder
// after a reviewed CPU increase. Adoption keeps its pending identity and age;
// Start requires exact receipt validation and refresh before granting or starting.
func (c *Controller) queuedDefaultCPUUpgrade(item *Container, snapshot *sharedcapacity.Snapshot) bool {
	if !item.NeverStarted || item.Running || item.Paused || !item.RoutingGated {
		return false
	}
	id := "build:" + item.Name
	if _, charged := snapshot.Grants[id]; charged {
		return false
	}
	pending, exists := snapshot.Pending[id]
	resources, err := containerResources(item)
	cost := c.Policy.Pools[buildPool].Cost
	return exists && pending.Pool == buildPool && pending.Resources == (sharedcapacity.Resources{}) && err == nil &&
		resources.MemoryMiB == cost.MemoryMiB && resources.VCPUs < cost.VCPUs
}

func (c *Controller) newContainerRequest(request sharedcapacity.Request, resources sharedcapacity.Resources) (sharedcapacity.Request, error) {
	if resources != c.Policy.Pools[buildPool].Cost {
		request.Resources = resources
	}
	return request, nil
}
