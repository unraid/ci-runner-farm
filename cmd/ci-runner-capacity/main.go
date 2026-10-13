// Command ci-runner-capacity owns Farm's host-local admission lifecycle.
package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/unraid/ci-runner-farm/internal/capacitycmd"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
)

func main() {
	err := capacitycmd.Run(os.Args[1:], os.Stdout)
	if err == nil {
		return
	}
	fmt.Fprintln(os.Stderr, "ci-runner-capacity:", err)
	if errors.Is(err, farmcapacity.ErrQueued) {
		os.Exit(75)
	}
	if errors.Is(err, farmcapacity.ErrCredentialsExpired) {
		os.Exit(76)
	}
	os.Exit(1)
}
