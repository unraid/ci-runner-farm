#!/usr/bin/env bash
# Exercise the real GitHub adapter without a Docker daemon or credentials.
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
fail() { printf 'PNPM CACHE FAIL: %s\n' "$*" >&2; exit 1; }
old_confgen() {
  printf '%s\0' '' "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" "$RUNNER_GROUP" "$RUNNER_LABELS" \
    "$EPHEMERAL" "$RUNNER_CPUS" "$RUNNER_MEMORY" "$WORK_TMPFS_SIZE" "$CACHE_MOUNTS" \
    "$USER_SHARE_MOUNTS" "$DIND" "$SHARE_DOCKER_SOCK" "$RUN_AS_ROOT" "$IMAGE_SOURCE" "$IMAGE" \
    "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" \
    "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" | sha256sum | cut -c1-12
}
for dest in /home/runner/.local/share/pnpm/store /opt/custom-store /_work/persistent-store; do
  CACHE_MOUNTS="npm:/home/runner/.npm pnpm-store:$dest"
  github_build_args 1 test-runner || fail 'valid store rejected'
  argv="$(printf '%s\n' "${ARGS[@]}")"
  for value in "PNPM_CONFIG_STORE_DIR=$dest" "npm_config_store_dir=$dest" "$CACHE_ROOT/pnpm-store:$dest"; do
    [ "$(printf '%s\n' "$argv" | grep -Fxc -- "$value")" = 1 ] || fail "missing or duplicate $value"
  done
  [ "$(github_confgen)" != "$(old_confgen)" ] || fail 'existing store slots would not drain'
done
CACHE_MOUNTS=$'npm:/home/runner/.npm\tpnpm-store:/opt/custom-store'
[ "$(github_confgen)" != "$(old_confgen)" ] || fail 'tab-separated cache entries would not drain'
for CACHE_MOUNTS in '' 'npm:/home/runner/.npm'; do
  github_build_args 1 test-runner || fail 'no-store configuration rejected'
  if printf '%s\n' "${ARGS[@]}" | grep -Eqi '(PNPM_CONFIG_STORE_DIR|npm_config_store_dir)='; then
    fail 'configuration without a pnpm bind received store settings'
  fi
  [ "$(github_confgen)" = "$(old_confgen)" ] || fail 'unrelated slots would drain'
done
for entry in pnpm-store pnpm-store: pnpm-store:relative pnpm-store:/ pnpm-store:/_work \
  pnpm-store:/opt/store:ro pnpm-store:/opt//store pnpm-store:/opt/../store pnpm-store:/opt/./store; do
  CACHE_MOUNTS="$entry"
  if github_build_args 1 test-runner >"$tmp/rejection" 2>&1; then fail "accepted $entry"; fi
done
CACHE_MOUNTS='pnpm-store:/opt/one pnpm-store:/opt/two'
if github_build_args 1 test-runner >"$tmp/rejection" 2>&1; then fail 'duplicate store accepted'; fi
# An EXIT trap must fail a green test when cleanup fails, while retaining the
# original failure. Run the actual cleanup function with a mock Docker boundary.
cleanup_function="$(sed -n '/^cleanup() {/,/^}/p' tests/pnpm-store-runtime.sh)"
for scenario in '0 0 0' '0 3 3' '7 3 7'; do
  read -r original cleanup_failure expected <<< "$scenario"
  rc=0
  bash -c '
    tmp="$(mktemp -d)"; suffix=test; image=fixture; containers=(); children=()
    cleanup_failure="$1"
    docker() { [ "$1" != run ] || return "$cleanup_failure"; }
    eval "$3"
    trap cleanup EXIT
    exit "$2"
  ' test "$cleanup_failure" "$original" "$cleanup_function" || rc=$?
  [ "$rc" = "$expected" ] || fail "cleanup lost exit status: $scenario became $rc"
done
printf 'pnpm cache adapter contracts passed.\n'
