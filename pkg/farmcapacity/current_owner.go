// Package farmcapacity reports current native owners without creating provenance.
package farmcapacity

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"golang.org/x/sys/unix"
)

// CurrentOwnerObservation is a current-only sample, never original history,
// effective-memory qualification, or authority to release or modify an owner.
type CurrentOwnerObservation struct {
	Schema             string           `json:"schema"`
	ObservedAt         time.Time        `json:"observedAt"`
	Slot               string           `json:"slot"`
	RunnerID           int64            `json:"runnerId"`
	State              string           `json:"state"`
	OriginalProvenance string           `json:"originalProvenance"`
	BindingSHA256      string           `json:"bindingSHA256"`
	Metadata           *CurrentMetadata `json:"metadata"`
}

type currentFileStamp struct {
	Device, Inode, UID, GID, Links uint64
	Mode                           uint32
	Size, Modified                 int64
}

func currentStamp(info os.FileInfo) (currentFileStamp, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return currentFileStamp{}, false
	}
	return currentFileStamp{uint64(stat.Dev), uint64(stat.Ino), uint64(stat.Uid), uint64(stat.Gid), uint64(stat.Nlink), uint32(info.Mode()), info.Size(), info.ModTime().UnixNano()}, true
}

type currentReceiptSet struct {
	owned     map[string]*receipt
	stamps    map[string]currentFileStamp
	hashes    map[string][32]byte
	directory currentFileStamp
}

// currentReceipts uses the native actual-directory boundary, not a new policy
// requiring shared filesystem mount ancestors to be private and root-owned.
func (c *Controller) currentReceipts(ctx context.Context) (currentReceiptSet, error) {
	result := currentReceiptSet{owned: map[string]*receipt{}, stamps: map[string]currentFileStamp{}, hashes: map[string][32]byte{}}
	if !filepath.IsAbs(c.ReceiptRoot) || filepath.Clean(c.ReceiptRoot) != c.ReceiptRoot || c.ReceiptRoot == "/" {
		return result, errors.New("current owner receipt root is noncanonical")
	}
	before, err := os.Lstat(c.ReceiptRoot)
	if err != nil {
		return result, errors.New("current owner receipt directory is unavailable")
	}
	stamp, ok := currentStamp(before)
	if !ok || !before.IsDir() || before.Mode().Perm() != 0o700 || before.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 || stamp.UID != uint64(os.Geteuid()) {
		return result, errors.New("unsafe current owner receipt directory")
	}
	directory, err := os.OpenFile(c.ReceiptRoot, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_DIRECTORY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return result, errors.New("current owner receipt directory open refused")
	}
	defer directory.Close()
	opened, err := directory.Stat()
	if err != nil {
		return result, errors.New("current owner receipt directory changed")
	}
	openedStamp, ok := currentStamp(opened)
	if !ok || stamp != openedStamp {
		return result, errors.New("current owner receipt directory changed")
	}
	entries, err := directory.ReadDir(257)
	if err != nil && !errors.Is(err, io.EOF) {
		return result, errors.New("current owner receipt inventory unavailable")
	}
	if len(entries) > 256 {
		return result, errors.New("current owner receipt inventory exceeds bound")
	}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		if strings.HasPrefix(entry.Name(), ".receipt-") {
			continue
		}
		name := strings.TrimSuffix(entry.Name(), ".json")
		if entry.Name() != name+".json" || !namePattern.MatchString(name) {
			return result, errors.New("unknown current owner receipt entry")
		}
		owned, identity, hash, err := readCurrentReceipt(int(directory.Fd()), entry.Name())
		if err != nil {
			return result, err
		}
		result.owned[name], result.stamps[name], result.hashes[name] = owned, identity, hash
	}
	after, err := directory.Stat()
	if err != nil {
		return result, errors.New("current owner receipt directory changed")
	}
	afterStamp, ok := currentStamp(after)
	named, namedErr := os.Lstat(c.ReceiptRoot)
	if !ok || afterStamp != stamp || namedErr != nil || !os.SameFile(before, named) {
		return result, errors.New("current owner receipt directory changed")
	}
	result.directory = stamp
	return result, nil
}

func readCurrentReceipt(directory int, name string) (*receipt, currentFileStamp, [32]byte, error) {
	var zero currentFileStamp
	var empty [32]byte
	fd, err := unix.Openat(directory, name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, zero, empty, errors.New("current owner receipt open refused")
	}
	file := os.NewFile(uintptr(fd), "current-owner-receipt")
	defer file.Close()
	before, err := file.Stat()
	if err != nil {
		return nil, zero, empty, errors.New("current owner receipt stat unavailable")
	}
	stamp, ok := currentStamp(before)
	if !ok || !before.Mode().IsRegular() || before.Mode().Perm() != 0o600 || before.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 || stamp.UID != uint64(os.Geteuid()) || stamp.Links != 1 || before.Size() < 1 || before.Size() > 4096 {
		return nil, zero, empty, errors.New("unsafe current owner receipt")
	}
	raw, err := io.ReadAll(io.LimitReader(file, 4097))
	if err != nil || len(raw) != int(before.Size()) || len(raw) > 4096 {
		return nil, zero, empty, errors.New("current owner receipt read changed")
	}
	after, err := file.Stat()
	if err != nil {
		return nil, zero, empty, errors.New("current owner receipt changed")
	}
	afterStamp, ok := currentStamp(after)
	if !ok || stamp != afterStamp {
		return nil, zero, empty, errors.New("current owner receipt changed")
	}
	fields, fieldErr := currentJSONFields(raw)
	if fieldErr != nil {
		return nil, zero, empty, errors.New("current owner receipt fields are ambiguous")
	}
	for _, name := range []string{"retiring", "releasePending", "maintenance", "replacementPrepared", "cacheCaptured", "preserveCache"} {
		if value, exists := fields[name]; exists && bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, zero, empty, errors.New("current owner lifecycle field is null")
		}
	}
	if rawWithdrawal, exists := fields["withdrawal"]; exists && !bytes.Equal(bytes.TrimSpace(rawWithdrawal), []byte("null")) {
		withdrawal, err := currentJSONFields(rawWithdrawal)
		if err != nil {
			return nil, zero, empty, errors.New("current owner registration fields are ambiguous")
		}
		for _, name := range []string{"containerId", "fence", "runnerId", "runnerName", "phase"} {
			if value, exists := withdrawal[name]; !exists || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
				return nil, zero, empty, errors.New("current owner registration field is unproved")
			}
		}
		if value, exists := withdrawal["unregistered"]; exists && bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, zero, empty, errors.New("current owner registration state is null")
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var owned receipt
	if err := decoder.Decode(&owned); err != nil {
		return nil, zero, empty, errors.New("current owner receipt is malformed")
	}
	if err := decoder.Decode(new(any)); err != io.EOF || !idPattern.MatchString(owned.ID) {
		return nil, zero, empty, errors.New("current owner receipt identity is malformed")
	}
	return &owned, stamp, sha256.Sum256(raw), nil
}

func currentGrant(diagnostics sharedcapacity.Diagnostics, name, fence string) (sharedcapacity.GrantDiagnostic, error) {
	var selected sharedcapacity.GrantDiagnostic
	age := time.Since(diagnostics.ObservedAt)
	if !diagnostics.PolicyMatches || age > 15*time.Second || age < -15*time.Second || fence == "" {
		return selected, errors.New("current owner policy or snapshot is unproved")
	}
	count := 0
	for _, grant := range diagnostics.Grants {
		if grant.ID == "build:"+name {
			selected = grant
			count++
		}
	}
	for _, pending := range diagnostics.Pending {
		if pending.ID == "build:"+name {
			return selected, errors.New("current owner has pending admission")
		}
	}
	sum := sha256.Sum256([]byte(fence))
	if count != 1 || selected.Pool != buildPool || selected.FenceSHA256 != hex.EncodeToString(sum[:]) {
		return selected, errors.New("current owner grant differs")
	}
	return selected, nil
}

// ObserveCurrentOwner is opt-in and read-only. It deliberately does not call
// ObserveOwners, matchOriginal, RecordRegistration, credential or lifecycle code.
// Its caller must retain the native fleet lock and protected configuration lease.
func (c *Controller) ObserveCurrentOwner(ctx context.Context, diagnostics sharedcapacity.Diagnostics, runnerID int64) (*CurrentOwnerObservation, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if runnerID <= 0 || !validOwnerContext(c.Host, c.Epoch) || c.Organization == "" {
		return nil, errors.New("protected current owner selector is required")
	}
	before, err := c.currentReceipts(ctx)
	if err != nil {
		return nil, err
	}
	var owned *receipt
	name := ""
	for candidate, row := range before.owned {
		if row.Withdrawal != nil && row.Withdrawal.RunnerID == runnerID {
			if owned != nil {
				return nil, errors.New("ambiguous current runner ID")
			}
			name, owned = candidate, row
		}
	}
	if owned == nil || owned.Withdrawal == nil {
		return nil, errors.New("current registration is unavailable")
	}
	withdrawal := owned.Withdrawal
	if withdrawal.ContainerID != owned.ID || withdrawal.Fence != owned.Fence || withdrawal.Phase != "" ||
		withdrawal.Unregistered || withdrawal.RunnerName == "" || len(withdrawal.RunnerName) > 256 ||
		strings.IndexFunc(withdrawal.RunnerName, func(r rune) bool { return r < 0x21 || r > 0x7e }) != -1 ||
		owned.Retiring || owned.ReleasePending || owned.Maintenance || owned.ReplacementPrepared {
		return nil, errors.New("current owner has unproved or pending lifecycle")
	}
	grant, err := currentGrant(diagnostics, name, owned.Fence)
	if err != nil {
		return nil, err
	}
	observer, ok := c.Docker.(interface {
		observeCurrentMetadata(context.Context, string, int64, string, string) (*CurrentMetadata, error)
	})
	if !ok {
		return nil, errors.New("closed current owner metadata is unavailable")
	}
	sample, err := observer.observeCurrentMetadata(ctx, owned.ID, runnerID, withdrawal.RunnerName, c.Organization)
	if err != nil {
		return nil, err
	}
	if !validCurrentMetadata(sample, owned.ID, runnerID, withdrawal.RunnerName) || c.validate(sample.container, name) != nil {
		return nil, errors.New("current owner metadata binding differs")
	}
	cost, costErr := containerResources(sample.container)
	if costErr != nil || cost != grant.Cost {
		return nil, errors.New("current owner hard limits differ from its grant")
	}
	after, err := c.currentReceipts(ctx)
	if err != nil {
		return nil, err
	}
	if before.directory != after.directory || !reflect.DeepEqual(before.stamps, after.stamps) || !reflect.DeepEqual(before.hashes, after.hashes) {
		return nil, errors.New("current owner receipt binding changed")
	}
	finalDiagnostics, err := c.Broker.Diagnose(&c.Policy)
	if err != nil {
		return nil, errors.New("current owner grant snapshot is unavailable")
	}
	finalGrant, err := currentGrant(finalDiagnostics, name, owned.Fence)
	if err != nil || !reflect.DeepEqual(grant, finalGrant) || diagnostics.ActivePolicyDigest != finalDiagnostics.ActivePolicyDigest {
		return nil, errors.New("current owner grant or policy changed")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	binding, err := json.Marshal([]any{c.Host, c.Epoch, name, runnerID, owned.ID, grant, sample.Runtime})
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(binding)
	original := "unavailable"
	if owned.OriginalRegistration != nil && owned.OriginalRegistration.Runtime != nil {
		original = "not-qualified-by-current-only-read"
	}
	return &CurrentOwnerObservation{
		Schema: "ci-runner-farm-current-owner/v1", ObservedAt: time.Now().UTC(), Slot: name, RunnerID: runnerID,
		State: "current-only; not release authority", OriginalProvenance: original,
		BindingSHA256: hex.EncodeToString(sum[:]), Metadata: sample,
	}, nil
}
