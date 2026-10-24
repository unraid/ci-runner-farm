#!/usr/bin/env bash
# GitHub App authentication: with an App id, installation id and key the engine
# uses the minted installation token (never the PAT), refreshes it only near
# expiry, exports it to child commands, and leaves PAT mode unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
PAT='github_pat_long_lived_secret_1234567890'
( umask 077; printf '%s\n' "$PAT" > "$CRF_CFGDIR/token" )

fail() { printf 'GITHUB APP AUTH FAIL: %s\n' "$*" >&2; exit 1; }

# A counting stand-in for `ci-runner-capacity github-app-token`.
MINT_LOG="$tmp/mint.log"; : > "$MINT_LOG"
cat > "$tmp/minter" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MINT_LOG"
[ "${MINT_FAIL:-}" != 1 ] || { echo "github app: installation token request returned status 401" >&2; exit 1; }
[ "$1" = github-app-token ] || exit 2
( umask 077; printf '%s\n' "${MINT_TOKEN:-ghs_MintedInstallationToken000001}" > "$5"; printf '%s\n' $(( $(date +%s) + ${MINT_LIFETIME:-3600} )) > "$5.expires" )
echo minted
EOF
chmod +x "$tmp/minter"
export MINT_LOG CRF_GITHUB_APP_MINTER="$tmp/minter"

# PAT mode: no App settings.
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
[ "$GITHUB_APP_MODE" = false ] || fail "PAT host entered App mode"
[ "$ACCESS_TOKEN" = "$PAT" ] || fail "PAT mode did not load the PAT"
[ -z "${CRF_GITHUB_TOKEN_FILE:-}" ] || fail "PAT mode exported a minted token path"
[ ! -s "$MINT_LOG" ] || fail "PAT mode ran the minter"

# App ids without a key stay in PAT mode.
GH_APP_ID=7; GH_APP_INSTALLATION_ID=42
reload_secret_files
[ "$GITHUB_APP_MODE" = false ] || fail "App mode without a private key"

# App mode: ids plus a private key.
( umask 077; printf 'not-a-real-key\n' > "$CRF_CFGDIR/github-app-key.pem" )
reload_secret_files
[ "$GITHUB_APP_MODE" = true ] || fail "App mode was not selected"
[ "$ACCESS_TOKEN" = ghs_MintedInstallationToken000001 ] || fail "App mode did not load the minted token: $ACCESS_TOKEN"
[ "${CRF_GITHUB_TOKEN_FILE:-}" = "$CRF_RUNDIR/github-token" ] || fail "minted token path was not exported"
[ "$(wc -l < "$MINT_LOG" | tr -d ' ')" = 1 ] || fail "first App load did not mint exactly once"
grep -qx "github-app-token 7 42 $CRF_CFGDIR/github-app-key.pem $CRF_RUNDIR/github-token" "$MINT_LOG" \
  || fail "minter arguments changed: $(cat "$MINT_LOG")"
[ "$(provider_token_name)" = "GitHub App installation token" ] || fail "token name does not say App"

# A fresh token is reused: no mint per reload or per request.
reload_secret_files; github_app_refresh
[ "$(wc -l < "$MINT_LOG" | tr -d ' ')" = 1 ] || fail "a fresh token was re-minted"

# Near expiry, the next use refreshes it.
printf '%s\n' $(( $(date +%s) + 600 )) > "$CRF_RUNDIR/github-token.expires"
MINT_TOKEN=ghs_MintedInstallationToken000002 github_app_refresh
[ "$ACCESS_TOKEN" = ghs_MintedInstallationToken000002 ] || fail "near-expiry token was not refreshed"

# A failed refresh keeps a token that is still valid ...
printf '%s\n' $(( $(date +%s) + 300 )) > "$CRF_RUNDIR/github-token.expires"
MINT_FAIL=1 github_app_refresh 2>"$tmp/warn"
[ "$ACCESS_TOKEN" = ghs_MintedInstallationToken000002 ] || fail "a failed refresh dropped a valid token"
grep -q "GitHub App token refresh failed" "$tmp/warn" || fail "a failed refresh was not reported"

# A failure backs off: the next calls inside the retry window do not mint.
mints="$(wc -l < "$MINT_LOG" | tr -d ' ')"
MINT_FAIL=1 github_app_refresh 2>/dev/null; MINT_FAIL=1 github_app_refresh 2>/dev/null
[ "$(wc -l < "$MINT_LOG" | tr -d ' ')" = "$mints" ] || fail "a failed refresh did not back off"
[ "$ACCESS_TOKEN" = ghs_MintedInstallationToken000002 ] || fail "backing off dropped a valid token"
rm -f "$CRF_RUNDIR/github-token.retry"

# A refresh already in progress elsewhere is not duplicated.
if command -v flock >/dev/null 2>&1; then
  ( exec 6>>"$CRF_RUNDIR/github-token.refresh"; flock 6; touch "$tmp/held"; sleep 1 ) &
  holder=$!
  while [ ! -e "$tmp/held" ]; do sleep 0.05; done
  github_app_refresh
  [ "$(wc -l < "$MINT_LOG" | tr -d ' ')" = "$mints" ] || fail "a concurrent refresh started a second minter"
  [ "$ACCESS_TOKEN" = ghs_MintedInstallationToken000002 ] || fail "waiting on a refresh dropped a valid token"
  wait "$holder"
fi

# ... and an expired one fails closed: no PAT fallback anywhere.
printf '%s\n' $(( $(date +%s) - 5 )) > "$CRF_RUNDIR/github-token.expires"
MINT_FAIL=1 github_app_refresh 2>/dev/null
[ -z "$ACCESS_TOKEN" ] || fail "an expired App token was used: $ACCESS_TOKEN"
github_token_ready && fail "token reported ready with no valid installation token"
echo "github 1700000000 7" > "$CRF_RUNDIR/queued.cache"
MINT_FAIL=1 github_queued_refresh 2>/dev/null
[ -z "$ACCESS_TOKEN" ] || fail "queued refresh fell back to the PAT"

# gh_api refreshes before each request and sends the minted token on stdin.
rm -f "$CRF_RUNDIR/github-token" "$CRF_RUNDIR/github-token.expires" "$CRF_RUNDIR/github-token.retry"
CURL_ARGV="$tmp/curl.argv"; CURL_STDIN="$tmp/curl.stdin"
curl() {
  printf '%s\n' "$*" > "$CURL_ARGV"; cat > "$CURL_STDIN"
  local body=/dev/stdout
  while [ "$#" -gt 0 ]; do case "$1" in -o) body="$2"; shift ;; -D) : > "$2"; shift ;; esac; shift; done
  printf '{}\n' > "$body"; printf 200
}
gh_api GET /user >/dev/null || fail "gh_api failed in App mode"
grep -qF "Authorization: Bearer ghs_MintedInstallationToken000001" "$CURL_STDIN" || fail "gh_api did not send the minted token"
if grep -qF ghs_ "$CURL_ARGV"; then fail "the installation token leaked into curl argv"; fi
if grep -qF "$PAT" "$CURL_STDIN"; then fail "gh_api sent the PAT in App mode"; fi

# Clearing the App settings returns to the PAT.
GH_APP_ID=""; GH_APP_INSTALLATION_ID=""
reload_secret_files
[ "$GITHUB_APP_MODE" = false ] && [ "$ACCESS_TOKEN" = "$PAT" ] || fail "clearing App settings did not restore PAT mode"
[ -z "${CRF_GITHUB_TOKEN_FILE:-}" ] || fail "PAT mode kept the minted token export"

echo "github app auth: ok"
