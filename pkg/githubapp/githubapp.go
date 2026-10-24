// Package githubapp mints GitHub App installation tokens for the Farm.
//
// A long-lived personal access token shares its rate limit with every other
// system that uses the same account. An installation token has its own limit
// (15,000 requests an hour on GitHub Enterprise Cloud), lasts one hour, and is
// scoped to the App's permissions. Minter keeps one current installation token
// in a private file. Every Farm consumer (the shell engine, the PHP queue
// reader and the native capacity binary) reads that file exactly as it read the
// PAT file, so this package is the only place that knows about Apps.
//
// Ensure is safe to call on every tick: it reuses the current token until it
// is within RefreshBefore of expiry, and a file lock makes concurrent callers
// mint at most once. Tokens and private keys never appear in errors.
package githubapp

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// DefaultAPIBase is the public GitHub REST API.
const DefaultAPIBase = "https://api.github.com"

// RefreshBefore is how long before expiry a token is replaced. It exceeds the
// longest Farm tick (300s) plus the work a tick performs with the token.
const RefreshBefore = 15 * time.Minute

const (
	maxKeyBytes   = 16 * 1024
	maxTokenBytes = 8 * 1024
	jwtLifetime   = 9 * time.Minute // GitHub caps App JWTs at 10 minutes.
	jwtBackdate   = time.Minute     // Tolerate host clock skew.
)

// Installation tokens are opaque: GitHub has issued short ghs_ tokens and
// longer forms containing "-" and "." (383 characters in October 2026), so
// accept any single-line token of URL-safe characters rather than one shape.
var tokenPattern = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]+$`)

func validToken(token []byte) bool {
	return len(token) >= 20 && len(token) <= 4096 && tokenPattern.Match(token)
}

// Minter keeps TokenPath holding a current installation token.
type Minter struct {
	AppID          int64
	InstallationID int64
	KeyPath        string
	TokenPath      string
	APIBase        string
	Client         *http.Client
	Now            func() time.Time
}

func (m *Minter) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func (m *Minter) expiryPath() string { return m.TokenPath + ".expires" }

func (m *Minter) validate() error {
	if m.AppID <= 0 || m.InstallationID <= 0 {
		return errors.New("github app: app id and installation id must be positive")
	}
	for _, path := range []string{m.KeyPath, m.TokenPath} {
		if !filepath.IsAbs(path) || filepath.Clean(path) != path {
			return errors.New("github app: key and token paths must be canonical absolute paths")
		}
	}
	if m.KeyPath == m.TokenPath {
		return errors.New("github app: key and token paths must differ")
	}
	return nil
}

// Ensure returns true when it minted a new token and false when the current
// token is still valid for longer than RefreshBefore.
func (m *Minter) Ensure(ctx context.Context) (bool, error) {
	if err := m.validate(); err != nil {
		return false, err
	}
	if m.fresh() {
		return false, nil
	}
	unlock, err := m.lock(ctx)
	if err != nil {
		return false, err
	}
	defer unlock()
	// Another caller may have minted while this one waited for the lock.
	if m.fresh() {
		return false, nil
	}
	key, err := readPrivateKey(m.KeyPath)
	if err != nil {
		return false, err
	}
	jwt, err := signJWT(key, m.AppID, m.now())
	if err != nil {
		return false, err
	}
	token, expires, err := m.mint(ctx, jwt)
	if err != nil {
		return false, err
	}
	// Token first: a missing or stale expiry only causes an early re-mint.
	if err := writePrivate(m.TokenPath, []byte(token+"\n")); err != nil {
		return false, err
	}
	if err := writePrivate(m.expiryPath(), []byte(strconv.FormatInt(expires.Unix(), 10)+"\n")); err != nil {
		return false, err
	}
	return true, nil
}

// fresh reports whether the token file and its expiry describe a token that
// stays valid for longer than RefreshBefore.
func (m *Minter) fresh() bool {
	token, err := readPrivate(m.TokenPath, maxTokenBytes)
	if err != nil || !validToken(bytes.TrimSpace(token)) {
		return false
	}
	raw, err := readPrivate(m.expiryPath(), 64)
	if err != nil {
		return false
	}
	seconds, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		return false
	}
	return time.Unix(seconds, 0).Sub(m.now()) > RefreshBefore
}

func (m *Minter) lock(ctx context.Context) (func(), error) {
	file, err := os.OpenFile(m.TokenPath+".lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, fmt.Errorf("github app: open token lock: %w", err)
	}
	for {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() {
				_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
				_ = file.Close()
			}, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			_ = file.Close()
			return nil, fmt.Errorf("github app: lock token: %w", err)
		}
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, errors.New("github app: timed out waiting for another token refresh")
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (m *Minter) mint(ctx context.Context, jwt string) (string, time.Time, error) {
	base := strings.TrimRight(m.APIBase, "/")
	if base == "" {
		base = DefaultAPIBase
	}
	endpoint := fmt.Sprintf("%s/app/installations/%d/access_tokens", base, m.InstallationID)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, http.NoBody)
	if err != nil {
		return "", time.Time{}, err
	}
	request.Header.Set("Authorization", "Bearer "+jwt)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("User-Agent", "ci-runner-farm")
	client := m.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return "", time.Time{}, errors.New("github app: installation token request did not complete")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if err != nil {
		return "", time.Time{}, errors.New("github app: installation token response was unreadable")
	}
	if response.StatusCode != http.StatusCreated {
		return "", time.Time{}, fmt.Errorf("github app: installation token request returned status %d", response.StatusCode)
	}
	var minted struct {
		Token     string    `json:"token"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := json.Unmarshal(body, &minted); err != nil || !validToken([]byte(minted.Token)) {
		return "", time.Time{}, errors.New("github app: installation token response was malformed")
	}
	if !minted.ExpiresAt.After(m.now().Add(RefreshBefore)) {
		return "", time.Time{}, errors.New("github app: installation token expires too soon")
	}
	return minted.Token, minted.ExpiresAt, nil
}

func signJWT(key *rsa.PrivateKey, appID int64, now time.Time) (string, error) {
	encode := func(value any) (string, error) {
		data, err := json.Marshal(value)
		if err != nil {
			return "", err
		}
		return base64.RawURLEncoding.EncodeToString(data), nil
	}
	header, err := encode(map[string]string{"alg": "RS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	claims, err := encode(map[string]any{
		"iat": now.Add(-jwtBackdate).Unix(),
		"exp": now.Add(jwtLifetime).Unix(),
		"iss": strconv.FormatInt(appID, 10),
	})
	if err != nil {
		return "", err
	}
	signingInput := header + "." + claims
	digest := sha256.Sum256([]byte(signingInput))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return "", errors.New("github app: could not sign the App JWT")
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

// readPrivateKey accepts PKCS#1 ("RSA PRIVATE KEY", as GitHub downloads it)
// and PKCS#8 ("PRIVATE KEY") RSA keys from a private regular file.
func readPrivateKey(path string) (*rsa.PrivateKey, error) {
	data, err := readPrivate(path, maxKeyBytes)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("github app: private key is not PEM")
	}
	switch block.Type {
	case "RSA PRIVATE KEY":
		key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			return nil, errors.New("github app: private key is not a valid PKCS#1 RSA key")
		}
		return key, nil
	case "PRIVATE KEY":
		parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		key, ok := parsed.(*rsa.PrivateKey)
		if err != nil || !ok {
			return nil, errors.New("github app: private key is not a valid PKCS#8 RSA key")
		}
		return key, nil
	default:
		return nil, errors.New("github app: private key must be an RSA PEM key")
	}
}

// readPrivate enforces the same rule as the Farm's other credentials: a
// regular, non-symlink file readable only by its owner.
func readPrivate(path string, limit int64) ([]byte, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > limit {
		return nil, fmt.Errorf("github app: %s must be a private regular file", filepath.Base(path))
	}
	return io.ReadAll(io.LimitReader(file, limit))
}

func writePrivate(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".")
	if err != nil {
		return fmt.Errorf("github app: stage %s: %w", filepath.Base(path), err)
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
