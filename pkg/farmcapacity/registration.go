// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"errors"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// RecordRegistration retains the attested public identity before an ephemeral
// listener exits, so maintenance never guesses a registration from a slot name.
func (c *Controller) RecordRegistration(name, id string, runnerID int64, runnerName string) error {
	if runnerID <= 0 || runnerName == "" {
		return errors.New("native registration identity is incomplete")
	}
	owned, err := c.load(name)
	if err != nil {
		return err
	}
	if owned.ID != id || owned.Fence == "" {
		return errors.New("native registration owner differs")
	}
	if owned.Withdrawal != nil {
		if owned.Withdrawal.ContainerID != id || owned.Withdrawal.Fence != owned.Fence || owned.Withdrawal.RunnerID != runnerID || owned.Withdrawal.RunnerName != runnerName {
			return errors.New("native registration identity changed")
		}
		return nil
	}
	owned.Withdrawal = &sharedcapacity.Withdrawal{ContainerID: id, Fence: owned.Fence, RunnerID: runnerID, RunnerName: runnerName}
	return c.save(name, owned)
}
