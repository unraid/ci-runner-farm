#!/usr/bin/env bash
# Phase timing (include/phase-timing.sh): one timing line per timed operation,
# without changing what the operation prints or returns.
# shellcheck disable=SC2034,SC2329  # engine globals and stubs are read by sourced functions
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'PHASE TIMING FAIL: %s\n' "$*" >&2; exit 1; }
T="$RUNDIR/timing.log"
last() { tail -n 1 "$T"; }
field() { tr ' ' '\n' <<< "$1" | awk -F= -v k="$2" '$1 == k { print $2; exit }'; }

# ---- accumulator ------------------------------------------------------------
timed() {
  local _tm_start _tm_last _tm_parts
  crf_timing_begin
  sleep 0.05; crf_timing_mark first
  sleep 0.05; crf_timing_mark second
  crf_timing_end demo slot-1 0
}
timed
line="$(last)"
[[ "$line" =~ ^ts=[0-9]+\.[0-9]{3}\ op=demo\ subject=slot-1\ rc=0\ total_ms=[0-9]+\ first_ms=[0-9]+\ second_ms=[0-9]+$ ]] \
  || fail "line format: $line"
total="$(field "$line" total_ms)"; first="$(field "$line" first_ms)"; second="$(field "$line" second_ms)"
[ "$first" -ge 40 ] && [ "$second" -ge 40 ] && [ $(( first + second )) -le "$total" ] || fail "phases do not add up: $line"
# A mark or end with no timed caller does nothing.
lines="$(wc -l < "$T")"
crf_timing_mark orphan; crf_timing_end orphan - 0
[ "$(wc -l < "$T")" = "$lines" ] || fail "an untimed mark wrote a line"
# A helper's marks join its caller's line.
helper() { crf_timing_mark helper_step; }
outer() { local _tm_start _tm_last _tm_parts; crf_timing_begin; helper; crf_timing_end outer - 0; }
outer
[[ "$(last)" == *" helper_step_ms="* ]] || fail "helper mark missing: $(last)"
# Without EPOCHREALTIME, date supplies the time.
( unset EPOCHREALTIME; timed ) || fail "fallback clock failed"
[[ "$(last)" == *"op=demo"* ]] || fail "fallback clock wrote no line"
# An unwritable timing file never fails the operation.
( RUNDIR="$tmp/missing/dir"; timed ) || fail "a write failure failed the operation"
# The file stays under its cap and keeps whole lines.
CRF_TIMING_MAX_BYTES=2000
for _ in $(seq 1 80); do crf_timing_write "op=fill subject=x rc=0 total_ms=1 pad_ms=1234567890"; done
[ "$(stat -c %s "$T")" -le 2000 ] || fail "timing file over its cap: $(stat -c %s "$T")"
grep -vqE '^ts=' "$T" && fail "a partial line survived trimming"
CRF_TIMING_MAX_BYTES=4194304

# ---- fleet.lock ---------------------------------------------------------------
: > "$T"
reload_locked_snapshot() { return 0; }
returns() { return "$1"; }
with_fleet_lock wait returns 0 || fail "lock wait changed rc 0"
[[ "$(last)" =~ op=lock\ subject=returns\ rc=0\ wait_ms=[0-9]+\ hold_ms=[0-9]+$ ]] || fail "lock line: $(last)"
rc=0; with_fleet_lock try returns 3 || rc=$?
[ "$rc" = 3 ] || fail "lock try changed rc 3 to $rc"
# A try that finds the lock busy skips with status 0 and records the skip.
( flock 9; sleep 2 ) 9>"$RUNDIR/fleet.lock" &
holder=$!
sleep 0.5
rc=0; with_fleet_lock try returns 7 || rc=$?
wait "$holder"
[ "$rc" = 0 ] || fail "busy try did not skip: rc $rc"
[[ "$(last)" == *"op=lock subject=returns rc=busy "* ]] || fail "busy try not recorded: $(last)"
# A failed snapshot reload keeps its status 1.
reload_locked_snapshot() { return 1; }
rc=0; with_fleet_lock wait returns 0 || rc=$?
[ "$rc" = 1 ] && [[ "$(last)" == *"rc=1 "* ]] || fail "reload failure changed: rc $rc, $(last)"
reload_locked_snapshot() { return 0; }

# ---- wrappers keep output and status --------------------------------------------
cmd_recycle_steps() { crf_timing_mark checks; echo '{"ok":false,"error":"x"}'; return 4; }
rc=0; out="$(cmd_recycle ci-runner-build-3)" || rc=$?
[ "$out" = '{"ok":false,"error":"x"}' ] && [ "$rc" = 4 ] || fail "recycle wrapper changed output or status: $out $rc"
[[ "$(last)" =~ op=recycle\ subject=ci-runner-build-3\ rc=4\ total_ms=[0-9]+\ checks_ms=[0-9]+$ ]] || fail "recycle line: $(last)"
github_start_one_steps() { crf_timing_mark admit; return 0; }
github_start_one 3 ci-runner-build-3 || fail "start wrapper changed status"
[[ "$(last)" == *"op=start subject=ci-runner-build-3 rc=0 "*"admit_ms="* ]] || fail "start line: $(last)"
lifecycle_tick_steps() { return 2; }
rc=0; lifecycle_tick || rc=$?
[ "$rc" = 2 ] && [[ "$(last)" == *"op=lifecycle-tick subject=- rc=2 "* ]] || fail "lifecycle tick wrapper: rc $rc, $(last)"
autoscale_tick_steps() { return 0; }
autoscale_tick && [[ "$(last)" == *"op=autoscale-tick subject=- rc=0 "* ]] || fail "autoscale tick wrapper: $(last)"

# ---- exit-event batch -----------------------------------------------------------
CI_PROVIDER=github
REPLACED="$tmp/replaced"; : > "$REPLACED"
lifecycle_event_replace() { printf '%s\n' "$2" >> "$REPLACED"; LIFECYCLE_EVENT_ACTED=true; }
lifecycle_event_yield() { return 0; }
id1="$(printf '%064x' 1)"; id2="$(printf '%064x' 2)"
lifecycle_event_dispatch "$id1 ci-runner-build-1 0"$'\n'"$id2 ci-runner-build-2 0" >/dev/null 2>&1 || fail "event batch failed"
[ "$(cat "$REPLACED")" = $'ci-runner-build-1\nci-runner-build-2' ] || fail "event batch did not replace both"
line="$(last)"
[[ "$line" == *"op=event-batch subject=slots-2 rc=0 "*"lock_wait_ms="*"setup_ms="*"replace_ms="*"yield_wait_ms="*"replace_ms="* ]] \
  || fail "event batch line: $line"

echo 'phase-timing: OK — line format, phase sums, helper marks, fallbacks, cap, lock wait/hold/busy, wrapper output and status, event batches'
