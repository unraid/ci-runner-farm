// Package hostcapacity defines Farm's protected host admission contract.
package hostcapacity

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"strings"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// Binding pins a consumer to an explicitly selected Farm ownership epoch.
// It contains no consumer-owned copy of Farm's policy or ledger location.
type Binding struct {
	ConfigPath string `json:"configPath"`
	Epoch      string `json:"epoch"`
	Consumer   string `json:"consumer"`
}

// Validate rejects ambiguous paths, missing epochs and unnamed consumers.
func (b Binding) Validate() error {
	if !filepath.IsAbs(b.ConfigPath) || filepath.Clean(b.ConfigPath) != b.ConfigPath || b.ConfigPath == "/" || !epochPattern.MatchString(b.Epoch) || b.Consumer == "" || len(b.Consumer) > 128 || strings.ContainsAny(b.Consumer, "\x00\r\n") {
		return errors.New("farm consumer binding is invalid")
	}
	return nil
}

// View is a private snapshot of the pinned policy and this consumer's classes.
// Consumers own their workload proofs; Farm owns policy, paths and overhead.
type View struct {
	Policy      sharedcapacity.Policy
	LedgerPath  string
	Pools       []string
	OverheadMiB uint64
	Epoch       string
}

type consumerContextKey struct{}
type consumerContext struct {
	binding Binding
	lease   *Lease
}

// WithConsumer holds a shared Farm policy lease through operation's return.
// The caller must include its provider effect AND state/receipt commit in that
// operation, after acquiring its existing configuration and owner leases.
// Nested calls with the same binding reuse the pinned lease. A different or
// expired ownership context fails rather than acquiring a second policy lease.
func WithConsumer(ctx context.Context, binding Binding, operation func(context.Context, View) error) error {
	return withConsumer(ctx, binding, operation, Acquire)
}

func withConsumer(ctx context.Context, binding Binding, operation func(context.Context, View) error, acquireLease func(context.Context, string, bool) (*Lease, error)) (result error) {
	if err := binding.Validate(); err != nil {
		return err
	}
	if operation == nil {
		return errors.New("farm consumer operation is missing")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if pinned, ok := ctx.Value(consumerContextKey{}).(*consumerContext); ok {
		if pinned.binding != binding {
			return errors.New("nested farm consumer ownership differs")
		}
		view, err := consumerView(pinned.lease, binding)
		if err != nil {
			return err
		}
		return operation(ctx, view)
	}
	lease, err := acquireLease(ctx, binding.ConfigPath, false)
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, lease.Close()) }()
	view, err := consumerView(lease, binding)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	ctx = context.WithValue(ctx, consumerContextKey{}, &consumerContext{binding: binding, lease: lease})
	return operation(ctx, view)
}

func consumerView(lease *Lease, binding Binding) (View, error) {
	if _, err := lease.file.Stat(); err != nil {
		return View{}, errors.New("farm consumer lease is closed")
	}
	config := lease.Config
	if config.Mode != "active" || config.Epoch != binding.Epoch {
		return View{}, errors.New("farm consumer ownership is closed or changed")
	}
	consumer, ok := config.Consumers[binding.Consumer]
	if !ok {
		return View{}, errors.New("farm consumer is not declared by the host owner")
	}
	policy := config.Policy
	policy.Pools = make(map[string]sharedcapacity.Pool, len(config.Policy.Pools))
	for name, pool := range config.Policy.Pools {
		pool.MinimumRequestIDs = slices.Clone(pool.MinimumRequestIDs)
		policy.Pools[name] = pool
	}
	if policy.BuildMemoryOvercommit != nil {
		overcommit := *policy.BuildMemoryOvercommit
		policy.BuildMemoryOvercommit = &overcommit
	}
	return View{Policy: policy, LedgerPath: config.LedgerPath, Pools: slices.Clone(consumer.Pools), OverheadMiB: consumer.OverheadMiB, Epoch: config.Epoch}, nil
}
