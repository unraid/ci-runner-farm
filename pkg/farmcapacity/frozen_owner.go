// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// FrozenOwner is restricted to one immutable native build and its registration.
type FrozenOwner struct {
	ID           string
	Name         string
	RunnerID     int64
	RunnerName   string
	Organization string
	Legacy       bool
	Unregistered bool
	TokenPath    string
	client       *http.Client
}

// Registration reads only public agent identity, never runner credentials.
func Registration(ctx context.Context, id, organization, name string) (runnerID int64, runnerName string, returnErr error) {
	return registration(ctx, id, organization, name, false)
}

// LegacyRegistration is restricted to native default-pool retirement.
func LegacyRegistration(ctx context.Context, id, organization, name string) (runnerID int64, runnerName string, returnErr error) {
	item, err := (NativeDocker{}).Inspect(ctx, id)
	if err != nil || item.ID != id || item.Name != name || !ownedLegacyBuild(item) {
		return 0, "", errors.New("legacy registration is not an exact native default owner")
	}
	return registration(ctx, id, organization, name, true)
}

func registration(ctx context.Context, id, organization, name string, legacy bool) (runnerID int64, runnerName string, returnErr error) {
	if !idPattern.MatchString(id) || (!namePattern.MatchString(name) && (!legacy || !legacyNamePattern.MatchString(name))) {
		return 0, "", errors.New("invalid native build identity")
	}
	const identityScript = `for file in .runner /home/runner/.runner /home/runner/actions-runner/.runner /actions-runner/.runner /runner/.runner; do if [ -f "$file" ]; then cat "$file"; exit; fi; done; exit 1`
	data, err := exec.CommandContext(ctx, "docker", "exec", id, "sh", "-c", identityScript).Output()
	if err != nil {
		return exitedRegistration(ctx, id, organization, name)
	}
	// GitHub's runner writes UTF-8 BOM-prefixed identity files. Match the
	// existing QA listener parser without relaxing the identity checks below.
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	var identity struct {
		AgentID   int64  `json:"agentId"`
		AgentName string `json:"agentName"`
		GitHubURL string `json:"gitHubUrl"`
	}
	if decodeErr := json.Unmarshal(data, &identity); decodeErr != nil {
		return 0, "", decodeErr
	}
	item, err := (NativeDocker{}).Inspect(ctx, id)
	if err != nil || item.ID != id || item.Name != name || !item.Managed || item.Provider != githubProvider || item.Role != runnerRole || (!ownedBuildPool(item.Pool, item.Name) && (!legacy || !ownedLegacyBuild(item))) {
		return 0, "", errors.New("native agent owner identity differs")
	}
	expectedName := item.RegistrationName
	if !registrationNameMatches(name, expectedName, legacy) {
		return 0, "", errors.New("native registration name does not match the owned slot")
	}
	if identity.AgentID <= 0 || identity.AgentName != expectedName || strings.TrimSuffix(identity.GitHubURL, "/") != "https://github.com/"+organization {
		return 0, "", errors.New("native agent does not match the configured organization and owned slot")
	}
	return identity.AgentID, identity.AgentName, nil
}

func (o *FrozenOwner) container(ctx context.Context) (*Container, error) {
	item, err := (NativeDocker{}).Inspect(ctx, o.ID)
	if err != nil {
		return nil, err
	}
	if item.ID != o.ID || item.Name != o.Name || !item.Managed || item.Provider != githubProvider || item.Role != runnerRole || (!ownedBuildPool(item.Pool, item.Name) && (!o.Legacy || !ownedLegacyBuild(item))) {
		return nil, errors.New("frozen native owner identity differs")
	}
	return item, nil
}

// Freeze closes every local job-pickup path before idle proof. A racing worker
// is resumed immediately by the coordinator and keeps its allocation.
func (o *FrozenOwner) Freeze(ctx context.Context) error {
	item, err := o.container(ctx)
	if err != nil {
		return err
	}
	if item.Exited {
		return nil
	}
	if o.Unregistered {
		return errors.New("unregistered recovery requires an exited native owner")
	}
	if !item.Running {
		return errors.New("idle withdrawal requires a live listener or an attested exited owner")
	}
	if item.Paused {
		return nil
	}
	return o.docker(ctx, "pause")
}

// FrozenIdle uses host-visible native process names; docker exec cannot run in
// a paused container. A positively exited PID-zero owner is already closed;
// log-derived idle state is never accepted as proof.
func (o *FrozenOwner) FrozenIdle(ctx context.Context) (bool, error) {
	item, err := o.container(ctx)
	if err != nil {
		return false, err
	}
	if item.Exited {
		if o.Unregistered && (!item.RoutingGated || item.RegistrationName != o.RunnerName) {
			return false, errors.New("unregistered native owner changed")
		}
		return true, nil
	}
	if o.Unregistered {
		return false, errors.New("unregistered native owner is not exited")
	}
	if !item.Paused || !item.Running {
		return false, errors.New("native job pickup is not frozen")
	}
	return o.nativeIdle(ctx)
}

// Idle supplies planning evidence only. Withdrawal must freeze and prove idle
// again before any effect; this observation cannot authorize removal.
func (o *FrozenOwner) Idle(ctx context.Context) (bool, error) {
	item, err := o.container(ctx)
	if err != nil {
		return false, err
	}
	if item.Exited {
		return o.RemoteIdle(ctx)
	}
	if !item.Running {
		return false, errors.New("native listener is not running")
	}
	idle, err := o.nativeIdle(ctx)
	if err != nil || !idle {
		return idle, err
	}
	return o.RemoteIdle(ctx)
}

func (o *FrozenOwner) nativeIdle(ctx context.Context) (bool, error) {
	if !idPattern.MatchString(o.ID) {
		return false, errors.New("invalid native process owner ID")
	}
	data, err := exec.CommandContext(ctx, "docker", "top", o.ID, "-eo", "pid,comm").Output() // #nosec G204 -- strict immutable hex ID validation above; no shell or arbitrary executable.
	if err != nil {
		return false, errors.New("cannot inspect native runner processes")
	}
	return nativeProcessesIdle(string(data))
}

func nativeProcessesIdle(data string) (bool, error) {
	listeners := 0
	for line := range strings.SplitSeq(data, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || (len(fields) == 2 && fields[0] == "PID" && fields[1] == "COMMAND") {
			continue
		}
		// comm may contain spaces ("Web Content") and zombies render as
		// "name <defunct>", so the command is everything after the PID.
		if len(fields) < 2 {
			return false, errors.New("native process identity is incomplete")
		}
		pid, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil || pid == 0 {
			return false, errors.New("native process PID is unproved")
		}
		// A zombie worker still marks a job that has not settled.
		if fields[1] == "Runner.Worker" {
			return false, nil
		}
		if strings.Join(fields[1:], " ") == "Runner.Listener" {
			listeners++
		}
	}
	if listeners != 1 {
		return false, errors.New("native runner listener state is unknown")
	}
	return true, nil
}

// Resume never changes immutable ownership or the retained allocation.
func (o *FrozenOwner) Resume(ctx context.Context) error {
	item, err := o.container(ctx)
	if err != nil {
		return err
	}
	if item.Exited {
		return nil
	}
	return o.docker(ctx, "unpause")
}

type remoteRunner struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	Status string `json:"status"`
	Busy   *bool  `json:"busy"`
	Labels []struct {
		Name string `json:"name"`
		Type string `json:"type"`
	} `json:"labels"`
}

func (o *FrozenOwner) remote(ctx context.Context) (remoteRunner, error) {
	var runner remoteRunner
	if err := o.request(ctx, http.MethodGet, &runner); err != nil {
		return runner, err
	}
	if runner.ID != o.RunnerID || runner.Name != o.RunnerName || runner.Busy == nil || (runner.Status != "online" && runner.Status != "offline") {
		return runner, errors.New("GitHub native runner identity or busy state differs")
	}
	return runner, nil
}

// RegistrationGone proposes recovery only for a positively idle native listener
// whose exact saved registration is authoritatively absent. Withdrawal must
// freeze and repeat both proofs before any removal or release.
func (o *FrozenOwner) RegistrationGone(ctx context.Context) (bool, error) {
	item, err := o.container(ctx)
	if err != nil {
		return false, err
	}
	if !item.Running {
		return false, nil
	}
	idle, err := o.nativeIdle(ctx)
	if err != nil || !idle {
		return false, err
	}
	return o.RemoteGone(ctx)
}

// RemoteIdle requires a fresh exact registration and explicit busy=false.
func (o *FrozenOwner) RemoteIdle(ctx context.Context) (bool, error) {
	if o.Unregistered {
		return o.RemoteGone(ctx)
	}
	item, err := o.remote(ctx)
	if errors.Is(err, os.ErrNotExist) {
		native, nativeErr := o.container(ctx)
		if nativeErr != nil {
			return false, nativeErr
		}
		if native.Exited {
			return true, nil
		}
		if native.Running && native.Paused {
			return o.nativeIdle(ctx)
		}
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return !*item.Busy, nil
}

// WithdrawRemote deletes only the exact idle registration while pickup is frozen.
func (o *FrozenOwner) WithdrawRemote(ctx context.Context) error {
	if o.Unregistered {
		gone, err := o.RemoteGone(ctx)
		if err != nil {
			return err
		}
		if !gone {
			return errors.New("unregistered native name exists remotely")
		}
		return nil
	}
	idle, err := o.RemoteIdle(ctx)
	if err != nil {
		return err
	}
	if !idle {
		return errors.New("GitHub native runner became busy")
	}
	gone, goneErr := o.RemoteGone(ctx)
	if goneErr != nil {
		return goneErr
	}
	if gone {
		return nil
	}
	return o.request(ctx, http.MethodDelete, nil)
}

// RemoteGone distinguishes an authoritative 404 from network/auth/API failures.
func (o *FrozenOwner) RemoteGone(ctx context.Context) (bool, error) {
	if o.Unregistered {
		return o.unregisteredGone(ctx)
	}
	_, err := o.remote(ctx)
	if errors.Is(err, os.ErrNotExist) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return false, nil
}

// RegistrationNameGone reuses complete, authorized scope pagination. It only
// proves absence and never deletes a registration by its reusable name.
func (o *FrozenOwner) RegistrationNameGone(ctx context.Context) (bool, error) {
	absence := *o
	absence.RunnerID = 0
	return absence.unregisteredGone(ctx)
}

// Terminated proves exact native exit with automatic restart disabled. It does
// not establish remote absence or authorize release on its own.
func (o *FrozenOwner) Terminated(ctx context.Context) (bool, error) {
	item, err := o.container(ctx)
	if err != nil {
		return false, err
	}
	return item.Terminated, nil
}

// RemoveTerminated refuses a restarted owner. Docker's non-forced removal
// closes the race between the final inspection and native deletion.
func (o *FrozenOwner) RemoveTerminated(ctx context.Context) error {
	terminated, err := o.Terminated(ctx)
	if err != nil {
		return err
	}
	if !terminated {
		return errors.New("native owner is not positively terminated")
	}
	if err := o.docker(ctx, "rm"); err != nil {
		return err
	}
	return o.confirmRemoved(ctx)
}

// RemoveFrozen never thaws a listener before deleting its native container.
func (o *FrozenOwner) RemoveFrozen(ctx context.Context) error {
	idle, err := o.FrozenIdle(ctx)
	if err != nil {
		return err
	}
	if !idle {
		return errors.New("native worker appeared before frozen removal")
	}
	if removeErr := o.docker(ctx, "rm", "--force"); removeErr != nil {
		return removeErr
	}
	return o.confirmRemoved(ctx)
}

func (o *FrozenOwner) confirmRemoved(ctx context.Context) error {
	removed, err := o.Removed(ctx)
	if err != nil {
		return err
	}
	if !removed {
		return errors.New("native frozen removal was not confirmed")
	}
	if o.Unregistered {
		gone, proofErr := o.RemoteGone(ctx)
		if proofErr != nil {
			return proofErr
		}
		if !gone {
			return errors.New("unregistered native name appeared after removal")
		}
	}
	return nil
}

// Removed proves both the old ID and its stable name are absent.
func (o *FrozenOwner) Removed(ctx context.Context) (bool, error) {
	for _, identity := range []string{o.ID, o.Name} {
		_, err := (NativeDocker{}).Inspect(ctx, identity)
		if errors.Is(err, ErrContainerMissing) {
			continue
		}
		if err != nil {
			return false, err
		}
		return false, nil
	}
	return true, nil
}

func (o *FrozenOwner) docker(ctx context.Context, action string, arguments ...string) error {
	if !idPattern.MatchString(o.ID) {
		return errors.New("invalid frozen container ID")
	}
	args := append([]string{action}, arguments...)
	args = append(args, o.ID)
	if err := exec.CommandContext(ctx, "docker", args...).Run(); err != nil {
		return fmt.Errorf("native frozen owner %s did not complete", action)
	}
	return nil
}

func (o *FrozenOwner) request(ctx context.Context, method string, result *remoteRunner) error {
	return o.requestEndpoint(ctx, method, "", result)
}

func (o *FrozenOwner) requestEndpoint(ctx context.Context, method, suffix string, result any) error {
	data, err := readPrivateFarmCredential(o.TokenPath)
	if err != nil {
		return err
	}
	token := strings.TrimSpace(string(data))
	if token == "" || strings.ContainsAny(token, "\r\n") {
		return errors.New("native farm credential is invalid")
	}
	endpoint := "https://api.github.com/orgs/" + url.PathEscape(o.Organization) + "/actions/runners/" + strconv.FormatInt(o.RunnerID, 10) + suffix
	req, err := http.NewRequestWithContext(ctx, method, endpoint, http.NoBody)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	client := o.client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	response, err := client.Do(req)
	if err != nil {
		return errors.New("GitHub native withdrawal request did not complete")
	}
	defer response.Body.Close()
	if method == http.MethodGet && response.StatusCode == http.StatusNotFound {
		// GitHub hides unauthorized resources with 404. Prove list permission in
		// this exact organization before accepting absence of the owned ID.
		if accessErr := o.verifyScopeAccess(ctx, client, token); accessErr != nil {
			return accessErr
		}
		return os.ErrNotExist
	}
	expected := http.StatusOK
	if method == http.MethodDelete && suffix == "" {
		expected = http.StatusNoContent
	}
	if response.StatusCode != expected {
		return fmt.Errorf("GitHub native withdrawal returned status %d", response.StatusCode)
	}
	if result != nil {
		return json.NewDecoder(response.Body).Decode(result)
	}
	return nil
}

func (o *FrozenOwner) verifyScopeAccess(ctx context.Context, client *http.Client, token string) error {
	endpoint := "https://api.github.com/orgs/" + url.PathEscape(o.Organization) + "/actions/runners?per_page=1"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, http.NoBody)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	response, err := client.Do(req)
	if err != nil {
		return errors.New("GitHub native runner scope permission is unproved")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errors.New("GitHub native runner scope permission is unproved")
	}
	var listing struct {
		Total   *int              `json:"total_count"`
		Runners []json.RawMessage `json:"runners"`
	}
	if err := json.NewDecoder(response.Body).Decode(&listing); err != nil {
		return err
	}
	if listing.Total == nil || *listing.Total < 0 || listing.Runners == nil {
		return errors.New("GitHub native runner scope response is invalid")
	}
	return nil
}

// GitHubTokenFileEnv names the minted GitHub App installation token the Farm
// exports to the commands it spawns. It overrides the configured PAT path so
// App mode needs no change to the published host capacity config.
const GitHubTokenFileEnv = "CRF_GITHUB_TOKEN_FILE"

func readPrivateFarmCredential(path string) ([]byte, error) {
	if override := os.Getenv(GitHubTokenFileEnv); override != "" {
		if !filepath.IsAbs(override) || filepath.Clean(override) != override {
			return nil, errors.New("native farm credential override must be a canonical absolute path")
		}
		path = override
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 16*1024 {
		return nil, errors.New("native farm credential must be a private regular file")
	}
	data, err := io.ReadAll(io.LimitReader(file, 16*1024+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 16*1024 {
		return nil, errors.New("native farm credential exceeds its private bound")
	}
	return data, nil
}
