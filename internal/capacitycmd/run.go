// Package capacitycmd composes Farm's native controller without a QA runtime.
package capacitycmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"syscall"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
)

// Run requires the native parent's fleet lock for every owner mutation.
func Run(arguments []string, output io.Writer) (result error) {
	if len(arguments) == 1 && arguments[0] == "capabilities" {
		return json.NewEncoder(output).Encode([]string{"fenced-start-memory-v6", "standalone-owner-init-v1"})
	}
	if len(arguments) == 1 && arguments[0] == "version" {
		_, err := fmt.Fprintln(output, "ci-runner-capacity protocol 1")
		return err
	}
	if len(arguments) == 1 && (arguments[0] == "build-limits" || arguments[0] == "scan-repositories") {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		lease, err := hostcapacity.Acquire(ctx, hostcapacity.ConfigPath, false)
		if err != nil {
			return err
		}
		defer func() { result = errors.Join(result, lease.Close()) }()
		return runMetadata(lease.Config, arguments[0], output)
	}
	if os.Geteuid() != 0 || !validArguments(arguments) {
		return errors.New("root and initialize, start|prepare-release|release|refresh-queued <name> <id>, demand-observe <pools>, demand-apply|demand-warm <pools> <targets>, or rebalance|retire|status are required")
	}
	if err := verifyFleetLock(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	lease, err := hostcapacity.Acquire(ctx, hostcapacity.ConfigPath, arguments[0] == "initialize")
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, lease.Close()) }()
	config := lease.Config
	controller := farmcapacity.Controller{
		Broker: sharedcapacity.Broker{Path: config.LedgerPath}, Policy: config.Policy,
		ReceiptRoot: config.ReceiptRoot, Docker: farmcapacity.NativeDocker{},
		RepairCache: farmcapacity.RepairNativeCache, Poisoned: farmcapacity.NativePoisoned,
	}
	if arguments[0] == "initialize" {
		if err := initializeStandalone(ctx, config, &controller); err != nil {
			return err
		}
		return lease.Activate()
	}
	if arguments[0] == "status" {
		diagnostics, err := controller.Broker.Diagnose(&controller.Policy)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(diagnostics)
	}
	if config.Mode != "active" {
		return errors.New("farm shared capacity is closed for ownership reconciliation")
	}
	return runAction(ctx, config, &controller, arguments, output)
}

func validArguments(arguments []string) bool {
	if len(arguments) == 1 {
		return arguments[0] == "initialize" || arguments[0] == "rebalance" || arguments[0] == "retire" || arguments[0] == "status"
	}
	if len(arguments) == 2 {
		return arguments[0] == "demand-observe"
	}
	return len(arguments) == 3 && (arguments[0] == "start" || arguments[0] == "prepare-release" || arguments[0] == "release" || arguments[0] == "refresh-queued" || arguments[0] == "demand-apply" || arguments[0] == "demand-warm")
}

func verifyFleetLock() error {
	file := os.NewFile(8, "native-farm-lock")
	if file == nil {
		return errors.New("native Farm fleet lock is required")
	}
	actual, err := file.Stat()
	if err != nil {
		return err
	}
	wanted, err := os.Lstat("/var/local/emhttp/ci-runner-farm/fleet.lock")
	if err != nil {
		return err
	}
	if !actual.Mode().IsRegular() || !wanted.Mode().IsRegular() || !os.SameFile(actual, wanted) {
		return errors.New("inherited native Farm lock differs")
	}
	if err := syscall.Flock(8, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("native Farm lifecycle is busy")
	}
	return nil
}

func runAction(ctx context.Context, config *hostcapacity.Config, controller *farmcapacity.Controller, arguments []string, output io.Writer) error {
	bind := nativeBinding(controller, config, true)
	switch arguments[0] {
	case "start":
		if err := controller.Start(ctx, arguments[1], arguments[2]); err != nil {
			return err
		}
		return recordRegistration(ctx, controller, config, arguments[1], arguments[2])
	case "prepare-release":
		return controller.PrepareRelease(ctx, arguments[1], arguments[2])
	case "release":
		return controller.Release(ctx, arguments[1], arguments[2])
	case "refresh-queued":
		return controller.PrepareQueuedReplacement(ctx, arguments[1], arguments[2])
	case "rebalance":
		return controller.Rebalance(ctx, bind)
	case "retire":
		if _, err := os.Lstat("/boot/config/plugins/ci-runner-farm/shared-capacity.closed"); err != nil {
			return errors.New("retirement requires native runner starts to be closed")
		}
		return controller.Retire(ctx, nativeBinding(controller, config, false))
	case "demand-observe", "demand-apply", "demand-warm":
		return runDemand(ctx, config, controller, arguments, bind, output)
	default:
		return errors.New("unknown Farm capacity action")
	}
}

func runDemand(ctx context.Context, config *hostcapacity.Config, controller *farmcapacity.Controller, arguments []string, bind farmcapacity.BindOwner, output io.Writer) error {
	if len(arguments[1]) > 16384 {
		return errors.New("farm demand pools exceed the input bound")
	}
	pools, err := farmcapacity.ParseDemandPools(arguments[1], &controller.Policy)
	if err != nil {
		return err
	}
	records := config.Organization + "\x00" + arguments[1]
	if arguments[0] == "demand-observe" {
		observation, err := controller.ObserveDemand(ctx, pools, records, bind)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(observation)
	}
	if len(arguments[2]) > 4096 {
		return errors.New("farm demand target exceeds the input bound")
	}
	decoder := json.NewDecoder(bytes.NewBufferString(arguments[2]))
	decoder.DisallowUnknownFields()
	var starts map[string][]int
	if arguments[0] == "demand-warm" {
		var request farmcapacity.WarmTargets
		if err := decodeDemandTarget(decoder, &request); err != nil {
			return err
		}
		starts, err = controller.WarmStarts(ctx, pools, &request)
	} else {
		var request farmcapacity.DemandTargets
		if err := decodeDemandTarget(decoder, &request); err != nil {
			return err
		}
		starts, err = controller.ApplyDemandTargets(ctx, pools, records, &request, bind)
	}
	if err != nil {
		return err
	}
	for _, pool := range pools {
		for _, index := range starts[pool.ID] {
			if _, err := fmt.Fprintf(output, "%s|%d\n", pool.ID, index); err != nil {
				return err
			}
		}
	}
	return nil
}

func decodeDemandTarget(decoder *json.Decoder, request any) error {
	if err := decoder.Decode(request); err != nil {
		return err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return errors.New("farm demand target has trailing data")
	}
	return nil
}
