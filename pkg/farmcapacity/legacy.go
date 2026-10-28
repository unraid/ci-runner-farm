// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

const (
	legacyDefaultPool      = "default"
	withdrawalRemovedPhase = "removed"
)

var legacyNamePattern = regexp.MustCompile(`^ci-runner-[1-8]$`)

func ownedLegacyBuild(item *Container) bool {
	return item != nil && legacyNamePattern.MatchString(item.Name) && idPattern.MatchString(item.ID) && item.Managed && item.Provider == githubProvider && item.Role == runnerRole && item.Pool == legacyDefaultPool
}

// LegacyDrain retires default-pool owners before the first shared adoption.
// It never initializes a broker or treats a stopped/unknown API result as idle.
// The native caller must close all starts and hold configuration/fleet leases.
type LegacyDrain struct {
	Root   string
	Docker inventoryDocker
	Bind   func(context.Context, Container, *sharedcapacity.Withdrawal) (OwnerBinding, error)
	Now    func() time.Time
}

type legacyRoutingOwner interface {
	WithdrawLegacyRouting(context.Context) error
}

// Run preserves durable intent across restarts and performs at most one bounded
// withdrawal step per exact owner. Busy workers are resumed by AdvanceWithdrawal.
func (d *LegacyDrain) Run(ctx context.Context) error {
	if !filepath.IsAbs(d.Root) || d.Docker == nil || d.Bind == nil {
		return errors.New("legacy drain requires protected receipts and native owner binding")
	}
	if err := os.MkdirAll(d.Root, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(d.Root)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		return errors.New("unsafe legacy drain directory")
	}
	items, err := d.Docker.Owned(ctx)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	var problems []error
	now := time.Now().UTC()
	if d.Now != nil {
		now = d.Now().UTC()
	}
	for i := range items {
		item := items[i]
		if item.Pool != legacyDefaultPool {
			continue
		}
		if !ownedLegacyBuild(&item) || seen[item.Name] {
			return errors.New("legacy native owner is unsupported or ambiguous")
		}
		seen[item.Name] = true
	}
	for i := range items {
		item := items[i]
		if seen[item.Name] {
			problems = append(problems, d.advanceOwner(ctx, &item, now))
		}
	}
	problems = append(problems, d.recoverAbsent(ctx, seen, now))
	return errors.Join(problems...)
}

func (d *LegacyDrain) advanceOwner(ctx context.Context, item *Container, now time.Time) error {
	withdrawal, err := d.load(item.Name)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if withdrawal != nil && withdrawal.ContainerID != item.ID {
		return errors.New("legacy owner identity changed")
	}
	binding, err := d.Bind(ctx, *item, withdrawal)
	if err != nil {
		return err
	}
	if binding.Owner == nil {
		return errors.New("legacy native owner binding unavailable")
	}
	if withdrawal == nil {
		if binding.RunnerID <= 0 || binding.RunnerName == "" {
			return errors.New("legacy owner registration is not attested")
		}
		sum := sha256.Sum256([]byte("legacy-retirement:" + item.Name + ":" + item.ID))
		withdrawal = &sharedcapacity.Withdrawal{ContainerID: item.ID, Fence: hex.EncodeToString(sum[:]), RunnerID: binding.RunnerID, RunnerName: binding.RunnerName}
		if saveErr := d.save(item.Name, withdrawal); saveErr != nil {
			return saveErr
		}
	}
	if withdrawal.Phase == "" {
		// Persistent legacy listeners can immediately accept another job. Close
		// their custom routing first, without pausing or deregistering a worker.
		routing, ok := binding.Owner.(legacyRoutingOwner)
		if !ok {
			return errors.New("legacy routing withdrawal capability is required")
		}
		if routeErr := routing.WithdrawLegacyRouting(ctx); routeErr != nil {
			return routeErr
		}
		idle, idleErr := binding.Owner.Idle(ctx)
		if idleErr != nil {
			return idleErr
		}
		if !idle {
			return sharedcapacity.ErrWorkloadBusy
		}
	}
	return sharedcapacity.AdvanceWithdrawal(ctx, withdrawal, binding.Owner, now, func() error { return d.save(item.Name, withdrawal) })
}

func (d *LegacyDrain) recoverAbsent(ctx context.Context, seen map[string]bool, now time.Time) error {
	entries, err := os.ReadDir(d.Root)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		name := entry.Name()[:len(entry.Name())-5]
		if !legacyNamePattern.MatchString(name) {
			return errors.New("unknown legacy drain receipt")
		}
		if seen[name] {
			continue
		}
		withdrawal, readErr := d.load(name)
		if readErr != nil {
			return readErr
		}
		// Preserve uncertain removals for the same fenced owner to recover through
		// its native remote-absence checks; never delete receipts or infer success.
		if withdrawal.Phase != withdrawalRemovedPhase {
			binding, bindErr := d.Bind(ctx, Container{ID: withdrawal.ContainerID, Name: name}, withdrawal)
			if bindErr != nil {
				return bindErr
			}
			if stepErr := sharedcapacity.AdvanceWithdrawal(ctx, withdrawal, binding.Owner, now, func() error { return d.save(name, withdrawal) }); stepErr != nil {
				return stepErr
			}
		}
	}
	return nil
}

func (d *LegacyDrain) load(name string) (*sharedcapacity.Withdrawal, error) {
	if !legacyNamePattern.MatchString(name) {
		return nil, errors.New("invalid legacy receipt name")
	}
	file, err := os.OpenFile(filepath.Join(d.Root, name+".json"), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 4096 {
		return nil, errors.New("unsafe legacy receipt")
	}
	var w sharedcapacity.Withdrawal
	if err := json.NewDecoder(file).Decode(&w); err != nil {
		return nil, err
	}
	sum := sha256.Sum256([]byte("legacy-retirement:" + name + ":" + w.ContainerID))
	if !idPattern.MatchString(w.ContainerID) || w.Fence != hex.EncodeToString(sum[:]) || w.RunnerID <= 0 || w.RunnerName == "" {
		return nil, errors.New("invalid legacy retirement identity")
	}
	return &w, nil
}

func (d *LegacyDrain) save(name string, w *sharedcapacity.Withdrawal) error {
	if !legacyNamePattern.MatchString(name) {
		return errors.New("invalid legacy receipt name")
	}
	file, err := os.CreateTemp(d.Root, ".retirement-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if encodeErr := json.NewEncoder(file).Encode(w); encodeErr != nil {
		return encodeErr
	}
	if syncErr := file.Sync(); syncErr != nil {
		return syncErr
	}
	if closeErr := file.Close(); closeErr != nil {
		return closeErr
	}
	if renameErr := os.Rename(file.Name(), filepath.Join(d.Root, name+".json")); renameErr != nil {
		return renameErr
	}
	dir, err := os.Open(d.Root)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
