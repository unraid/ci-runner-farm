package hostcapacity

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func expandedPolicy(t *testing.T, previous sharedcapacity.Policy) sharedcapacity.Policy {
	t.Helper()
	data, err := json.Marshal(previous)
	if err != nil {
		t.Fatal(err)
	}
	var next sharedcapacity.Policy
	if err := json.Unmarshal(data, &next); err != nil {
		t.Fatal(err)
	}
	pool := next.Pools["build"]
	pool.Maximum = 8
	next.Pools["build"] = pool
	return next
}

func TestPoolExpansionPreservesOwnersAndRecoversLedgerCommit(t *testing.T) {
	for _, stage := range []string{"normal", "before-ledger", "after-ledger"} {
		t.Run(stage, func(t *testing.T) {
			root := testRoot(t)
			path := filepath.Join(root, "host-capacity.json")
			config := testConfig(root)
			writeConfig(t, path, config)
			broker := sharedcapacity.Broker{Path: config.LedgerPath}
			if err := broker.Initialize(&config.Policy, func() error { return nil }); err != nil {
				t.Fatal(err)
			}
			decision, err := broker.Admit(&config.Policy, sharedcapacity.Request{ID: "existing", Pool: "build"})
			if err != nil || !decision.Admitted {
				t.Fatal(decision, err)
			}
			for _, id := range []string{"existing-2", "existing-3", "existing-4", "pending-5"} {
				if _, err := broker.Admit(&config.Policy, sharedcapacity.Request{ID: id, Pool: "build"}); err != nil {
					t.Fatal(err)
				}
			}
			before, err := broker.Status(&config.Policy)
			if err != nil {
				t.Fatal(err)
			}
			if len(before.Pending) != 1 {
				t.Fatal("pending owner fixture was not queued")
			}
			expansion := PoolExpansion{Previous: config.Policy, Revised: expandedPolicy(t, config.Policy)}
			if stage != "normal" {
				closed := config
				closed.Mode = "closed"
				closed.PoolExpansion = &expansion
				writeConfig(t, path, closed)
				if stage == "after-ledger" {
					if err := broker.ReconcilePolicy(&expansion.Previous, &expansion.Revised); err != nil {
						t.Fatal(err)
					}
				}
			}
			lease, err := acquire(context.Background(), path, true, config.Host, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			defer lease.Close()
			if err := lease.ExpandPools(expansion); err != nil {
				t.Fatal(err)
			}
			if err := lease.ExpandPools(expansion); err != nil {
				t.Fatal("accepted retry", err)
			}
			after, err := broker.Status(&expansion.Revised)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(before.Grants, after.Grants) || !reflect.DeepEqual(before.Pending, after.Pending) {
				t.Fatal("expansion changed existing ownership")
			}
			if lease.Config.Mode != "active" || lease.Config.PoolExpansion != nil || lease.Config.Epoch != config.Epoch {
				t.Fatal("ownership publication changed")
			}
		})
	}
}

func TestPoolExpansionRejectsPolicyChangesAndSharedLease(t *testing.T) {
	root := testRoot(t)
	config := testConfig(root)
	next := expandedPolicy(t, config.Policy)
	next.Budget.MemoryMiB++
	if err := (&PoolExpansion{Previous: config.Policy, Revised: next}).Validate(); err == nil {
		t.Fatal("budget mutation accepted")
	}
	next = expandedPolicy(t, config.Policy)
	pool := next.Pools["build"]
	pool.Minimum = 0
	next.Pools["build"] = pool
	if err := (&PoolExpansion{Previous: config.Policy, Revised: next}).Validate(); err == nil {
		t.Fatal("floor reduction accepted")
	}
	path := filepath.Join(root, "host-capacity.json")
	writeConfig(t, path, config)
	lease, err := acquire(t.Context(), path, false, config.Host, uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if err := lease.ExpandPools(PoolExpansion{Previous: config.Policy, Revised: expandedPolicy(t, config.Policy)}); err == nil {
		t.Fatal("shared consumer expanded policy")
	}
}

func TestPoolExpansionRejectsUnrelatedClosureAndChangedLock(t *testing.T) {
	for _, scenario := range []string{"unrelated-closure", "replaced-lock", "wrong-transition"} {
		t.Run(scenario, func(t *testing.T) {
			root := testRoot(t)
			path := filepath.Join(root, "host-capacity.json")
			config := testConfig(root)
			expansion := PoolExpansion{Previous: config.Policy, Revised: expandedPolicy(t, config.Policy)}
			if scenario == "unrelated-closure" {
				config.Mode = "closed"
			}
			if scenario == "wrong-transition" {
				config.Mode = "closed"
				other := expansion
				pool := expandedPolicy(t, config.Policy)
				p := pool.Pools["build"]
				p.Maximum = 9
				pool.Pools["build"] = p
				other.Revised = pool
				config.PoolExpansion = &other
			}
			writeConfig(t, path, config)
			lease, err := acquire(t.Context(), path, true, config.Host, uint32(os.Geteuid()))
			if err != nil {
				t.Fatal(err)
			}
			defer lease.Close()
			if scenario == "replaced-lock" {
				if err := os.Rename(config.LockPath, config.LockPath+".old"); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(config.LockPath, nil, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if err := lease.ExpandPools(expansion); err == nil {
				t.Fatal("unsafe expansion accepted")
			}
		})
	}
}

func TestPoolExpansionNormalizesEmptyOptionalSlices(t *testing.T) {
	root := testRoot(t)
	path := filepath.Join(root, "host-capacity.json")
	config := testConfig(root)
	writeConfig(t, path, config)
	broker := sharedcapacity.Broker{Path: config.LedgerPath}
	if err := broker.Initialize(&config.Policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	expansion := PoolExpansion{Previous: config.Policy, Revised: expandedPolicy(t, config.Policy)}
	pool := expansion.Revised.Pools["build"]
	pool.MinimumRequestIDs = []string{}
	expansion.Revised.Pools["build"] = pool
	lease, err := acquire(t.Context(), path, true, config.Host, uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	if err := lease.ExpandPools(expansion); err != nil {
		t.Fatal("optional empty slice stranded expansion", err)
	}
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	retry, err := acquire(t.Context(), path, true, config.Host, uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	defer retry.Close()
	if err := retry.ExpandPools(expansion); err != nil {
		t.Fatal("same unnormalized request did not replay", err)
	}
	if retry.Config.Mode != "active" || retry.Config.PoolExpansion != nil {
		t.Fatal("expansion remained closed")
	}
}
