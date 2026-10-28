// Package capacitycmd composes Farm's native controller without a QA runtime.
package capacitycmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/githubapp"
)

// runGitHubAppToken keeps a token file holding a current installation token:
// github-app-token <app-id> <installation-id> <private-key-file> <token-file>.
// It needs neither the capacity lease nor the fleet lock, because minting is
// independent of capacity state and the token file has its own lock.
func runGitHubAppToken(arguments []string, output io.Writer) error {
	appID, appErr := strconv.ParseInt(arguments[0], 10, 64)
	installationID, installationErr := strconv.ParseInt(arguments[1], 10, 64)
	if appErr != nil || installationErr != nil {
		return errors.New("github-app-token requires numeric app and installation ids")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	minter := githubapp.Minter{AppID: appID, InstallationID: installationID, KeyPath: arguments[2], TokenPath: arguments[3]}
	minted, err := minter.Ensure(ctx)
	if err != nil {
		return err
	}
	state := "current"
	if minted {
		state = "minted"
	}
	_, err = fmt.Fprintln(output, state)
	return err
}
