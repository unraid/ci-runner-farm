package capacitycmd

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

func TestVersionRequiresNoProviderConfiguration(t *testing.T) {
	var output bytes.Buffer
	if err := Run([]string{"version"}, &output); err != nil || output.String() != "ci-runner-capacity protocol 1\n" {
		t.Fatal("standalone executable requires external configuration", output.String(), err)
	}
}

func TestUnknownAndLegacyCommandsCannotReachOwners(t *testing.T) {
	for _, arguments := range [][]string{nil, {"scale", "records"}, {"adopt"}, {"start"}, {"release", "slot"}, {"rebalance", "extra"}, {"demand-apply", "records"}} {
		if validArguments(arguments) {
			t.Fatal("unsupported command was accepted", arguments)
		}
	}
}

func TestDemandRejectsMalformedTargetsBeforeOwnerObservation(t *testing.T) {
	controller := &farmcapacity.Controller{Policy: sharedcapacity.Policy{
		Budget: sharedcapacity.Resources{MemoryMiB: 32768, VCPUs: 8}, AgingSeconds: 60,
		Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}, Minimum: 1, Maximum: 2}},
	}}
	config := &hostcapacity.Config{Organization: "test-org"}
	records := "v3|build|general-build|custom|1|1|2|0|2|12g|inherit"
	for _, target := range []string{`{"unknown":true}`, `{} {}`, strings.Repeat("x", 4097), `{"schema":1}`} {
		// Docker is deliberately absent: invalid input must fail before any
		// observation, cancellation, routing change or container effect.
		err := runDemand(context.Background(), config, controller, []string{"demand-apply", records, target}, nil, &bytes.Buffer{})
		if err == nil {
			t.Fatal("invalid target was accepted", target)
		}
	}
}
