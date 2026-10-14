// Package hostcapacity defines Farm's protected host admission contract.
package hostcapacity

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// PoolExpansion is a durable, closed policy transition. Unknown readers fail
// closed until the exact ledger and active policy have both been published.
type PoolExpansion struct {
	Previous sharedcapacity.Policy `json:"previous"`
	Revised  sharedcapacity.Policy `json:"revised"`
}

func samePolicy(a, b sharedcapacity.Policy) bool { return reflect.DeepEqual(a, b) }

// Validate permits only monotonic pool limits. Costs, priorities, physical
// reserves, budgets, epochs and existing allocation identities stay unchanged.
func (e *PoolExpansion) Validate() error {
	if e == nil {
		return errors.New("pool expansion is missing")
	}
	if err := e.Previous.Validate(); err != nil {
		return err
	}
	if err := e.Revised.Validate(); err != nil {
		return err
	}
	data, err := json.Marshal(e.Revised)
	if err != nil {
		return err
	}
	var normalized sharedcapacity.Policy
	if err := json.Unmarshal(data, &normalized); err != nil {
		return err
	}
	for name, pool := range e.Previous.Pools {
		next, exists := normalized.Pools[name]
		if !exists || next.Minimum < pool.Minimum || next.Maximum < pool.Maximum {
			return errors.New("pool expansion cannot remove or shrink allocation limits")
		}
		next.Minimum, next.Maximum = pool.Minimum, pool.Maximum
		normalized.Pools[name] = next
	}
	if !samePolicy(normalized, e.Previous) {
		return errors.New("pool expansion cannot change allocation policy beyond limits")
	}
	return nil
}

// ExpandPools commits a reviewed monotonic expansion under the same exclusive
// lease used by all consumers. A crash leaves a closed, resumable transition.
// The caller retains its native fleet lock; this method starts no workloads.
func (l *Lease) ExpandPools(expansion PoolExpansion) error {
	// Decode into a zero value: decoding into the populated request retains
	// omitted optional slices and would not normalize their representation.
	data, err := json.Marshal(expansion)
	if err != nil {
		return err
	}
	var normalized PoolExpansion
	if err := json.Unmarshal(data, &normalized); err != nil {
		return err
	}
	expansion = normalized
	if err := expansion.Validate(); err != nil {
		return err
	}
	if err := l.checkExpansionPublication(); err != nil {
		return err
	}
	current := l.Config
	if current.PoolExpansion != nil {
		if !reflect.DeepEqual(current.PoolExpansion, &expansion) {
			return errors.New("another pool expansion owns recovery")
		}
	} else {
		if current.Mode != "active" {
			return errors.New("closed ownership cannot be converted into pool expansion")
		}
		if samePolicy(current.Policy, expansion.Revised) {
			_, err := (&sharedcapacity.Broker{Path: current.LedgerPath}).Status(&expansion.Revised)
			return err
		}
		if !samePolicy(current.Policy, expansion.Previous) {
			return errors.New("pool expansion previous policy changed")
		}
	}
	broker := sharedcapacity.Broker{Path: current.LedgerPath}
	if err := broker.CheckPolicyChange(&expansion.Previous, &expansion.Revised); err != nil {
		return err
	}
	if current.PoolExpansion == nil {
		next := *current
		next.Mode, next.PoolExpansion = "closed", &expansion
		if err := publishConfig(l.path, &next); err != nil {
			return err
		}
		l.Config = &next
	}
	if err := broker.ReconcilePolicy(&expansion.Previous, &expansion.Revised); err != nil {
		return err
	}
	if err := l.checkExpansionPublication(); err != nil {
		return err
	}
	next := *l.Config
	next.Policy, next.Mode, next.PoolExpansion = expansion.Revised, "active", nil
	if err := publishConfig(l.path, &next); err != nil {
		return err
	}
	l.Config = &next
	return nil
}

func (l *Lease) checkExpansionPublication() error {
	if l == nil || !l.exclusive || l.file == nil || l.Config == nil {
		return errors.New("pool expansion requires a live exclusive policy lease")
	}
	held, err := l.file.Stat()
	if err != nil {
		return err
	}
	observed, err := os.Lstat(l.Config.LockPath)
	if err != nil || !os.SameFile(held, observed) {
		return errors.New("pool expansion lock identity changed")
	}
	current, err := load(l.path, l.Config.Host, l.owner)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(current, l.Config) {
		return errors.New("pool expansion configuration changed")
	}
	parent, err := os.Stat(filepath.Dir(l.path))
	if err != nil {
		return err
	}
	stat, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != l.owner || !parent.IsDir() || parent.Mode().Perm()&0o022 != 0 {
		return errors.New("pool expansion configuration parent is unprotected")
	}
	return nil
}
