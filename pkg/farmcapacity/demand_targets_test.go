// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"testing"
	"time"
)

func TestFarmTargetsRejectStalePolicyAndIncompleteClassesBeforeEffects(t *testing.T) {
	c, owners, bind, now := demandFixture(t)
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8}, {ID: smallClassPool, Maximum: 8}}
	observation, err := c.ObserveDemand(context.Background(), pools, "bound-scope", bind)
	if err != nil {
		t.Fatal(err)
	}
	good := DemandTargets{Schema: 1, PolicyDigest: observation.PolicyDigest, PoolsDigest: observation.PoolsDigest, ObservedAt: now.Unix(), QueueStartedAt: now.Unix(), Targets: map[string]int{buildPool: 4, smallClassPool: 0}}
	for _, mode := range []string{"schema", "policy", "scope", "expired-observation", "future", "queue", "partial", "extra", "negative", "ceiling", "floor"} {
		t.Run(mode, func(t *testing.T) {
			bad := good
			bad.Targets = map[string]int{buildPool: 4, smallClassPool: 0}
			switch mode {
			case "schema":
				bad.Schema = 2
			case "policy":
				bad.PolicyDigest = "changed-policy"
			case "scope":
				bad.PoolsDigest = "changed-scope"
			case "expired-observation":
				bad.ObservedAt = now.Add(-(demandObservationSeconds + 1) * time.Second).Unix()
			case "future":
				bad.ObservedAt = now.Add(time.Second).Unix()
			case "queue":
				bad.QueueStartedAt = now.Add(-(demandQueueSeconds + 1) * time.Second).Unix()
			case "partial":
				delete(bad.Targets, smallClassPool)
			case "extra":
				bad.Targets["other"] = 0
			case "negative":
				bad.Targets[smallClassPool] = -1
			case "ceiling":
				bad.Targets[smallClassPool] = 9
			case "floor":
				bad.Targets[buildPool] = 3
			}
			if _, applyErr := c.ApplyDemandTargets(context.Background(), pools, "bound-scope", &bad, bind); applyErr == nil {
				t.Fatal("unsafe target accepted")
			}
			for _, owner := range owners {
				if owner.frozen || owner.gone {
					t.Fatal("invalid request mutated an owner")
				}
			}
		})
	}
}

func TestFarmTargetApplyReobservesPickupAndUnknownOwners(t *testing.T) {
	for _, unknown := range []bool{false, true} {
		c, owners, bind, now := demandFixture(t)
		pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8}}
		observation, err := c.ObserveDemand(context.Background(), pools, "scope", bind)
		if err != nil {
			t.Fatal(err)
		}
		// Work can change after Farm calculated a lower target. Apply must preserve
		// every newly busy or unknown owner rather than trusting retained counts.
		for _, owner := range owners {
			owner.busy = !unknown
			owner.unknown = unknown
		}
		request := DemandTargets{Schema: 1, PolicyDigest: observation.PolicyDigest, PoolsDigest: observation.PoolsDigest, ObservedAt: now.Unix(), QueueStartedAt: now.Unix(), Targets: map[string]int{buildPool: 4}}
		starts, err := c.ApplyDemandTargets(context.Background(), pools, "scope", &request, bind)
		if err != nil || len(starts[buildPool]) != 0 {
			t.Fatal(starts, err)
		}
		for _, owner := range owners {
			if owner.frozen || owner.gone {
				t.Fatal("busy/unknown owner retired")
			}
		}
	}
}

func TestFarmTargetsExpireDuringOwnerReobservation(t *testing.T) {
	c, owners, bind, now := demandFixture(t)
	pools := []DemandPool{{ID: buildPool, Minimum: 4, Maximum: 8}}
	observation, err := c.ObserveDemand(t.Context(), pools, "scope", bind)
	if err != nil {
		t.Fatal(err)
	}
	request := DemandTargets{Schema: 1, PolicyDigest: observation.PolicyDigest, PoolsDigest: observation.PoolsDigest, ObservedAt: now.Unix(), QueueStartedAt: now.Unix(), Targets: map[string]int{buildPool: 4}}
	slow := func(ctx context.Context, name, id string, rid int64, rname string) (OwnerBinding, error) {
		*now = now.Add(20 * time.Second)
		return bind(ctx, name, id, rid, rname)
	}
	if _, applyErr := c.ApplyDemandTargets(t.Context(), pools, "scope", &request, slow); applyErr == nil {
		t.Fatal("expired owner observation accepted")
	}
	for _, owner := range owners {
		if owner.frozen || owner.gone {
			t.Fatal("expired observation retired owner")
		}
	}
}
