#!/bin/bash
# Optional GitHub App authentication for the GitHub provider.
#
# A personal access token shares its hourly rate limit with everything else
# its account runs. When GH_APP_ID and GH_APP_INSTALLATION_ID are set and the
# App's private key is installed at $GITHUB_APP_KEY_FILE, the Farm uses a
# one-hour installation token instead, which has its own limit. The token is
# minted by bin/ci-runner-capacity into $GITHUB_APP_TOKEN_FILE on tmpfs, so the
# hourly rotation never writes the boot flash, and reused until it is within
# GITHUB_APP_REFRESH_SECONDS of expiry.
#
# Every consumer reads the same minted file: the shell engine through
# ACCESS_TOKEN, and the PHP queue reader and native capacity binary through
# CRF_GITHUB_TOKEN_FILE, which this file exports. App mode never falls back to
# the PAT: without a valid installation token ACCESS_TOKEN is empty, so GitHub
# work pauses (as it does with no token) until a refresh succeeds.
# Sourced by runner-farm.sh before credentials are first loaded.

GITHUB_APP_KEY_FILE="${CFGDIR}/github-app-key.pem"
GITHUB_APP_TOKEN_FILE="${RUNDIR}/github-token"
GITHUB_APP_REFRESH_SECONDS=900
GITHUB_APP_RETRY_SECONDS=30
GITHUB_APP_MODE=false

github_app_configured() {
  [ "${CI_PROVIDER:-github}" = github ] || return 1
  case "${GH_APP_ID:-}" in ''|0|*[!0-9]*) return 1 ;; esac
  case "${GH_APP_INSTALLATION_ID:-}" in ''|0|*[!0-9]*) return 1 ;; esac
  [ -f "$GITHUB_APP_KEY_FILE" ]
}

# Seconds the minted token remains valid, or a negative value when unknown.
github_app_token_seconds_left() {
  local expires
  [ -s "$GITHUB_APP_TOKEN_FILE" ] && [ -f "$GITHUB_APP_TOKEN_FILE.expires" ] || { echo -1; return; }
  read -r expires < "$GITHUB_APP_TOKEN_FILE.expires" 2>/dev/null || { echo -1; return; }
  case "$expires" in ''|*[!0-9]*) echo -1; return ;; esac
  echo $(( expires - $(date +%s) ))
}

# Run the minter at most once at a time, and not again for
# GITHUB_APP_RETRY_SECONDS after a failure. A caller that finds a refresh in
# progress or backing off returns at once and keeps the current token, so a
# GitHub outage costs one request per retry window rather than one per call.
github_app_mint() {
  local retry
  read -r retry 2>/dev/null < "$GITHUB_APP_TOKEN_FILE.retry" || retry=0
  case "$retry" in ''|*[!0-9]*) retry=0 ;; esac
  [ "$(date +%s)" -ge "$retry" ] || return 0
  (
    if command -v flock >/dev/null 2>&1; then
      exec 6>>"$GITHUB_APP_TOKEN_FILE.refresh" || exit 0
      flock -n 6 || exit 0
    fi
    if "${CRF_GITHUB_APP_MINTER:-$SCRIPT_DIR/../bin/ci-runner-capacity}" github-app-token \
        "$GH_APP_ID" "$GH_APP_INSTALLATION_ID" "$GITHUB_APP_KEY_FILE" "$GITHUB_APP_TOKEN_FILE" \
        >/dev/null 2>"$RUNDIR/github-app-token.err"; then
      rm -f "$GITHUB_APP_TOKEN_FILE.retry"
    else
      printf '%s\n' $(( $(date +%s) + GITHUB_APP_RETRY_SECONDS )) > "$GITHUB_APP_TOKEN_FILE.retry"
      printf '[ci-runner-farm] warning: GitHub App token refresh failed: %s\n' \
        "$(head -c 300 "$RUNDIR/github-app-token.err" 2>/dev/null | tr -d '\r\n')" >&2
    fi
  )
}

# Mint when the current token is near expiry, then load it into ACCESS_TOKEN.
# A failed refresh keeps a token that is still valid; an expired or missing
# token leaves ACCESS_TOKEN empty rather than reaching for the PAT.
github_app_load_token() {
  local left
  left="$(github_app_token_seconds_left)"
  if [ "$left" -le "$GITHUB_APP_REFRESH_SECONDS" ]; then
    github_app_mint
    left="$(github_app_token_seconds_left)"
  fi
  if [ "$left" -gt 60 ]; then
    ACCESS_TOKEN="$(tr -d '\r\n' < "$GITHUB_APP_TOKEN_FILE" 2>/dev/null)"
  else
    ACCESS_TOKEN=""
  fi
}

# Select the credential source for this snapshot. Called by reload_secret_files.
github_app_select() {
  if github_app_configured; then
    GITHUB_APP_MODE=true
    export CRF_GITHUB_TOKEN_FILE="$GITHUB_APP_TOKEN_FILE"
    github_app_load_token
  else
    GITHUB_APP_MODE=false
    unset CRF_GITHUB_TOKEN_FILE
    ACCESS_TOKEN="$(read_secret_file "$TOKEN_FILE")"
  fi
}

# Long operations (multi-slot starts, image drains) can outlive a token; GitHub
# callers refresh just before each request. A no-op outside App mode.
github_app_refresh() {
  [ "$GITHUB_APP_MODE" = true ] || return 0
  github_app_load_token
}
