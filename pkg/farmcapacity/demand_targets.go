// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"

	"encoding/json"
)

// DemandObservation contains owner facts, never GitHub queue evidence or a
// second resource allocation. The native fleet lock serializes observation.
type DemandObservation struct {
	Schema       int            `json:"schema"`
	PolicyDigest string         `json:"policyDigest"`
	PoolsDigest  string         `json:"poolsDigest"`
	ObservedAt   int64          `json:"observedAt"`
	Retained     map[string]int `json:"retained"`
}

// DemandTargets carries Farm's transient desired counts. Native apply still
// owns admission, exact owner reobservation and fenced idle withdrawal.
type DemandTargets struct {
	Schema         int            `json:"schema"`
	PolicyDigest   string         `json:"policyDigest"`
	PoolsDigest    string         `json:"poolsDigest"`
	ObservedAt     int64          `json:"observedAt"`
	QueueStartedAt int64          `json:"queueStartedAt"`
	Targets        map[string]int `json:"targets"`
}

func demandRecordsDigest(records string) string {
	sum := sha256.Sum256([]byte(records))
	return hex.EncodeToString(sum[:])
}

// ObserveDemand projects exact native owner counts under the existing fleet lock.
func (c *Controller) ObserveDemand(ctx context.Context, pools []DemandPool, records string, bind BindOwner) (*DemandObservation, error) {
	digest, err := policyDigest(c.Policy)
	if err != nil {
		return nil, err
	}
	result := &DemandObservation{Schema: 1, PolicyDigest: digest, PoolsDigest: demandRecordsDigest(records), Retained: map[string]int{}}
	for _, pool := range pools {
		_, _, retained, observeErr := c.observeDemandSlots(ctx, &pool, bind)
		if observeErr != nil {
			return nil, observeErr
		}
		// Busy owners above a lowered ceiling are retained too; the target
		// contract bounds retained by the ceiling, which they already fill.
		result.Retained[pool.ID] = min(retained, pool.Maximum)
	}
	result.ObservedAt = c.now().Unix()
	return result, nil
}

// ApplyDemandTargets validates Farm targets before reobserving and applying owned effects.
func (c *Controller) ApplyDemandTargets(ctx context.Context, pools []DemandPool, records string, request *DemandTargets, bind BindOwner) (map[string][]int, error) {
	digest, err := policyDigest(c.Policy)
	if err != nil {
		return nil, err
	}
	now := c.now().Unix()
	if !demandTargetsFresh(now, request) || request == nil || request.Schema != 1 || request.PolicyDigest != digest || request.PoolsDigest != demandRecordsDigest(records) ||
		len(request.Targets) != len(pools) {
		return nil, errors.New("native demand target identity or freshness differs")
	}
	// Validate every class before any withdrawal or cancellation is considered.
	for _, pool := range pools {
		target, found := request.Targets[pool.ID]
		if !found || target < pool.Minimum || target > pool.Maximum {
			return nil, errors.New("native demand target exceeds protected class bounds")
		}
	}
	starts := map[string][]int{}
	for _, pool := range pools {
		slots, occupied, retained, observeErr := c.observeDemandSlots(ctx, &pool, bind)
		if observeErr != nil {
			return nil, observeErr
		}
		if !demandTargetsFresh(c.now().Unix(), request) {
			return nil, errors.New("native demand target expired during owner observation")
		}
		selected, applyErr := c.applyDemandTarget(ctx, &pool, request.Targets[pool.ID], slots, occupied, retained)
		if applyErr != nil {
			return nil, applyErr
		}
		starts[pool.ID] = selected
	}
	return starts, nil
}

func demandTargetsFresh(now int64, request *DemandTargets) bool {
	return request != nil && request.ObservedAt > 0 && request.ObservedAt <= now && now-request.ObservedAt <= 15 &&
		request.QueueStartedAt > 0 && request.QueueStartedAt <= request.ObservedAt && now-request.QueueStartedAt <= 60
}

// policyDigest preserves the original QA JSON/SHA-256 observation identity.
func policyDigest(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}
