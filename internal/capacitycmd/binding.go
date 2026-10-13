// Package capacitycmd composes Farm's native controller without a QA runtime.
package capacitycmd

import (
	"context"
	"errors"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
)

func nativeBinding(controller *farmcapacity.Controller, config *hostcapacity.Config, publish bool) farmcapacity.BindOwner {
	return func(ctx context.Context, name, id string, runnerID int64, runnerName string) (farmcapacity.OwnerBinding, error) {
		if runnerID == 0 && runnerName != "" {
			owner := &farmcapacity.FrozenOwner{ID: id, Name: name, RunnerName: runnerName, Organization: config.Organization, TokenPath: config.TokenPath, Unregistered: true}
			return farmcapacity.OwnerBinding{Owner: owner, RunnerName: runnerName}, nil
		}
		if runnerID == 0 {
			var identityErr error
			runnerID, runnerName, identityErr = farmcapacity.Registration(ctx, id, config.Organization, name)
			if identityErr != nil {
				owner, recoveryErr := farmcapacity.BindUnregistered(ctx, id, name, config.Organization, config.TokenPath)
				if recoveryErr != nil {
					return farmcapacity.OwnerBinding{}, errors.Join(identityErr, recoveryErr)
				}
				return farmcapacity.OwnerBinding{Owner: owner, RunnerName: owner.RunnerName}, nil
			}
		}
		item, err := controller.Docker.Inspect(ctx, id)
		if publish && err == nil && item.Running && !item.Paused && runnerID > 0 {
			if err := recordAndPublish(ctx, controller, config, name, id, runnerID, runnerName); err != nil {
				return farmcapacity.OwnerBinding{}, err
			}
		}
		owner := &farmcapacity.FrozenOwner{ID: id, Name: name, RunnerID: runnerID, RunnerName: runnerName, Organization: config.Organization, TokenPath: config.TokenPath}
		return farmcapacity.OwnerBinding{Owner: owner, RunnerID: runnerID, RunnerName: runnerName}, nil
	}
}

func recordRegistration(ctx context.Context, controller *farmcapacity.Controller, config *hostcapacity.Config, name, id string) error {
	attempt, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	for {
		runnerID, runnerName, err := farmcapacity.Registration(attempt, id, config.Organization, name)
		if err == nil {
			return recordAndPublish(ctx, controller, config, name, id, runnerID, runnerName)
		}
		timer := time.NewTimer(time.Second)
		select {
		case <-attempt.Done():
			timer.Stop()
			return errors.New("native registration remains unproved; allocation retained")
		case <-timer.C:
		}
	}
}

func recordAndPublish(ctx context.Context, controller *farmcapacity.Controller, config *hostcapacity.Config, name, id string, runnerID int64, runnerName string) error {
	if err := controller.RecordRegistration(name, id, runnerID, runnerName); err != nil {
		return err
	}
	owner := &farmcapacity.FrozenOwner{ID: id, Name: name, RunnerID: runnerID, RunnerName: runnerName, Organization: config.Organization, TokenPath: config.TokenPath}
	return controller.PublishRouting(ctx, owner)
}
