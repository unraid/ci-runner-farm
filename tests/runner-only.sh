#!/usr/bin/env bash
# Exercise ordinary runner creation and refusal of retired allocator settings.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { echo "runner-only: $*" >&2; exit 1; }

for removed in pkg/sharedcapacity pkg/hostcapacity pkg/farmcapacity internal/capacitycmd cmd/ci-runner-capacity; do
  [ ! -e "$removed" ] || fail "removed allocation surface still exists: $removed"
done
declare -F shared_capacity_call >/dev/null && fail 'QA allocation bridge still exported'
declare -F cmd_shared_activate >/dev/null && fail 'host allocation activation still exported'
declare -F cmd_resume_queued >/dev/null && fail 'allocation resume still exported'

calls="$tmp/calls"
crf_shared_cache_mount() { return 0; }
clear_dangling_endpoint() { printf 'endpoint %s\n' "$1" >> "$calls"; }
docker() { printf 'docker %s\n' "$*" >> "$calls"; }
NAME_PREFIX=ci-runner-build
ARGS=(-d --name ci-runner-build-1 --cpus=4 --memory=12g runner-image)
run_owned_github_container 1 || fail 'ordinary runner creation failed'
grep -qx 'docker run -d --name ci-runner-build-1 --cpus=4 --memory=12g runner-image' "$calls" || fail 'configured Docker limits changed'
[ "$(wc -l < "$calls")" -eq 2 ] || fail 'creation added allocation actions'

for marker in host-capacity.json shared-capacity.owner shared-capacity.enabled shared-capacity.closed; do
  printf 'retained original\n' > "$CFGDIR/$marker"
  : > "$calls"
  if run_owned_github_container 1 >/dev/null 2>&1; then fail "retired $marker admitted start"; fi
  [ ! -s "$calls" ] || fail 'retired configuration dispatched Docker'
  [ "$(cat "$CFGDIR/$marker")" = 'retained original' ] || fail 'old allocation evidence changed'
  rm "$CFGDIR/$marker"
  ln -s "$tmp/missing" "$CFGDIR/$marker"
  if runner_starts_allowed >/dev/null 2>&1; then fail 'broken retired marker accepted'; fi
  rm "$CFGDIR/$marker"
done
for setting in QUEUED_POOLS ELASTIC_POOLS; do
  printf -v "$setting" true
  if runner_starts_allowed >/dev/null 2>&1; then fail "retired $setting accepted"; fi
  printf -v "$setting" false
done
runner_starts_allowed || fail 'ordinary configuration needs host allocation state'
# Invalid saved pool configuration fails visibly before replenishment effects.
(
  CI_PROVIDER=github GH_SCOPE=org AUTOSCALE=false RUNNER_MODE=pools
  RUNNER_POOLS='v3|optional|optional-build|linux,x64|0|0|2|0|2|8g|builtin'
  managed_names() { return 0; }
  : > "$calls"
  pool_base_refresh
  if replenish_fixed_github_capacity; then fail 'invalid fixed pool silently accepted'; fi
  [ ! -s "$calls" ] || fail 'invalid fixed pool dispatched Docker'
)
echo 'runner-only: ordinary limits and creation, removed services and retained-state refusal passed'
