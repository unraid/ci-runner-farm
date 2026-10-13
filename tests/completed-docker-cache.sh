#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
realpath -m -- / >/dev/null 2>&1 || { echo 'SKIP: GNU realpath required'; exit 0; }
tmp="$(realpath -m -- "$(mktemp -d)")"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { echo "completed Docker cleanup: $*" >&2; exit 1; }
fixture_name=ci-runner-build-1
fixture_id=1111111111111111111111111111111111111111111111111111111111111111
fixture_root="$tmp/cache with spaces"
fixture_store="$fixture_root/docker/$fixture_name"
managed_names() { echo "$fixture_name"; }
managed_runner_snapshot() { echo "$fixture_id|github|runner|1|generation"; }
runner_pool() { echo build; }
pool_activate() { :; }
crf_safe_cache_root() { echo "$fixture_root"; }
crf_docker_storage_references() { [ "$1" = "$fixture_id" ] || return 1; printf '%s\n' "$fixture_references"; }
shared_capacity_prepare_release() { echo prepare >> "$tmp/order"; [ "$fixture_failure" != prepare ]; }
shared_capacity_release() { echo release >> "$tmp/order"; [ "$fixture_failure" != release ]; }
github_remove_runner() { echo remove >> "$tmp/order"; touch "$tmp/removed"; rm -rf "$fixture_store"; }
docker() {
  [ "$1" = inspect ] || return 1
  if [ "$2" != --format ]; then [ ! -e "$tmp/removed" ]; return; fi
  case "$3" in
    *State.Status*)
      [ "$fixture_failure" != inspect ] || return 1
      count=$(cat "$tmp/count"); echo "$((count+1))" > "$tmp/count"
      if [ "$fixture_failure" = restart ] && [ "$count" -gt 0 ]; then echo 'running|true|false|42|no'; else echo "$fixture_state"; fi ;;
    *Mounts*) echo "$fixture_bind" ;;
    *) return 1 ;;
  esac
}
fixture() {
  rm -rf "$fixture_root" "$tmp/removed" "$tmp/order"
  mkdir -p "$fixture_store"; touch "$fixture_store/data"
  fixture_state='exited|false|false|0|no'; fixture_bind="$fixture_store"; fixture_references='mount|/'; fixture_failure=''
  echo 0 > "$tmp/count"
}
fixture
cmd_prune_completed_docker --dry-run >/dev/null
[ -f "$fixture_store/data" ] && [ ! -e "$tmp/order" ] || fail 'dry run changed owner'
cmd_prune_completed_docker --apply >/dev/null
[ ! -e "$fixture_store" ] || fail 'completed fixture_store retained'
[ "$(cat "$tmp/order")" = $'prepare\nremove\nrelease' ] || fail 'release hooks bypassed'
for fixture_state in 'running|true|false|42|no' 'created|false|false|0|no' 'exited|false|true|0|no' 'exited|false|false|0|always'; do
  tested="$fixture_state"; fixture; fixture_state="$tested"
  cmd_prune_completed_docker --apply >/dev/null
  [ -f "$fixture_store/data" ] && [ ! -e "$tmp/order" ] || fail 'live/queued/restarting owner removed'
done
for fixture_failure in prepare inspect restart; do
  tested="$fixture_failure"; fixture; fixture_failure="$tested"
  if cmd_prune_completed_docker --apply >/dev/null 2>&1; then fail "accepted $fixture_failure fixture_failure"; fi
  [ -f "$fixture_store/data" ] || fail 'uncertain owner removed'
done
for fixture_references in "consumer|$fixture_root" "consumer|$fixture_store" "consumer|$fixture_store/child" "mount|$fixture_store/overlay/merged"; do
  tested="$fixture_references"; fixture; fixture_references="$tested"
  if cmd_prune_completed_docker --apply >/dev/null 2>&1; then fail 'overlapping consumer accepted'; fi
  [ -f "$fixture_store/data" ] || fail 'referenced fixture_store removed'
done
fixture; fixture_bind="$fixture_root/unrelated"
if cmd_prune_completed_docker --apply >/dev/null 2>&1; then fail 'wrong owned fixture_bind accepted'; fi
fixture; mv "$fixture_root/docker" "$fixture_root/real-docker"; ln -s "$fixture_root/real-docker" "$fixture_root/docker"
if cmd_prune_completed_docker --apply >/dev/null 2>&1; then fail 'symlink parent accepted'; fi
fixture; fixture_failure=release
if cmd_prune_completed_docker --apply >/dev/null 2>&1; then fail 'failed release reported success'; fi
fixture
DOCKER_CACHE_MIN_FREE_PERCENT=15
df_mode=pressure
df() {
  [ "$df_mode" != unavailable ] || return 1
  if [ "$df_mode" = malformed ]; then echo unknown; return; fi
  echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
  if [ -e "$tmp/removed" ]; then echo 'cache 1000 800 200 80% /cache'; else echo 'cache 1000 950 50 95% /cache'; fi
}
crf_docker_storage_pressure || fail 'pressure not detected'
managed_names() { printf '%s\n' "$fixture_name" ci-runner-build-2; }
cmd_prune_completed_docker --pressure >/dev/null
[ "$(grep -c remove "$tmp/order")" -eq 1 ] || fail 'cleanup continued past free-space threshold'
if crf_docker_storage_pressure; then fail 'healthy disk treated as pressure'; fi
for df_mode in unavailable malformed; do
  if crf_docker_storage_pressure >/dev/null 2>&1; then fail 'unknown disk authorized cleanup'; fi
done
for DOCKER_CACHE_MIN_FREE_PERCENT in 0 101 invalid; do
  if crf_docker_storage_pressure >/dev/null 2>&1; then fail 'disabled/invalid threshold authorized cleanup'; fi
done
DOCKER_CACHE_MIN_FREE_PERCENT=15; df_mode=pressure
fixture
CI_PROVIDER=github DIND=true SHARE_DOCKER_SOCK=false CACHE_ROOT="$fixture_root"
# Exercise the real lifecycle entry point: cleanup must not erase the only
# discovery path for a fixed-size farm. Failed creation retries from config.
fixture_name=ci-runner-1; fixture_store="$fixture_root/docker/$fixture_name"
fixture
RUNNER_MODE=single RUNNER_COUNT=1 AUTOSCALE=false NAME_PREFIX=ci-runner
shared_capacity_enabled() { return 1; }
managed_names() {
  if [ ! -e "$tmp/removed" ] || [ -e "$tmp/recreated" ]; then echo "$fixture_name"; fi
}
provider_token_ready() { return 0; }
provider_validate_settings() { return 0; }
provision_base() { return 0; }
provider_call() { return 0; }
create_fails=false
start_one() {
  echo "$NAME_PREFIX-$1" >> "$tmp/starts"
  [ "$create_fails" = false ] || return 1
  touch "$tmp/recreated"
}
lifecycle_tick >/dev/null
[ "$(cat "$tmp/starts")" = ci-runner-1 ] && [ -e "$tmp/recreated" ] || fail 'fixed slot lost after cleanup'
rm "$tmp/recreated" "$tmp/starts"
fixture; create_fails=true
if lifecycle_tick >/dev/null 2>&1; then fail 'failed replacement reported success'; fi
[ ! -e "$tmp/recreated" ] || fail 'failed replacement invented owner'
create_fails=false
lifecycle_tick >/dev/null
[ "$(wc -l < "$tmp/starts" | tr -d ' ')" -eq 2 ] && [ -e "$tmp/recreated" ] || fail 'missing fixed slot did not retry after cleanup'
rm "$tmp/recreated" "$tmp/starts"
fixture
cmd_prune_completed_docker() { echo attempted > "$tmp/pressure-cleanup"; return 1; }
crf_storage_pressure_cleanup >/dev/null 2>&1 || fail 'cleanup failure blocks normal recovery'
[ -f "$tmp/pressure-cleanup" ] || fail 'pressure cleanup not attempted'
echo 'completed Docker cleanup: immutable offline owners, references, release failures and bounded pressure recovery passed'
