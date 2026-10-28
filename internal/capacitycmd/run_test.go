package capacitycmd

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"reflect"
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

func TestWarmDemandArgumentsAndInvalidTargets(t *testing.T) {
	if !validArguments([]string{"demand-warm", "pools", "targets"}) || validArguments([]string{"demand-warm", "pools"}) {
		t.Fatal("warm command argument contract differs")
	}
	controller := &farmcapacity.Controller{Policy: sharedcapacity.Policy{
		Budget: sharedcapacity.Resources{MemoryMiB: 32768, VCPUs: 8}, AgingSeconds: 60,
		Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}, Minimum: 1, Maximum: 2}},
	}}
	config := &hostcapacity.Config{Organization: "test-org"}
	records := "v3|build|general-build|custom|1|1|2|0|2|12g|inherit"
	for _, target := range []string{`{"unknown":true}`, `{} {}`, strings.Repeat("x", 4097), `{"schema":2,"targets":{"build":1}}`, `{"schema":1,"targets":{"build":2}}`, `{"schema":1,"targets":{"other":1}}`} {
		if err := runDemand(t.Context(), config, controller, []string{"demand-warm", records, target}, nil, &bytes.Buffer{}); err == nil {
			t.Fatal("invalid warm target reached owner planning", target)
		}
	}
	if err := runDemand(t.Context(), config, controller, []string{"demand-warm", strings.Repeat("x", 16385), `{}`}, nil, &bytes.Buffer{}); err == nil {
		t.Fatal("oversized pool input reached owner planning")
	}
}

type missingWarmDocker struct{ calls int }

func (d *missingWarmDocker) Inspect(context.Context, string) (*farmcapacity.Container, error) {
	d.calls++
	return nil, farmcapacity.ErrContainerMissing
}
func (*missingWarmDocker) Start(context.Context, string) error {
	return errors.New("warm planner attempted a start")
}

func TestWarmDemandPrintsAdditivePlanWithoutBindingOrAdmission(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	docker := &missingWarmDocker{}
	controller := &farmcapacity.Controller{Docker: docker, Broker: sharedcapacity.Broker{Path: filepath.Join(root, "capacity.bolt")}, Policy: sharedcapacity.Policy{
		Budget: sharedcapacity.Resources{MemoryMiB: 32768, VCPUs: 8}, AgingSeconds: 60,
		Pools: map[string]sharedcapacity.Pool{"build": {Cost: sharedcapacity.Resources{MemoryMiB: 12288, VCPUs: 2}, Minimum: 1, Maximum: 2}},
	}}
	if err := controller.Broker.Initialize(&controller.Policy, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	before, err := controller.Broker.Status(&controller.Policy)
	if err != nil {
		t.Fatal(err)
	}
	bind := func(context.Context, string, string, int64, string) (farmcapacity.OwnerBinding, error) {
		t.Fatal("warm planning queried remote owner")
		return farmcapacity.OwnerBinding{}, nil
	}
	var output bytes.Buffer
	if err := runDemand(t.Context(), &hostcapacity.Config{Organization: "test-org"}, controller, []string{"demand-warm", "v3|build|general-build|custom|1|1|2|0|2|12g|inherit", `{"schema":1,"targets":{"build":1}}`}, bind, &output); err != nil {
		t.Fatal(err)
	}
	after, err := controller.Broker.Status(&controller.Policy)
	if err != nil || !reflect.DeepEqual(before, after) || output.String() != "build|1\n" || docker.calls != 2 {
		t.Fatal("warm planning changed admission or output", output.String(), docker.calls, err)
	}
}

func TestIdleReconciliationRequiresExactOwnerArguments(t *testing.T) {
	if !validArguments([]string{"reconcile-idle", "slot", "identity"}) {
		t.Fatal("native idle reconciliation is unavailable")
	}
	for _, args := range [][]string{{"reconcile-idle"}, {"reconcile-idle", "slot"}, {"reconcile-idle", "slot", "identity", "extra"}} {
		if validArguments(args) {
			t.Fatal("incomplete reconciliation arguments accepted")
		}
	}
}
