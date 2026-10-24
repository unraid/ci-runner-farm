package githubapp

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// The current GitHub format: long, with "-" and "." separators.
var fakeToken = "ghs_" + strings.Repeat("FAKEtoken0123456789-abcdefABCDEF.", 11) + "end"

type fakeGitHub struct {
	t        *testing.T
	key      *rsa.PublicKey
	appID    string
	status   int
	token    string
	lifetime time.Duration
	now      func() time.Time
	mints    atomic.Int32
}

func (f *fakeGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mints.Add(1)
	if r.Method != http.MethodPost || r.URL.Path != "/app/installations/42/access_tokens" {
		f.t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
	}
	f.verifyJWT(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if f.status != 0 && f.status != http.StatusCreated {
		w.WriteHeader(f.status)
		_, _ = w.Write([]byte(`{"message":"no"}`))
		return
	}
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{"token": f.token, "expires_at": f.now().Add(f.lifetime).UTC()})
}

func (f *fakeGitHub) verifyJWT(jwt string) {
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		f.t.Fatalf("App JWT has %d parts", len(parts))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if err := rsa.VerifyPKCS1v15(f.key, crypto.SHA256, digest[:], signature); err != nil {
		f.t.Fatalf("App JWT signature does not verify: %v", err)
	}
	raw, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var claims struct {
		Iat int64  `json:"iat"`
		Exp int64  `json:"exp"`
		Iss string `json:"iss"`
	}
	if err := json.Unmarshal(raw, &claims); err != nil {
		f.t.Fatal(err)
	}
	now := f.now().Unix()
	if claims.Iss != f.appID || claims.Iat > now || claims.Exp <= now || claims.Exp-claims.Iat > 600 {
		f.t.Fatalf("App JWT claims are invalid: %+v (now %d)", claims, now)
	}
}

type harness struct {
	minter *Minter
	server *fakeGitHub
	clock  *time.Time
	dir    string
}

func newHarness(t *testing.T, pkcs8 bool) *harness {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	block := &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}
	if pkcs8 {
		der, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			t.Fatal(err)
		}
		block = &pem.Block{Type: "PRIVATE KEY", Bytes: der}
	}
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "github-app-key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(block), 0o600); err != nil {
		t.Fatal(err)
	}
	clock := time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)
	now := func() time.Time { return clock }
	h := &harness{clock: &clock, dir: dir}
	h.server = &fakeGitHub{t: t, key: &key.PublicKey, appID: "7", token: fakeToken, lifetime: time.Hour, now: func() time.Time { return *h.clock }}
	server := httptest.NewServer(h.server)
	t.Cleanup(server.Close)
	h.minter = &Minter{AppID: 7, InstallationID: 42, KeyPath: keyPath, TokenPath: filepath.Join(dir, "github-token"),
		APIBase: server.URL, Client: server.Client(), Now: func() time.Time { _ = now; return *h.clock }}
	return h
}

func mode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode().Perm()
}

func TestEnsureMintsAPrivateTokenAndReusesItWhileFresh(t *testing.T) {
	h := newHarness(t, false)
	minted, err := h.minter.Ensure(context.Background())
	if err != nil || !minted {
		t.Fatalf("first Ensure = %v, %v; want a mint", minted, err)
	}
	data, err := os.ReadFile(h.minter.TokenPath)
	if err != nil || strings.TrimSpace(string(data)) != fakeToken {
		t.Fatalf("token file = %q, %v", data, err)
	}
	for _, path := range []string{h.minter.TokenPath, h.minter.TokenPath + ".expires"} {
		if got := mode(t, path); got != 0o600 {
			t.Fatalf("%s mode = %o, want 600", filepath.Base(path), got)
		}
	}
	*h.clock = h.clock.Add(40 * time.Minute) // 20 minutes left: still fresh.
	minted, err = h.minter.Ensure(context.Background())
	if err != nil || minted || h.server.mints.Load() != 1 {
		t.Fatalf("fresh Ensure = %v, %v after %d mints; want reuse", minted, err, h.server.mints.Load())
	}
}

func TestEnsureReplacesATokenNearExpiry(t *testing.T) {
	h := newHarness(t, false)
	if _, err := h.minter.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	*h.clock = h.clock.Add(50 * time.Minute) // 10 minutes left: inside RefreshBefore.
	minted, err := h.minter.Ensure(context.Background())
	if err != nil || !minted || h.server.mints.Load() != 2 {
		t.Fatalf("near-expiry Ensure = %v, %v after %d mints; want a second mint", minted, err, h.server.mints.Load())
	}
}

func TestConcurrentCallersMintOnce(t *testing.T) {
	h := newHarness(t, false)
	var wait sync.WaitGroup
	errs := make(chan error, 5)
	for range 5 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, err := h.minter.Ensure(context.Background())
			errs <- err
		}()
	}
	wait.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := h.server.mints.Load(); got != 1 {
		t.Fatalf("concurrent callers minted %d tokens, want 1", got)
	}
}

func TestPKCS8KeysAreAccepted(t *testing.T) {
	h := newHarness(t, true)
	if minted, err := h.minter.Ensure(context.Background()); err != nil || !minted {
		t.Fatalf("PKCS#8 Ensure = %v, %v", minted, err)
	}
}

func TestPublicKeyFilesAreRefusedBeforeAnyRequest(t *testing.T) {
	h := newHarness(t, false)
	if err := os.Chmod(h.minter.KeyPath, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := h.minter.Ensure(context.Background()); err == nil {
		t.Fatal("a group- or world-readable key was accepted")
	}
	if h.server.mints.Load() != 0 {
		t.Fatal("a request was made with a key that failed validation")
	}
}

func TestFailedMintsLeaveNoTokenAndNoSecretInTheError(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		token  string
		life   time.Duration
	}{
		{"refused", http.StatusUnauthorized, fakeToken, time.Hour},
		{"malformed token", http.StatusCreated, "not a token!", time.Hour},
		{"expires too soon", http.StatusCreated, fakeToken, 5 * time.Minute},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t, false)
			h.server.status, h.server.token, h.server.lifetime = tc.status, tc.token, tc.life
			_, err := h.minter.Ensure(context.Background())
			if err == nil {
				t.Fatal("a failed mint returned success")
			}
			if strings.Contains(err.Error(), fakeToken) || strings.Contains(err.Error(), "PRIVATE KEY") {
				t.Fatalf("error leaks a secret: %v", err)
			}
			if _, statErr := os.Stat(h.minter.TokenPath); !os.IsNotExist(statErr) {
				t.Fatal("a failed mint left a token file")
			}
		})
	}
}

func TestInvalidConfigurationIsRejected(t *testing.T) {
	for _, m := range []Minter{
		{AppID: 0, InstallationID: 1, KeyPath: "/k", TokenPath: "/t"},
		{AppID: 1, InstallationID: 1, KeyPath: "relative", TokenPath: "/t"},
		{AppID: 1, InstallationID: 1, KeyPath: "/same", TokenPath: "/same"},
	} {
		if _, err := m.Ensure(context.Background()); err == nil {
			t.Fatalf("configuration %+v was accepted", m)
		}
	}
}
