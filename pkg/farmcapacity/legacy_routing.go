// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"net/http"
	"os"
)

// WithdrawLegacyRouting closes custom build selection without pausing a busy
// worker or deleting its registration. The caller has persisted its exact
// retirement identity under the native fleet and provider configuration locks.
func (o *FrozenOwner) WithdrawLegacyRouting(ctx context.Context) error {
	if !o.Legacy || !legacyNamePattern.MatchString(o.Name) {
		return errors.New("routing withdrawal requires an exact legacy retirement owner")
	}
	if _, err := o.container(ctx); err != nil {
		return err
	}
	return o.withdrawLegacyRemoteRouting(ctx)
}

// WithdrawRetirementRouting binds custom-label withdrawal to an exact named
// builder. The controller persists retirement intent before invoking it.
func (o *FrozenOwner) WithdrawRetirementRouting(ctx context.Context) error {
	if o.Legacy || !namePattern.MatchString(o.Name) {
		return errors.New("retirement requires an exact named builder")
	}
	if _, err := o.container(ctx); err != nil {
		return err
	}
	err := o.withdrawLegacyRemoteRouting(ctx)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (o *FrozenOwner) withdrawLegacyRemoteRouting(ctx context.Context) error {
	runner, err := o.remote(ctx)
	if err != nil {
		return err
	}
	custom, err := customRoutingPresent(runner)
	if err != nil || !custom {
		return err
	}
	var labels struct {
		Labels []struct {
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"labels"`
	}
	if requestErr := o.requestEndpoint(ctx, http.MethodDelete, "/labels", &labels); requestErr != nil {
		return requestErr
	}
	// Re-read the exact registration. Label withdrawal is never idle proof.
	runner, err = o.remote(ctx)
	if err != nil {
		return err
	}
	custom, err = customRoutingPresent(runner)
	if err != nil {
		return err
	}
	if custom {
		return errors.New("legacy custom routing remained after withdrawal")
	}
	return nil
}

func customRoutingPresent(runner remoteRunner) (bool, error) {
	if runner.Labels == nil {
		return false, errors.New("legacy scheduling labels are unproved")
	}
	custom := false
	for _, label := range runner.Labels {
		if label.Name == "" || (label.Type != "custom" && label.Type != "read-only") {
			return false, errors.New("legacy scheduling label identity is unknown")
		}
		custom = custom || label.Type == "custom"
	}
	return custom, nil
}
