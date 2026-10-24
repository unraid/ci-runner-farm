package farmcapacity

import (
	"os"
	"path/filepath"
	"testing"
)

// In GitHub App mode the engine exports the minted installation token, which
// must win over the PAT path baked into the published host capacity config.
func TestMintedTokenOverridesTheConfiguredCredential(t *testing.T) {
	dir := t.TempDir()
	pat := filepath.Join(dir, "token")
	minted := filepath.Join(dir, "github-token")
	if err := os.WriteFile(pat, []byte("github_pat_configured\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(minted, []byte("ghs_minted\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if data, err := readPrivateFarmCredential(pat); err != nil || string(data) != "github_pat_configured\n" {
		t.Fatalf("without an override = %q, %v", data, err)
	}
	t.Setenv(GitHubTokenFileEnv, minted)
	if data, err := readPrivateFarmCredential(pat); err != nil || string(data) != "ghs_minted\n" {
		t.Fatalf("with an override = %q, %v", data, err)
	}
	if err := os.Chmod(minted, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := readPrivateFarmCredential(pat); err == nil {
		t.Fatal("a non-private minted token was accepted")
	}
	t.Setenv(GitHubTokenFileEnv, "relative/github-token")
	if _, err := readPrivateFarmCredential(pat); err == nil {
		t.Fatal("a relative override was accepted")
	}
}
