// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

func TestLegacyRoutingClosesPersistentBusyPickupWithoutDeregistering(t *testing.T) {
	labels := `[{"name":"build","type":"custom"},{"name":"Linux","type":"read-only"}]`
	removed := 0
	owner := remoteFixture(t, func(req *http.Request) (*http.Response, error) {
		if req.Method == http.MethodDelete {
			if !strings.HasSuffix(req.URL.Path, "/123/labels") {
				t.Fatal("busy runner registration was deleted")
			}
			removed++
			labels = `[{"name":"Linux","type":"read-only"}]`
			return ownerResponse(http.StatusOK, `{"labels":`+labels+`}`), nil
		}
		return ownerResponse(http.StatusOK, fmt.Sprintf(`{"id":123,"name":"owned-runner","status":"online","busy":true,"labels":%s}`, labels)), nil
	})
	for range 2 {
		if err := owner.withdrawLegacyRemoteRouting(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if removed != 1 {
		t.Fatal("routing intent replay repeated an already observed effect")
	}
	if idle, err := owner.RemoteIdle(context.Background()); err != nil || idle {
		t.Fatal("label withdrawal was counted as idle")
	}
}

func TestLegacyRoutingRejectsUnknownAndForeignRemoteIdentity(t *testing.T) {
	for _, body := range []string{
		`{"id":124,"name":"owned-runner","status":"online","busy":true,"labels":[]}`,
		`{"id":123,"name":"owned-runner","status":"online","labels":[]}`,
		`{"id":123,"name":"owned-runner","status":"online","busy":true}`,
		`{"id":123,"name":"owned-runner","status":"online","busy":true,"labels":[{"name":"build"}]}`,
	} {
		owner := remoteFixture(t, func(req *http.Request) (*http.Response, error) {
			if req.Method != http.MethodGet {
				t.Fatal("unknown or foreign routing mutated")
			}
			return ownerResponse(http.StatusOK, body), nil
		})
		if err := owner.withdrawLegacyRemoteRouting(context.Background()); err == nil {
			t.Fatal("unproved remote identity accepted")
		}
	}
}

func TestLegacyRoutingRefusesOrdinarySharedOwner(t *testing.T) {
	owner := &FrozenOwner{Name: testName}
	if err := owner.WithdrawLegacyRouting(context.Background()); err == nil {
		t.Fatal("shared owner entered legacy migration")
	}
}

func TestLegacyDrainPersistsRoutingBeforeBusyWaitAndRetainsFailedRouting(t *testing.T) {
	d, owner, _ := legacyFixture(t)
	owner.busy = true
	if err := d.Run(context.Background()); err == nil || !owner.routingClosed || owner.frozen || owner.gone {
		t.Fatal("busy persistent listener pickup was not closed safely")
	}
	w, err := d.load("ci-runner-1")
	if err != nil || w.Phase != "" || w.RunnerID != 123 {
		t.Fatal("routing retirement identity did not survive restart")
	}
	owner.routingErr = errors.New("routing authorization unknown")
	owner.busy = false
	if err := d.Run(context.Background()); err == nil || owner.frozen || owner.gone {
		t.Fatal("unknown routing effect permitted idle withdrawal")
	}
}
