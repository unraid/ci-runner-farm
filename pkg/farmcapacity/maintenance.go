// Package farmcapacity owns native builder admission and fenced lifecycle recovery.
package farmcapacity

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// RepairNativeCache runs only after exact native removal, under fleet.lock.
// It retains image/layer caches and removes only the poisoned BuildKit metadata.
func RepairNativeCache(ctx context.Context, name, root string) error {
	if !namePattern.MatchString(name) || !strings.HasPrefix(root, "/mnt/") || filepath.Clean(root) != root || filepath.Base(root) != name || filepath.Base(filepath.Dir(root)) != "docker" {
		return errors.New("unsafe native Docker cache root")
	}
	canonical, err := filepath.EvalSymlinks(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || canonical != root {
		return errors.New("native Docker cache has uncertain or symlink ownership")
	}
	data, err := exec.CommandContext(ctx, "docker", "ps", "-aq", "--no-trunc").Output()
	if err != nil {
		return errors.New("cannot verify cache writers")
	}
	for id := range strings.FieldsSeq(string(data)) {
		if !idPattern.MatchString(id) {
			return errors.New("invalid cache writer identity")
		}
		mountData, inspectErr := exec.CommandContext(ctx, "docker", "inspect", "--format", "{{json .Mounts}}", id).Output()
		if inspectErr != nil {
			return errors.New("cannot inspect cache writers")
		}
		var mounts []struct {
			Source string `json:"Source"`
		}
		if decodeErr := json.Unmarshal(mountData, &mounts); decodeErr != nil {
			return decodeErr
		}
		for _, mount := range mounts {
			if overlapsCache(root, mount.Source) {
				return errors.New("native cache remains mounted by a container")
			}
		}
	}
	data, err = os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return err
	}
	for line := range strings.SplitSeq(string(data), "\n") {
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			return errors.New("unknown native mount inventory")
		}
		mount := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(fields[4])
		if mount == root || strings.HasPrefix(mount, root+"/") {
			return errors.New("native cache contains a mounted filesystem")
		}
	}
	return os.RemoveAll(filepath.Join(root, "buildkit"))
}

func overlapsCache(root, source string) bool {
	if source == "" || !filepath.IsAbs(source) {
		return false
	}
	return source == root || strings.HasPrefix(source, root+"/") || strings.HasPrefix(root, strings.TrimSuffix(source, "/")+"/")
}

// NativePoisoned accepts only an exact immutable owner marker. Once recorded in
// the durable receipt, reboot or source-marker loss cannot reopen that owner.
func NativePoisoned(name, id string) (bool, error) {
	if !namePattern.MatchString(name) || !idPattern.MatchString(id) {
		return false, errors.New("invalid poison owner identity")
	}
	return readNativePoisonMarker("/var/local/emhttp/ci-runner-farm/poison-pending."+name, id)
}

func readNativePoisonMarker(path, id string) (bool, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Size() > 66 {
		return false, errors.New("unsafe native poison marker")
	}
	data, err := io.ReadAll(io.LimitReader(file, 67))
	if err != nil {
		return false, err
	}
	if len(data) > 66 {
		return false, errors.New("native poison marker grew during read")
	}
	return strings.TrimSpace(string(data)) == id, nil
}
