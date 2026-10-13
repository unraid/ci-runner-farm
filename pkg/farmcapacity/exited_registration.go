// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"path"
	"regexp"
	"strings"
)

const (
	diagnosticArchiveLimit = 64 << 20
	diagnosticFileLimit    = 8 << 20
	settingsMarker         = "INFO BrokerMessageListener] {\n"
)

type diagnosticIdentity struct {
	AgentID   int64  `json:"AgentId"`
	AgentName string `json:"AgentName"`
	GitHubURL string `json:"GitHubUrl"`
}

// Legacy ephemeral runners remove .runner after completion. Recover their
// public registration from the exact exited container's native runner settings.
// Live, unknown, ambiguous and foreign owners never use this recovery path.
func exitedRegistration(ctx context.Context, id, organization, name string) (runnerID int64, runnerName string, returnErr error) {
	if !idPattern.MatchString(id) || (!namePattern.MatchString(name) && !legacyNamePattern.MatchString(name)) {
		return 0, "", errors.New("invalid exited native owner identity")
	}
	item, err := (NativeDocker{}).Inspect(ctx, id)
	if err != nil || item.ID != id || item.Name != name || !item.Exited || !item.Managed || item.Provider != githubProvider || item.Role != runnerRole || (!ownedBuildPool(item.Pool, item.Name) && !ownedLegacyBuild(item)) {
		return 0, "", errors.New("cannot attest exited native build registration")
	}
	// #nosec G204 -- immutable ID is restricted to 64 hexadecimal characters above.
	command := exec.CommandContext(ctx, "docker", "cp", id+":/actions-runner/_diag", "-")
	stream, err := command.StdoutPipe()
	if err != nil {
		return 0, "", err
	}
	if err = command.Start(); err != nil {
		return 0, "", errors.New("native registration diagnostics unavailable")
	}
	bounded := &io.LimitedReader{R: stream, N: diagnosticArchiveLimit + 1}
	identity, readErr := diagnosticRegistration(bounded)
	// Drain the bounded archive so Docker can finish; never retain or log diagnostics.
	_, drainErr := io.Copy(io.Discard, bounded)
	closeErr := stream.Close()
	waitErr := command.Wait()
	if readErr != nil || drainErr != nil || closeErr != nil || bounded.N <= 0 || waitErr != nil {
		return 0, "", errors.New("native registration diagnostics are unproved")
	}
	// Host renames must not change the identity of an existing immutable owner.
	expected := item.RegistrationName
	prefix, matched := strings.CutSuffix(expected, "-"+name)
	if !matched || !regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`).MatchString(prefix) {
		return 0, "", errors.New("exited native registration name is not bound to its owned slot")
	}
	if identity.AgentID <= 0 || identity.AgentName != expected || strings.TrimSuffix(identity.GitHubURL, "/") != "https://github.com/"+organization {
		return 0, "", errors.New("exited native registration differs from its owned slot and organization")
	}
	return identity.AgentID, identity.AgentName, nil
}

func diagnosticRegistration(reader io.Reader) (diagnosticIdentity, error) {
	archive := tar.NewReader(reader)
	var identity diagnosticIdentity
	total := int64(0)
	for {
		header, err := archive.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return identity, err
		}
		total += header.Size
		if header.Size < 0 || total > diagnosticArchiveLimit {
			return identity, errors.New("native diagnostics exceed recovery limit")
		}
		file := path.Base(header.Name)
		if header.Typeflag != tar.TypeReg || !strings.HasPrefix(file, "Runner_") || !strings.HasSuffix(file, ".log") {
			continue
		}
		if header.Size > diagnosticFileLimit {
			return identity, errors.New("native runner diagnostic exceeds recovery limit")
		}
		data, err := io.ReadAll(archive)
		if err != nil {
			return identity, err
		}
		identity, err = mergeDiagnosticSettings(identity, data)
		if err != nil {
			return identity, err
		}
	}
	if identity.AgentID == 0 {
		return identity, errors.New("native runner settings identity is missing")
	}
	return identity, nil
}

func mergeDiagnosticSettings(identity diagnosticIdentity, data []byte) (diagnosticIdentity, error) {
	for {
		offset := bytes.Index(data, []byte(settingsMarker))
		if offset < 0 {
			break
		}
		data = data[offset+len(settingsMarker):]
		end := bytes.Index(data, []byte("\n}"))
		if end < 0 {
			return identity, errors.New("native runner settings are incomplete")
		}
		var observed diagnosticIdentity
		if err := json.Unmarshal(append([]byte("{\n"), data[:end+2]...), &observed); err != nil {
			return identity, errors.New("native runner settings are invalid")
		}
		if observed.AgentID <= 0 || observed.AgentName == "" || observed.GitHubURL == "" {
			return identity, errors.New("native runner settings identity is incomplete")
		}
		if identity.AgentID != 0 && identity != observed {
			return identity, errors.New("native runner settings identities are ambiguous")
		}
		identity = observed
		data = data[end+2:]
	}
	return identity, nil
}
