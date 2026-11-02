// Package authcmd supplies GitHub App authentication for runner registration.
package authcmd

import (
	"errors"
	"io"
)

// Run exposes only the existing runner-registration token minter.
func Run(arguments []string, output io.Writer) error {
	if len(arguments) != 5 || arguments[0] != "github-app-token" {
		return errors.New("github-app-token <app-id> <installation-id> <private-key-file> <token-file> is required")
	}
	return runGitHubAppToken(arguments[1:], output)
}
