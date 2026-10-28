package capacitycmd

import (
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestStandaloneInitializationIsExplicitAndCannotReplaceSharedOwnership(t *testing.T) {
	if !validArguments([]string{"initialize"}) || validArguments([]string{"initialize", "extra"}) {
		t.Fatal("standalone initialization argument contract differs")
	}
	for _, config := range []*hostcapacity.Config{
		{Mode: "active"},
		{Mode: "closed", Consumers: map[string]hostcapacity.Consumer{"qa": {Pools: []string{"qa"}}}},
		{Mode: "closed", Policy: sharedcapacity.Policy{Pools: map[string]sharedcapacity.Pool{"build": {}, "qa": {}}}},
	} {
		// No controller: a shared or open host must fail before inventory or
		// ledger access, independently of any optional consumer installation.
		if err := initializeStandalone(t.Context(), config, nil); err == nil {
			t.Fatal("shared or active ownership reached standalone initialization")
		}
	}
}
