// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type ownerTransport func(*http.Request) (*http.Response, error)

func (f ownerTransport) RoundTrip(request *http.Request) (*http.Response, error) { return f(request) }

func remoteFixture(t *testing.T, transport ownerTransport) *FrozenOwner {
	t.Helper()
	path := filepath.Join(t.TempDir(), "credential")
	if err := os.WriteFile(path, []byte("test-credential"), 0o600); err != nil {
		t.Fatal(err)
	}
	return &FrozenOwner{RunnerID: 123, RunnerName: "owned-runner", Organization: "test-org", TokenPath: path, client: &http.Client{Transport: transport}}
}

func ownerResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body))}
}

func TestRemoteAbsenceRequiresScopeAuthorization(t *testing.T) {
	for _, authorized := range []bool{false, true} {
		owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
			if request.URL.Query().Get("per_page") == "1" {
				if !authorized {
					return ownerResponse(http.StatusForbidden, `{}`), nil
				}
				return ownerResponse(http.StatusOK, `{"total_count":0,"runners":[]}`), nil
			}
			return ownerResponse(http.StatusNotFound, `{}`), nil
		})
		gone, err := owner.RemoteGone(context.Background())
		if authorized {
			if !gone || err != nil {
				t.Fatalf("authorized absence: %v", err)
			}
		} else if gone || err == nil {
			t.Fatal("hidden unauthorized runner counted as absent")
		}
	}
}

func TestRemoteIdleRequiresExplicitExactIdentity(t *testing.T) {
	for _, body := range []string{
		`{"id":123,"name":"owned-runner","status":"online"}`,
		`{"id":124,"name":"owned-runner","status":"online","busy":false}`,
		`{"id":123,"name":"other-runner","status":"online","busy":false}`,
		`{"id":123,"name":"owned-runner","status":"unknown","busy":false}`,
	} {
		owner := remoteFixture(t, func(*http.Request) (*http.Response, error) { return ownerResponse(http.StatusOK, body), nil })
		if idle, err := owner.RemoteIdle(context.Background()); idle || err == nil {
			t.Fatal("ambiguous GitHub state accepted")
		}
	}
}

func TestBusyRunnerNeverReachesRemoteDelete(t *testing.T) {
	deletes := 0
	owner := remoteFixture(t, func(request *http.Request) (*http.Response, error) {
		if request.Method == http.MethodDelete {
			deletes++
		}
		return ownerResponse(http.StatusOK, `{"id":123,"name":"owned-runner","status":"online","busy":true}`), nil
	})
	if err := owner.WithdrawRemote(context.Background()); err == nil || deletes != 0 {
		t.Fatal("busy runner deregistered")
	}
}

func TestNativeProcessIdleRequiresListenerAndNoWorker(t *testing.T) {
	for _, item := range []struct {
		data  string
		idle  bool
		known bool
	}{
		{"PID COMMAND\n123 Runner.Listener\n125 dockerd\n", true, true},
		{"PID COMMAND\n123 Runner.Listener\n124 Runner.Worker\n", false, true},
		{"PID COMMAND\n125 dockerd\n", false, false},
		{"PID COMMAND\n0 Runner.Listener\n", false, false},
		{"COMMAND\nRunner.Listener\n", false, false},
		{"PID COMMAND\n123 Runner.Listener\n124 Runner.Listener\n", false, false},
		// Commands with spaces and zombies keep a provable identity.
		{"PID COMMAND\n123 Runner.Listener\n125 Web Content\n126 node <defunct>\n", true, true},
		{"PID COMMAND\n125 Web Content\n123 Runner.Listener\n124 Runner.Worker\n", false, true},
		{"PID COMMAND\n123 Runner.Listener\n124 Runner.Worker <defunct>\n", false, true},
		{"PID COMMAND\n123 Runner.Listener <defunct>\n", false, false},
	} {
		idle, err := nativeProcessesIdle(item.data)
		if idle != item.idle || (err == nil) != item.known {
			t.Fatal("native idle proof differs")
		}
	}
}
