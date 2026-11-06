#!/usr/bin/env bash
# Legacy recovery must replace dead slots without using logs to infer idle.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'LIFECYCLE ENFORCEMENT FAIL: %s\n' "$*" >&2; exit 1; }
CI_PROVIDER=github
RUNNER_COUNT=1
DIND=true
LIFECYCLE_CONFIRMATIONS=2
OWNER_ID=owner-1
NATIVE_STATE='running|true|false|false|123'
INSPECT_RESULT=0
managed_names() { printf 'ci-runner-1\n'; }
managed_runner_snapshot() { printf '%s|github|runner|1|test-generation\n' "$OWNER_ID"; }
# Old logs/native heuristics report idle even when inspection is unavailable.
runner_state() { echo idle; }
github_runner_state() { echo idle; }
docker() {
  case "${1:-}" in
    inspect) [ "$INSPECT_RESULT" -eq 0 ] || return 1; printf '%s\n' "$NATIVE_STATE" ;;
    *) fail 'watchdog attempted live process inspection or cleanup' ;;
  esac
}
marker="$CRF_RUNDIR/github-lifecycle.ci-runner-1"
for NATIVE_STATE in 'running|true|false|false|123' 'running|true|true|false|123' 'restarting|false|false|true|0' 'exited|false|false|false|123' ''; do
  printf '%s 9\n' "$OWNER_ID" > "$marker"
  [ -z "$(github_lifecycle_candidates)" ] || fail "unsafe native state became candidate: $NATIVE_STATE"
  [ ! -e "$marker" ] || fail 'unknown/live state retained confirmation'
done
INSPECT_RESULT=1
[ -z "$(github_lifecycle_candidates)" ] || fail 'failed inspection became candidate'
INSPECT_RESULT=0
NATIVE_STATE='exited|false|false|false|0'
[ -z "$(github_lifecycle_candidates)" ] || fail 'first exit check recycled runner'
OWNER_ID=owner-2
[ -z "$(github_lifecycle_candidates)" ] || fail 'replacement inherited old confirmation'
[ "$(github_lifecycle_candidates)" = ci-runner-1 ] || fail 'confirmed dead slot was not recovered'
recycle_log="$tmp/recycle.log"
cmd_recycle() { printf '%s\n' "$1" >> "$recycle_log"; }
rm -f "$marker"
lifecycle_tick
[ ! -s "$recycle_log" ] || fail 'first lifecycle tick recycled runner'
lifecycle_tick
[ "$(cat "$recycle_log")" = ci-runner-1 ] || fail 'confirmed exit was not replaced'
# Recheck the exact owner immediately before native replacement.
provider_call() { echo ci-runner-1; }
NATIVE_STATE='running|true|false|false|123'
: > "$recycle_log"
lifecycle_tick
[ ! -s "$recycle_log" ] || fail 'owner restarted after selection was recycled'
DIND=false
NATIVE_STATE='exited|false|false|false|0'
rm -f "$marker"
[ -z "$(github_lifecycle_candidates)" ] || fail 'first non-DinD exit check recycled runner'
[ "$(github_lifecycle_candidates)" = ci-runner-1 ] || fail 'non-DinD dead slot was not recovered'
# A burst of exits drains in one tick, and one call counts as one confirmation.
DIND=true
provider_call() { "${CI_PROVIDER}_$1" "${@:2}"; }
managed_names() { printf 'ci-runner-1\nci-runner-2\nci-runner-3\n'; }
cmd_recycle() { printf '%s\n' "$1" >> "$recycle_log"; }
rm -f "$CRF_RUNDIR"/github-lifecycle.*
: > "$recycle_log"
lifecycle_tick
[ ! -s "$recycle_log" ] || fail 'one tick satisfied two confirmations'
lifecycle_tick
[ "$(tr '\n' ' ' < "$recycle_log")" = 'ci-runner-1 ci-runner-2 ci-runner-3 ' ] \
  || fail 'confirmed exits were not all replaced in one tick'
# One failed slot does not hold back the rest, and the tick still reports it.
cmd_recycle() { printf '%s\n' "$1" >> "$recycle_log"; [ "$1" != ci-runner-1 ]; }
: > "$recycle_log"
if lifecycle_tick 2>/dev/null; then fail 'failed replacement in a batch reported success'; fi
[ "$(tr '\n' ' ' < "$recycle_log")" = 'ci-runner-1 ci-runner-2 ci-runner-3 ' ] \
  || fail 'a failed slot blocked the rest of the batch'
# A slot that restarts during the batch is rechecked and left alone.
cmd_recycle() {
  printf '%s\n' "$1" >> "$recycle_log"
  NATIVE_STATE='running|true|false|false|123'
}
: > "$recycle_log"
lifecycle_tick
[ "$(cat "$recycle_log")" = ci-runner-1 ] || fail 'restarted slot was replaced from a stale batch'
echo 'lifecycle-enforcement: OK — positively exited immutable owners only'
