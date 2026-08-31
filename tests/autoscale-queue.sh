#!/usr/bin/env bash
# Verify that a fresh provider queue cache can increase growth without changing
# the existing idle-only fallback for stale, mismatched, or missing cache data.
set -euo pipefail
# The sourced engine consumes these values through Bash dynamic scope.
# shellcheck disable=SC2034
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source "$ENGINE"

AUTOSCALE=true
AUTOSCALE_MIN=2
AUTOSCALE_MAX=16
AUTOSCALE_MIN_IDLE=2
AUTOSCALE_STEP=2
AUTOSCALE_IDLE_GRACE=5
scale_log="$tmp/scales"
autoscale_output="$tmp/output"

reap_dead_runners() { :; }
heal_poisoned_runners() { :; }
reconcile_stale_runners() { :; }
provider_call() {
  [ "${1:-}" = autoscale_counts ] || return 1
  cur=4
  busy=4
  idle=0
}
cmd_scale() { printf '%s\n' "$1" >> "$scale_log"; }

assert_target() {
  local label="$1" provider="$2" timestamp="$3" count="$4" expected="$5"
  rm -f "$RUNDIR/queued.cache" "$RUNDIR/autoscale.state"
  : > "$scale_log"
  if [ "$provider" != none ]; then
    printf '%s %s %s\n' "$provider" "$timestamp" "$count" > "$RUNDIR/queued.cache"
  fi
  autoscale_tick >"$autoscale_output" \
    || { cat "$autoscale_output" >&2; printf 'autoscale-queue: %s failed\n' "$label" >&2; exit 1; }
  [ "$(cat "$scale_log")" = "$expected" ] \
    || { printf 'autoscale-queue: %s expected %s, got %s\n' "$label" "$expected" "$(cat "$scale_log")" >&2; exit 1; }
}

now="$(date +%s)"
assert_target "one queued job keeps the step floor" github "$now" 1 6
grep -q 'queued=1' "$autoscale_output" \
  || { echo 'autoscale-queue: fresh queue depth was not reported' >&2; exit 1; }
assert_target "larger queue increases growth" github "$now" 8 12
assert_target "queue growth stays below the maximum" github "$now" 50 16
assert_target "stale cache falls back to the step" github "$((now - 61))" 50 6
assert_target "provider mismatch falls back to the step" gitlab "$now" 50 6
assert_target "missing cache falls back to the step" none "$now" 0 6

echo "autoscale-queue: PASS"
