// Command ci-runner-auth refreshes GitHub App tokens for runner registration.
package main

import (
	"fmt"
	"os"

	"github.com/unraid/ci-runner-farm/internal/authcmd"
)

func main() {
	if err := authcmd.Run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "ci-runner-auth:", err)
		os.Exit(1)
	}
}
