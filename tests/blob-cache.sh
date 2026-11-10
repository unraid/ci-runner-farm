#!/usr/bin/env bash
# The blob-cache CACHE_MOUNTS entry exports its destination to GitHub runners.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
# shellcheck disable=SC2034 # configuration consumed by sourced provider functions
{
  CACHE_ROOT="$tmp/cache"; ACCESS_TOKEN=''; NO_REGISTER=1
}
GH_SCOPE=org; GH_OWNER=example; DIND=false; SHARE_DOCKER_SOCK=false
NETWORK_ISOLATION=off; WORK_TMPFS_SIZE=64m; RUNNER_LABELS=self-hosted
host() { printf 'mockhost\n'; }
runner_host_service_ipv4() { printf '192.0.2.10\n'; }
fail() { printf 'BLOB CACHE FAIL: %s\n' "$*" >&2; exit 1; }
argv() { printf '%s\n' "${ARGS[@]}"; }

CACHE_MOUNTS='npm:/home/runner/.npm'
github_build_args 1 test-runner || fail 'configuration without a blob cache rejected'
if argv | grep -q '^CI_BLOB_CACHE_DIR='; then fail 'runner without a blob-cache mount received its variable'; fi
before="$(github_confgen)"

for dest in /home/runner/.cache/unraid-blobs /opt/blob-cache; do
  CACHE_MOUNTS="npm:/home/runner/.npm blob-cache:$dest"
  github_build_args 1 test-runner || fail "valid destination $dest rejected"
  for value in "CI_BLOB_CACHE_DIR=$dest" "$CACHE_ROOT/blob-cache:$dest"; do
    [ "$(argv | grep -Fxc -- "$value")" = 1 ] || fail "missing or duplicate $value"
  done
  [ "$(github_confgen)" != "$before" ] || fail 'existing slots would not drain onto the blob cache'
done

# A host that gained the mount before this release must still drain onto the
# new variable, so the fingerprint carries an explicit salt, not only the list.
fingerprint_input() {
  ( sha256sum() { cat > "$tmp/fingerprint"; printf 'stub  -\n'; }; github_confgen >/dev/null )
  tr '\0' '\n' < "$tmp/fingerprint"
}
CACHE_MOUNTS='blob-cache:/opt/blobs'
fingerprint_input | grep -q -- '-blob-cache-v1' || fail 'blob-cache slots carry no drain salt'
CACHE_MOUNTS='npm:/home/runner/.npm'
if fingerprint_input | grep -q -- '-blob-cache-v1'; then fail 'unrelated slots received the blob-cache salt'; fi

# The pnpm store keeps its own variables beside the blob cache.
CACHE_MOUNTS='pnpm-store:/opt/store blob-cache:/opt/blobs'
github_build_args 1 test-runner || fail 'pnpm store and blob cache together rejected'
for value in PNPM_CONFIG_STORE_DIR=/opt/store CI_BLOB_CACHE_DIR=/opt/blobs; do
  [ "$(argv | grep -Fxc -- "$value")" = 1 ] || fail "missing or duplicate $value"
done

for entry in blob-cache blob-cache: blob-cache:relative blob-cache:/ blob-cache:/_work \
  blob-cache:/_work/blobs blob-cache:/opt/blobs:ro blob-cache:/opt//blobs blob-cache:/opt/../blobs \
  blob-cache:/opt/./blobs 'blob-cache:/opt/one blob-cache:/opt/two'; do
  CACHE_MOUNTS="$entry"
  if github_build_args 1 test-runner >"$tmp/rejection" 2>&1; then fail "accepted $entry"; fi
done
printf 'blob cache adapter contracts passed.\n'
