#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'RUNNER POOL GROWTH FAIL: %s\n' "$*" >&2; exit 1; }
CI_PROVIDER=github GH_SCOPE=org RUNNER_MODE=pools AUTOSCALE=true
RUNNER_POOLS='v3|build|general-build|unraid,build|4|4|8|1|1|12g|builtin;v3|build-small|build-small|self-hosted,linux,x64|1|0|24|2|1|4g|builtin;v3|build-large|build-large|self-hosted,linux,x64|1|0|8|1|4|16g|builtin'
pool_base_refresh
validate_runner_mode || fail 'ordinary named pools rejected without an allocator'
mode=empty
managed_names() { [ "$mode" = empty ] || printf 'ci-runner-build-small-1\nci-runner-build-small-2\n'; }
runner_pool() { printf 'build-small'; }
managed_runner_snapshot() { printf 'id%s|github|runner|%s|generation\n' "${1##*-}" "${1##*-}"; }
docker() {
 case "$1" in
 inspect)
  case "$mode" in pending) printf 'created|false' ;; paused) printf 'running|true' ;; *) printf 'running|false' ;; esac ;;
 top)
  case "$mode" in
   unknown) return 1 ;;
   malformed) printf 'COMMAND\nRunner.Listener\nRunner.Worker\n' ;;
   busy) printf 'PID COMMAND\n1 Runner.Listener\n2 Runner.Worker\n' ;;
   idle) printf 'PID COMMAND\n1 Runner.Listener\n' ;;
  esac ;;
 *) fail 'unexpected docker mutation' ;;
 esac
}
[ "$(pool_start_target build)" = 4 ] || fail 'standard floor lost'
[ "$(pool_start_target build-small)" = 2 ] || fail 'small warm headroom lost'
mode=busy
[ "$(pool_start_target build-small)" = 4 ] || fail 'busy small jobs did not expand headroom'
for mode in idle unknown malformed pending paused; do
 [ "$(pool_start_target build-small)" = 2 ] || fail "$mode changed retained slots"
done
mode=busy
RUNNER_POOLS="${RUNNER_POOLS/|0|24|/|0|3|}"
[ "$(pool_start_target build-small)" = 3 ] || fail 'class ceiling ignored'
# Docker errors remain errors; no removed broker status can report success.
start_one() { return 75; }
provider_remote_image_host_pull_required() { return 1; }
if start_configured_capacity; then fail 'Docker failure was treated as queued success'; fi
echo 'runner-pool-growth: floors, busy growth, ceilings, unknown retention and Docker failures passed'
