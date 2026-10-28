package hostcapacity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func consumerFixture(t *testing.T) (Binding, *Lease) {
	t.Helper()
	file, err := os.CreateTemp(t.TempDir(), "lease-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = file.Close() })
	binding := Binding{ConfigPath: "/farm/host-capacity.json", Epoch: "0123456789abcdef0123456789abcdef", Consumer: "qa-vm-service"}
	config := &Config{Mode: "active", Epoch: binding.Epoch, LedgerPath: "/farm/shared-capacity.bolt", Consumers: map[string]Consumer{binding.Consumer: {Pools: []string{"qa-runner", "qa-guest"}, OverheadMiB: 1024}}, Policy: sharedcapacity.Policy{Budget: sharedcapacity.Resources{MemoryMiB: 65536, VCPUs: 16}, AgingSeconds: 600, Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 4}, Maximum: 12}, "qa-runner": {Cost: sharedcapacity.Resources{MemoryMiB: 1024, VCPUs: 1}, Maximum: 8}, "qa-guest": {Cost: sharedcapacity.Resources{MemoryMiB: 6144, VCPUs: 2}, Maximum: 8}}}}
	return binding, &Lease{Config: config, file: file}
}

func TestConsumerLeaseEnclosesEffectAndCommitWithNestedReuse(t *testing.T) {
	binding, lease := consumerFixture(t)
	acquired := 0
	acquire := func(context.Context, string, bool) (*Lease, error) { acquired++; return lease, nil }
	var saved context.Context
	err := withConsumer(context.Background(), binding, func(ctx context.Context, view View) error {
		saved = ctx
		if view.LedgerPath != lease.Config.LedgerPath || view.OverheadMiB != 1024 || len(view.Pools) != 2 {
			t.Fatal("wrong consumer projection")
		}
		view.Policy.Pools["qa-guest"] = sharedcapacity.Pool{}
		view.Pools[0] = "build"
		if err := withConsumer(ctx, binding, func(_ context.Context, nested View) error {
			if nested.Policy.Pools["qa-guest"].Maximum != 8 || nested.Pools[0] != "qa-runner" {
				t.Fatal("caller mutated pinned policy")
			}
			return nil
		}, acquire); err != nil {
			return err
		}
		// The outer caller commits state and receipts after the nested provider effect.
		if _, err := lease.file.Stat(); err != nil {
			t.Fatal("lease ended before receipt commit", err)
		}
		return nil
	}, acquire)
	if err != nil || acquired != 1 {
		t.Fatalf("nested lease: acquired=%d err=%v", acquired, err)
	}
	if _, err := lease.file.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Fatal("outer lease not closed", err)
	}
	called := false
	if err := withConsumer(saved, binding, func(context.Context, View) error { called = true; return nil }, acquire); err == nil || called || acquired != 1 {
		t.Fatal("expired context reacquired or used the policy")
	}
}

func TestConsumerRejectsChangedOwnershipBeforeEffects(t *testing.T) {
	for _, mode := range []string{"closed", "epoch", "consumer", "acquire", "canceled", "invalid"} {
		t.Run(mode, func(t *testing.T) {
			binding, lease := consumerFixture(t)
			ctx := context.Background()
			switch mode {
			case "closed":
				lease.Config.Mode = "closed"
			case "epoch":
				lease.Config.Epoch = "ffffffffffffffffffffffffffffffff"
			case "consumer":
				delete(lease.Config.Consumers, binding.Consumer)
			case "invalid":
				binding.ConfigPath = "relative"
			case "canceled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			called := false
			acquire := func(context.Context, string, bool) (*Lease, error) {
				if mode == "acquire" {
					return nil, os.ErrPermission
				}
				return lease, nil
			}
			err := withConsumer(ctx, binding, func(context.Context, View) error { called = true; return nil }, acquire)
			if err == nil || called {
				t.Fatal("unproved ownership reached an effect")
			}
		})
	}
}

func TestConsumerFailureReleasesLeaseAndRejectsDifferentNestedOwner(t *testing.T) {
	binding, lease := consumerFixture(t)
	sentinel := errors.New("receipt commit failed")
	acquire := func(context.Context, string, bool) (*Lease, error) { return lease, nil }
	err := withConsumer(context.Background(), binding, func(ctx context.Context, _ View) error {
		other := binding
		other.Epoch = "ffffffffffffffffffffffffffffffff"
		if err := withConsumer(ctx, other, func(context.Context, View) error { t.Fatal("different nested owner admitted"); return nil }, acquire); err == nil {
			t.Fatal("nested owner mismatch accepted")
		}
		return sentinel
	}, acquire)
	if !errors.Is(err, sentinel) {
		t.Fatal("callback failure lost", err)
	}
	if _, err := lease.file.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Fatal("failed callback leaked shared lease")
	}
}

func TestConsumerLeaseBlocksRealWriterUntilReceiptCommit(t *testing.T) {
	root := testRoot(t)
	config := testConfig(root)
	config.Policy.Pools["guest"] = sharedcapacity.Pool{Cost: sharedcapacity.Resources{MemoryMiB: 4096, VCPUs: 2}, Maximum: 2}
	config.Consumers = map[string]Consumer{"guest-provider": {Pools: []string{"guest"}, OverheadMiB: 1024}}
	path := filepath.Join(root, "host-capacity.json")
	writeConfig(t, path, config)
	binding := Binding{ConfigPath: path, Epoch: config.Epoch, Consumer: "guest-provider"}
	acquireLease := func(ctx context.Context, path string, exclusive bool) (*Lease, error) {
		return acquire(ctx, path, exclusive, "test-host", uint32(os.Geteuid()))
	}
	err := withConsumer(context.Background(), binding, func(ctx context.Context, _ View) error {
		if err := withConsumer(ctx, binding, func(context.Context, View) error { return nil }, acquireLease); err != nil {
			return err
		}
		// A policy handoff must still wait after the nested effect and before commit.
		writerCtx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
		defer cancel()
		if writer, err := acquireLease(writerCtx, path, true); !errors.Is(err, context.DeadlineExceeded) || writer != nil {
			t.Fatal("writer crossed pending receipt commit", err)
		}
		return nil
	}, acquireLease)
	if err != nil {
		t.Fatal(err)
	}
	writer, err := acquireLease(context.Background(), path, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestConsumerPanicReleasesSharedLease(t *testing.T) {
	binding, lease := consumerFixture(t)
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("callback panic lost")
			}
		}()
		_ = withConsumer(context.Background(), binding, func(context.Context, View) error { panic("effect panicked") }, func(context.Context, string, bool) (*Lease, error) { return lease, nil })
	}()
	if _, err := lease.file.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Fatal("panic leaked shared policy lease")
	}
}

func TestConsumerCancellationAfterAcquireClosesLeaseBeforeEffects(t *testing.T) {
	binding, lease := consumerFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	called := false
	err := withConsumer(ctx, binding, func(context.Context, View) error { called = true; return nil }, func(context.Context, string, bool) (*Lease, error) { cancel(); return lease, nil })
	if !errors.Is(err, context.Canceled) || called {
		t.Fatal("canceled acquisition reached effect", err)
	}
	if _, err := lease.file.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Fatal("canceled acquisition leaked policy lease")
	}
}
