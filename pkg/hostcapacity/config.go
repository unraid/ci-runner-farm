// Package hostcapacity defines Farm's protected host admission contract.
package hostcapacity

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"syscall"

	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"golang.org/x/sys/unix"
)

// ConfigPath is the protected Farm-owned policy entry point for all consumers.
const ConfigPath = "/boot/config/plugins/ci-runner-farm/host-capacity.json"

// Consumer declares a participant's charged classes and fixed guest overhead.
// The participant still owns its own workload identity and stopped-owner proof.
type Consumer struct {
	Pools       []string `json:"pools"`
	OverheadMiB uint64   `json:"overheadMiB,omitempty"`
}

// Config is root-owned operator policy, independent of any consumer's settings.
// Epoch binds participants to one explicit ownership handoff.
type Config struct {
	Schema       int                   `json:"schema"`
	Host         string                `json:"host"`
	Epoch        string                `json:"epoch"`
	Organization string                `json:"organization"`
	LedgerPath   string                `json:"ledgerPath"`
	ReceiptRoot  string                `json:"receiptRoot"`
	TokenPath    string                `json:"tokenPath"`
	LockPath     string                `json:"lockPath"`
	Mode         string                `json:"mode"`
	Policy       sharedcapacity.Policy `json:"policy"`
	Consumers    map[string]Consumer   `json:"consumers,omitempty"`
}

var epochPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)
var organizationPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,38}$`)

// Validate rejects incomplete ownership, unbounded budgets and class ambiguity.
func (c *Config) Validate(host string) error {
	if (c.Mode != "active" && c.Mode != "closed") || c.Schema != 1 || c.Host == "" || c.Host != host || !epochPattern.MatchString(c.Epoch) || !organizationPattern.MatchString(c.Organization) {
		return errors.New("farm host capacity identity is invalid")
	}
	for _, path := range []string{c.LedgerPath, c.ReceiptRoot, c.TokenPath, c.LockPath} {
		if !filepath.IsAbs(path) || filepath.Clean(path) != path || path == "/" {
			return errors.New("farm capacity requires canonical absolute paths")
		}
	}
	if c.LedgerPath == c.ReceiptRoot || c.LockPath == c.LedgerPath || c.TokenPath == c.LedgerPath {
		return errors.New("farm capacity ownership paths overlap")
	}
	if err := c.Policy.Validate(); err != nil {
		return err
	}
	if _, exists := c.Policy.Pools["build"]; !exists {
		return errors.New("farm capacity requires its build allocation class")
	}
	claimed := map[string]bool{"build": true}
	for name, consumer := range c.Consumers {
		if name == "" || len(consumer.Pools) == 0 {
			return errors.New("farm capacity consumer has no charged classes")
		}
		for _, pool := range consumer.Pools {
			if _, exists := c.Policy.Pools[pool]; !exists || claimed[pool] {
				return errors.New("farm capacity consumer class is missing or owned twice")
			}
			claimed[pool] = true
		}
	}
	if len(claimed) != len(c.Policy.Pools) {
		return errors.New("farm capacity has an undeclared consumer class")
	}
	return nil
}

// Load reads only a bounded private regular root-owned configuration file.
func Load(path string) (*Config, error) {
	host, err := os.Hostname()
	if err != nil {
		return nil, err
	}
	return load(path, host, 0)
}

func load(path, host string, owner uint32) (*Config, error) {
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil || canonical != path {
		return nil, errors.New("farm capacity configuration path is absent or symlinked")
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != owner || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || info.Size() > 64*1024 {
		return nil, errors.New("farm capacity configuration is not a bounded private owner file")
	}
	decoder := json.NewDecoder(io.LimitReader(file, 64*1024+1))
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return nil, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, errors.New("farm capacity configuration has trailing data")
	}
	if err := config.Validate(host); err != nil {
		return nil, err
	}
	return &config, nil
}
