// Package hostcapacity defines Farm's protected host admission contract.
package hostcapacity

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
)

// Activate publishes an unchanged closed policy as active while its exclusive
// lease remains held. The caller first persists every owner's allocation and
// receipt. A native start closure remains separate and is not removed here.
func (l *Lease) Activate() error {
	if l == nil || !l.exclusive || l.file == nil || l.Config == nil || l.Config.Mode != "closed" || l.Config.PoolExpansion != nil {
		return errors.New("activation requires a live exclusive closed policy lease")
	}
	held, err := l.file.Stat()
	if err != nil {
		return err
	}
	observed, err := os.Lstat(l.Config.LockPath)
	if err != nil || !os.SameFile(held, observed) {
		return errors.New("farm policy lock identity changed before activation")
	}
	current, err := load(l.path, l.Config.Host, l.owner)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(current, l.Config) {
		return errors.New("farm policy changed before activation")
	}
	parent := filepath.Dir(l.path)
	info, err := os.Stat(parent)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != l.owner || !info.IsDir() || info.Mode().Perm()&0o022 != 0 {
		return errors.New("farm policy parent is not protected from replacement")
	}
	current.Mode = "active"
	if err := publishConfig(l.path, current); err != nil {
		return err
	}
	l.Config = current
	return nil
}

func publishConfig(path string, config *Config) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".host-capacity-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err := file.Chmod(0o600); err != nil {
		return err
	}
	if err := json.NewEncoder(file).Encode(config); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
