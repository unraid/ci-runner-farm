// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// RecordRegistration retains the attested public identity before an ephemeral
// listener exits, so maintenance never guesses a registration from a slot name.
func (c *Controller) RecordRegistration(name, id string, runnerID int64, runnerName string) error {
	if runnerID <= 0 || runnerName == "" {
		return errors.New("native registration identity is incomplete")
	}
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned.ID != id || owned.Fence == "" {
		return errors.New("native registration owner differs")
	}
	if owned.Withdrawal != nil {
		if owned.Withdrawal.ContainerID != id || owned.Withdrawal.Fence != owned.Fence || owned.Withdrawal.RunnerID != runnerID || owned.Withdrawal.RunnerName != runnerName {
			return errors.New("native registration identity changed")
		}
		return nil
	}
	// Only a receipt prepared by this code before first start may acquire
	// original provenance. Existing registrations are never historical backfills.
	if original := owned.OriginalRegistration; original != nil && original.Runtime == nil {
		parent := c.OwnerContext
		if parent == nil {
			parent = context.Background()
		}
		ctx, cancel := context.WithTimeout(parent, 10*time.Second)
		current, item, observeErr := c.observeOwner(ctx, name, id)
		verifier, verifies := c.Docker.(interface {
			verifyLocalRegistration(context.Context, *LocalWorkerIdentity, string, int64, string) error
		})
		if observeErr == nil && (!verifies || verifier.verifyLocalRegistration(ctx, current, c.Organization, runnerID, runnerName) != nil) {
			observeErr = errors.New("local public registration is unproved")
		}
		cancel()
		if observeErr == nil && item.RoutingGated && original.Host == c.Host && original.Epoch == c.Epoch && original.ContainerID == id && original.Confgen == item.Confgen && original.IncarnationSHA256 == ownerIncarnation(c.Epoch, id, owned.Fence) && item.RegistrationName == runnerName {
			original.RunnerID, original.RunnerName, original.Runtime = runnerID, runnerName, current
		}
	}
	owned.Withdrawal = &sharedcapacity.Withdrawal{ContainerID: id, Fence: owned.Fence, RunnerID: runnerID, RunnerName: runnerName}
	return c.save(name, owned)
}

const hostLabelPrefix = "crf-host-"

var hostKeyPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$`)
var ownerEpochPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

// HostSelectorLabel is a routing hint for an operator-configured host key.
// It is neither a chassis identity nor an access control mechanism.
func HostSelectorLabel(host string) string {
	if !hostKeyPattern.MatchString(host) {
		return ""
	}
	sum := sha256.Sum256([]byte("ci-runner-farm-host-v1\x00" + host))
	return hostLabelPrefix + hex.EncodeToString(sum[:])
}

func validOwnerContext(host, epoch string) bool {
	return HostSelectorLabel(host) != "" && ownerEpochPattern.MatchString(epoch)
}
func ownerIncarnation(epoch, id, fence string) string {
	sum := sha256.Sum256([]byte("ci-runner-farm-owner-v1\x00" + epoch + "\x00" + id + "\x00" + fence))
	return hex.EncodeToString(sum[:])
}

// OriginalRegistration is prepared before start, then bound once before routing.
// A nonnil incomplete record is explicitly unknown, never an inferred original.
type OriginalRegistration struct {
	Schema            int                  `json:"schema"`
	Host              string               `json:"host"`
	Epoch             string               `json:"epoch"`
	ContainerID       string               `json:"containerId"`
	Confgen           string               `json:"confgen"`
	IncarnationSHA256 string               `json:"incarnationSHA256"`
	RunnerID          int64                `json:"runnerId"`
	RunnerName        string               `json:"runnerName"`
	Runtime           *LocalWorkerIdentity `json:"runtime"`
}

// UnmarshalJSON rejects unknown origin fields without changing legacy receipts.
func (o *OriginalRegistration) UnmarshalJSON(data []byte) error {
	type plain OriginalRegistration
	var value plain
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	*o = OriginalRegistration(value)
	return nil
}

func validOriginalShape(o *OriginalRegistration) bool {
	if o == nil || o.Schema != 1 || !validOwnerContext(o.Host, o.Epoch) || !idPattern.MatchString(o.ContainerID) || !confgenPattern.MatchString(o.Confgen) {
		return false
	}
	if o.IncarnationSHA256 != "" && !idPattern.MatchString(o.IncarnationSHA256) {
		return false
	}
	if o.Runtime == nil {
		return o.RunnerID == 0 && o.RunnerName == ""
	}
	return o.RunnerID > 0 && len(o.RunnerName) > 0 && len(o.RunnerName) <= 256 && strings.IndexFunc(o.RunnerName, func(r rune) bool { return r < 0x21 || r > 0x7e }) == -1 && validLocalIdentity(o.Runtime) && o.Runtime.ContainerID == o.ContainerID && o.Runtime.Confgen == o.Confgen
}

// prepareRefreshedOrigin handles an existing inert refresh's committed-ID crash
// boundary. This is unstarted intent, never a historical execution backfill.
func (c *Controller) prepareRefreshedOrigin(ctx context.Context, name string, container *Container, owned *receipt, snapshot *sharedcapacity.Snapshot) error {
	original := owned.OriginalRegistration
	if !validOriginalShape(original) || original.ContainerID == container.ID || original.Runtime != nil || original.IncarnationSHA256 != "" || owned.Withdrawal != nil || !container.NeverStarted || container.Running || !validOwnerContext(c.Host, c.Epoch) || !confgenPattern.MatchString(container.Confgen) {
		return nil
	}
	if queuedReplacementAllowed(name, owned, snapshot) != nil {
		return nil
	}
	_, err := c.Docker.Inspect(ctx, original.ContainerID)
	if !errors.Is(err, ErrContainerMissing) {
		return nil
	}
	owned.OriginalRegistration = &OriginalRegistration{Schema: 1, Host: c.Host, Epoch: c.Epoch, ContainerID: container.ID, Confgen: container.Confgen}
	return c.save(name, owned)
}

// OwnerObservation correlates exact registration provenance without release power.
type OwnerObservation struct {
	Slot     string                `json:"slot"`
	RunnerID int64                 `json:"runnerId"`
	State    string                `json:"state"`
	Reason   string                `json:"reason"`
	Original *OriginalRegistration `json:"original"`
	Current  *LocalWorkerIdentity  `json:"current"`
}

func (c *Controller) observeOwner(ctx context.Context, name, id string) (*LocalWorkerIdentity, *Container, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	observer, ok := c.Docker.(interface {
		ObserveLocalOwner(context.Context, string) (*LocalWorkerIdentity, error)
		inspectLocalOwner(context.Context, string) (*Container, error)
	})
	if !ok {
		return nil, nil, errors.New("local owner observation is unavailable")
	}
	current, err := observer.ObserveLocalOwner(ctx, id)
	if err != nil {
		return nil, nil, err
	}
	item, err := observer.inspectLocalOwner(ctx, id)
	if err != nil {
		return nil, nil, err
	}
	if err = c.validate(item, name); err != nil {
		return nil, nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if !validLocalIdentity(current) || current.ContainerID != id || current.Name != name || item.ID != id || !item.Running || item.Paused || item.InitPID != current.InitPID || item.Confgen != current.Confgen {
		return nil, nil, errors.New("local owner observation changed")
	}
	return current, item, nil
}

func (c *Controller) matchOriginal(owned *receipt, item *Container, current *LocalWorkerIdentity) error {
	o := owned.OriginalRegistration
	if !validOriginalShape(o) || o.Schema != 1 || !validOwnerContext(o.Host, o.Epoch) || o.Host != c.Host || o.Epoch != c.Epoch || o.ContainerID != owned.ID || o.ContainerID != item.ID || o.Confgen != item.Confgen || !confgenPattern.MatchString(o.Confgen) || o.IncarnationSHA256 != ownerIncarnation(c.Epoch, item.ID, owned.Fence) || o.RunnerID <= 0 || o.RunnerName == "" || len(o.RunnerName) > 256 || o.RunnerName != item.RegistrationName || owned.Withdrawal == nil || owned.Withdrawal.Phase != "" || owned.Withdrawal.ContainerID != item.ID || owned.Withdrawal.Fence != owned.Fence || owned.Withdrawal.RunnerID != o.RunnerID || owned.Withdrawal.RunnerName != o.RunnerName || !sameLocalIdentity(o.Runtime, current) {
		return errors.New("original registration does not match the current incarnation")
	}
	return nil
}

// ObserveOwners reads existing receipts and supplied read-only ledger diagnostics.
// It never calls Registration, publishers, credential readers or lifecycle effects.
// Its caller retains the existing native fleet lock and configuration lease.
func (c *Controller) ObserveOwners(ctx context.Context, diagnostics sharedcapacity.Diagnostics) ([]OwnerObservation, error) {
	if !validOwnerContext(c.Host, c.Epoch) {
		return nil, errors.New("protected local host context required")
	}
	names := map[string]bool{}
	grants := map[string]sharedcapacity.GrantDiagnostic{}
	for _, grant := range diagnostics.Grants {
		if strings.HasPrefix(grant.ID, "build:") {
			name := strings.TrimPrefix(grant.ID, "build:")
			if !namePattern.MatchString(name) {
				return nil, errors.New("unknown native grant name")
			}
			if _, exists := grants[name]; exists {
				return nil, errors.New("ambiguous native grant")
			}
			names[name] = true
			grants[name] = grant
		}
	}
	info, err := os.Lstat(c.ReceiptRoot)
	if err == nil {
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !info.IsDir() || info.Mode().Perm() != 0o700 || !ok || owner.Uid != uint32(os.Geteuid()) {
			return nil, errors.New("unsafe native receipt directory")
		}
		directory, openErr := os.OpenFile(c.ReceiptRoot, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_DIRECTORY, 0)
		if openErr != nil {
			return nil, openErr
		}
		opened, statErr := directory.Stat()
		if statErr != nil || !os.SameFile(info, opened) {
			_ = directory.Close()
			return nil, errors.New("native receipt directory changed")
		}
		entries, readErr := directory.ReadDir(257)
		closeErr := directory.Close()
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return nil, readErr
		}
		if closeErr != nil {
			return nil, closeErr
		}
		if len(entries) > 256 {
			return nil, errors.New("native receipt inventory exceeds bound")
		}
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), ".receipt-") {
				continue
			}
			name := strings.TrimSuffix(entry.Name(), ".json")
			if entry.Name() != name+".json" || !namePattern.MatchString(name) {
				return nil, errors.New("unknown native receipt entry")
			}
			names[name] = true
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if len(names) > 256 {
		return nil, errors.New("native owner inventory exceeds bound")
	}
	ordered := make([]string, 0, len(names))
	for name := range names {
		ordered = append(ordered, name)
	}
	sort.Strings(ordered)
	rows := make([]OwnerObservation, 0, len(names))
	counts := map[int64]int{}
	for _, name := range ordered {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		row := OwnerObservation{Slot: name, State: "unknown", Reason: "receipt_unavailable"}
		owned, loadErr := c.load(name)
		if loadErr == nil {
			if owned.Withdrawal != nil {
				row.RunnerID = owned.Withdrawal.RunnerID
			}
			if validOriginalShape(owned.OriginalRegistration) {
				row.Original = owned.OriginalRegistration
			}
			row.Reason = "original_unavailable"
			if row.Original != nil && row.Original.Runtime != nil {
				row.State, row.Reason = "unknown", "observation_unavailable"
				current, item, observeErr := c.observeOwner(ctx, name, owned.ID)
				row.Current = current
				if observeErr == nil {
					row.State, row.Reason = "stale", "incarnation_changed"
					if c.matchOriginal(owned, item, current) == nil {
						grant, exists := grants[name]
						sum := sha256.Sum256([]byte(owned.Fence))
						cost, costErr := containerResources(item)
						row.State, row.Reason = "unknown", "grant_mismatch"
						if diagnostics.PolicyMatches && exists && grant.Pool == buildPool && grant.FenceSHA256 == hex.EncodeToString(sum[:]) && costErr == nil && grant.Cost == cost && !owned.Retiring && !owned.ReleasePending {
							row.State, row.Reason = "complete", "original_matches_current"
						}
					}
				}
			}
		}
		if row.RunnerID > 0 {
			counts[row.RunnerID]++
		}
		rows = append(rows, row)
	}
	for n := range rows {
		if rows[n].RunnerID > 0 && counts[rows[n].RunnerID] > 1 {
			rows[n].State, rows[n].Reason = "unknown", "ambiguous_runner_id"
		}
	}
	return rows, nil
}

func (c *Controller) requireHostRouting(ctx context.Context, owned *receipt, item *Container) error {
	count := 0
	for _, label := range item.RoutingLabels {
		if strings.HasPrefix(strings.ToLower(label), hostLabelPrefix) {
			count++
			if count != 1 || label != HostSelectorLabel(c.Host) {
				return errors.New("reserved host label differs from protected local host")
			}
		}
	}
	if count == 0 {
		return nil
	}
	current, last, err := c.observeOwner(ctx, item.Name, item.ID)
	if err != nil {
		return errors.New("targeted owner provenance is unavailable")
	}
	if err = c.matchOriginal(owned, last, current); err != nil {
		return fmt.Errorf("targeted owner provenance: %w", err)
	}
	if last.MemoryBytes != item.MemoryBytes || last.NanoCPUs != item.NanoCPUs || last.Confgen != item.Confgen || last.RegistrationName != item.RegistrationName || !slices.Equal(last.RoutingLabels, item.RoutingLabels) {
		return errors.New("targeted owner resource observation changed")
	}
	return nil
}
