#!/usr/bin/env bash
# A pool record removed from the saved layout while its runners still exist.
# Those runners can never be recreated, so they are retired: idle and stopped
# ones are removed, busy ones finish their job first, and the remaining pools
# keep reconciling and growing on every tick. A stub Docker holds the fleet.
# shellcheck disable=SC2034,SC2329  # engine globals and stubs are read by sourced functions
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'REMOVED POOL FAIL: %s\n' "$*" >&2; exit 1; }

LOG="$tmp/tick.log"; MUTATIONS="$tmp/mutations"; STARTS="$tmp/starts"
: > "$LOG"; : > "$MUTATIONS"; : > "$STARTS"

CI_PROVIDER=github GH_SCOPE=org RUNNER_MODE=pools AUTOSCALE=true GROWTH_BACKPRESSURE=false
BUILD='v3|build|general-build|unraid,build|2|2|8|1|4|16g|builtin'
SMALL='v3|small|build-small|self-hosted|1|1|4|1|1|2g|builtin'
OLD='v3|old|build-old|self-hosted|1|1|4|1|1|2g|builtin'
RUNNER_POOLS="$BUILD;$SMALL;$OLD"
pool_base_refresh
validate_runner_mode || fail "the starting layout is invalid"

# Fingerprints of the pools that stay. They are taken while the old pool is
# still configured and must not change when it is removed.
gen_of() { ( pool_activate "$1" && crf_confgen ); }
GEN_BUILD="$(gen_of build)"; GEN_SMALL="$(gen_of small)"
[ -n "$GEN_BUILD" ] && [ -n "$GEN_SMALL" ] || fail "empty pool fingerprint"
[ "$GEN_BUILD" != "$GEN_SMALL" ] || fail "pools share one fingerprint"

# The stub fleet. EXISTING lists slot names, BUSY the ones running a job,
# STOPPED the exited ones, and STALE the ones on a previous config.
EXISTING=""; BUSY=""; STOPPED=""; STALE=""
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
pool_of() { local n="${1#ci-runner-}"; printf '%s\n' "${n%-*}"; }
# shellcheck disable=SC2086  # EXISTING is a space-separated name list
managed_names() { printf '%s\n' $EXISTING; }
runner_pool() { pool_of "$1"; }
managed_runner_snapshot() {
  local gen=unknown
  in_list "$1" "$EXISTING" || return 1
  case "$(pool_of "$1")" in build) gen="$GEN_BUILD" ;; small) gen="$GEN_SMALL" ;; old) gen=old-gen ;; esac
  in_list "$1" "$STALE" && gen=stale-gen
  printf 'id-%s|github|runner|%s|%s\n' "$1" "${1##*-}" "$gen"
}
runner_state() { if in_list "$1" "$BUSY"; then printf 'busy\n'; else printf 'idle\n'; fi; }
docker() {
  local target="${*: -1}"; target="${target#id-}"
  case "$1" in
    inspect)
      if [ "$2" = --format ]; then
        in_list "$target" "$STOPPED" && { printf 'exited|false\n'; return 0; }
        printf 'running|false\n'; return 0
      fi
      if [ "$2" = -f ]; then
        in_list "$target" "$EXISTING" || return 1
        if in_list "$target" "$STOPPED"; then printf 'false\n'; else printf 'true\n'; fi
        return 0
      fi
      in_list "$target" "$EXISTING" ;;
    top)
      target="${2#id-}"
      if in_list "$target" "$BUSY"; then printf 'PID COMMAND\n1 Runner.Listener\n2 Runner.Worker\n'
      else printf 'PID COMMAND\n1 Runner.Listener\n'; fi ;;
    ps) managed_names ;;
    *) printf 'docker %s\n' "$*" >> "$MUTATIONS"; return 1 ;;
  esac
}
drop() { local n out=""; for n in $EXISTING; do [ "$n" = "$1" ] || out+="$n "; done; EXISTING="${out% }"; }
# Records the slot prefix the provider cleanup would see.
remove_runner() {
  printf 'remove %s %s\n' "$1" "$NAME_PREFIX" >> "$MUTATIONS"
  [ "${3:-}" = "id-$1" ] && [ "${4:-}" = "${EXPECT_PROVIDER:-github}" ] || fail "removal of $1 lost its immutable owner"
  drop "$1"
}
# Like the real recycle, this activates the runner's pool in the caller's shell.
cmd_recycle() { printf 'recycle %s\n' "$1" >> "$MUTATIONS"; pool_activate "$(runner_pool "$1")"; }
start_one() {
  in_list "$NAME_PREFIX-$1" "$EXISTING" && return 0
  printf '%s-%s\n' "$NAME_PREFIX" "$1" >> "$STARTS"
  EXISTING="$EXISTING $NAME_PREFIX-$1"
}
reload_locked_snapshot() { pool_base_refresh; }
crf_storage_pressure_cleanup() { :; }
provider_remote_image_host_pull_required() { return 1; }

starts() { tr '\n' ' ' < "$STARTS" | sed 's/ $//'; }
removed() { grep '^remove ' "$MUTATIONS" | cut -d' ' -f2 | sort | tr '\n' ' ' | sed 's/ $//'; }
tick() { : > "$STARTS"; : > "$MUTATIONS"; autoscale_tick >>"$LOG" 2>&1 || fail "autoscale tick failed: $(tail -3 "$LOG")"; }

# The old pool is removed while it has an idle, a busy and a stopped runner.
# Both build runners are busy, so the build pool needs one more warm runner.
EXISTING='ci-runner-build-1 ci-runner-build-2 ci-runner-old-1 ci-runner-old-2 ci-runner-old-3 ci-runner-small-1'
BUSY='ci-runner-build-1 ci-runner-build-2 ci-runner-old-2'
STOPPED='ci-runner-old-3'
RUNNER_POOLS="$BUILD;$SMALL"
pool_base_refresh

tick
[ "$(removed)" = 'ci-runner-old-1 ci-runner-old-3' ] || fail "idle and stopped runners of the removed pool were not removed: $(removed)"
grep -q '^recycle ' "$MUTATIONS" && fail "a runner was recycled: $(grep '^recycle ' "$MUTATIONS")"
[ "$(starts)" = 'ci-runner-build-3' ] || fail "the build pool did not grow beside the removed pool: $(starts)"
in_list ci-runner-old-2 "$EXISTING" || fail "a busy runner of the removed pool was removed"
[ "$(grep -c 'ci-runner-old-2' "$LOG")" = 1 ] || fail "the busy retired runner was not reported once"

# Still busy: kept, not reported again, and the other pools keep growing.
BUSY="$BUSY ci-runner-build-3"
tick
[ -z "$(removed)" ] || fail "a busy retired runner was removed: $(removed)"
[ "$(starts)" = 'ci-runner-build-4' ] || fail "growth stopped while a retired runner was busy: $(starts)"
[ "$(grep -c 'ci-runner-old-2' "$LOG")" = 1 ] || fail "the busy retired runner was reported on every tick"

# Its job finished: removed on the next tick.
BUSY="${BUSY/ci-runner-old-2/}"
tick
[ "$(removed)" = 'ci-runner-old-2' ] || fail "the retired runner was not removed after its job: $(removed)"
grep -q '^recycle ' "$MUTATIONS" && fail "a runner was recycled after the retirement"

# The pools that stay keep their fingerprints, so none of their runners is stale.
[ "$(gen_of build)" = "$GEN_BUILD" ] && [ "$(gen_of small)" = "$GEN_SMALL" ] \
  || fail "removing a pool changed another pool's fingerprint"
[ "$(count_stale_runners)" = 0 ] || fail "runners of the remaining pools read as stale"

# A runner whose current config cannot be worked out is skipped and reported
# once. It is not removed or recycled, and growth goes on.
BROKEN_POOL=small
eval "real_$(declare -f crf_confgen)"
crf_confgen() { [ "${CRF_POOL_ID:-}" != "$BROKEN_POOL" ] || { err "pool $BROKEN_POOL cannot be resolved"; return 1; }; real_crf_confgen; }
BUSY="$BUSY ci-runner-build-4"
: > "$LOG"
tick
tick
[ -z "$(removed)" ] || fail "a runner was removed after a config lookup failure: $(removed)"
grep -q '^recycle ' "$MUTATIONS" && fail "a runner was recycled after a config lookup failure"
[ "$(grep -c 'ci-runner-small-1' "$LOG")" = 1 ] || fail "the lookup failure was not reported exactly once: $(cat "$LOG")"
grep -q 'cannot be resolved' "$LOG" || fail "the lookup failure did not carry its reason"
in_list ci-runner-build-5 "$EXISTING" || fail "growth stopped after a config lookup failure"
BROKEN_POOL=none
# Once it resolves again, a later failure is reported again.
tick
BROKEN_POOL=small
tick
[ "$(grep -c 'ci-runner-small-1' "$LOG")" = 2 ] || fail "a new lookup failure after recovery was not reported"
BROKEN_POOL=none

# The lifecycle watchdog removes an exited runner of a removed pool instead of
# trying to recreate it in a pool that has no settings.
EXISTING="$EXISTING ci-runner-old-4"; STOPPED='ci-runner-old-4'
github_runner_exited() { return 0; }
: > "$MUTATIONS"
lifecycle_replace ci-runner-old-4 >>"$LOG" 2>&1 || fail "lifecycle failed on a retired runner"
[ "$(removed)" = 'ci-runner-old-4' ] || fail "lifecycle did not remove an exited retired runner: $(removed)"
grep -q '^recycle ' "$MUTATIONS" && fail "lifecycle recycled a retired runner"

# Restoring stopped runners removes a stopped retired one and reports success.
EXISTING="$EXISTING ci-runner-old-5"; STOPPED='ci-runner-old-5'
recreate_stopped_runner() { printf 'recreate %s\n' "$1" >> "$MUTATIONS"; }
: > "$MUTATIONS"
start_stopped_managed >>"$LOG" 2>&1 || fail "restoring stopped runners failed on a retired runner"
[ "$(removed)" = 'ci-runner-old-5' ] || fail "a stopped retired runner was not removed: $(removed)"
grep -q '^recreate ' "$MUTATIONS" && fail "a stopped retired runner was recreated"
STOPPED=''

# One reconcile pass recycles one stale runner and still retires every
# retired runner, each under its own slot prefix. A recycle earlier in the pass
# activates another pool, and the provider cleanup accepts only names under the
# active prefix.
EXISTING="$EXISTING ci-runner-small-2 ci-runner-small-3 ci-runner-old-7 ci-runner-old-8"
STALE='ci-runner-small-2 ci-runner-small-3'
: > "$MUTATIONS"
reconcile_stale_runners >>"$LOG" 2>&1 || fail "reconcile failed beside a recycle"
[ "$(grep -c '^recycle ' "$MUTATIONS")" = 1 ] && grep -qx 'recycle ci-runner-small-2' "$MUTATIONS" \
  || fail "one pass did not recycle exactly one stale runner: $(cat "$MUTATIONS")"
[ "$(removed)" = 'ci-runner-old-7 ci-runner-old-8' ] || fail "a recycle stopped the retirement: $(removed)"
[ "$(grep '^remove ' "$MUTATIONS" | cut -d' ' -f3 | sort -u)" = ci-runner-old ] \
  || fail "a retired runner was removed under another pool's prefix: $(grep '^remove ' "$MUTATIONS")"
STALE=''; pool_base_refresh; pool_activate default

# A stopped GitLab manager whose executor still runs a job is busy. It is kept
# until the job ends, then removed.
EXPECT_PROVIDER=gitlab
EXISTING="$EXISTING ci-runner-old-9"; STOPPED='ci-runner-old-9'; BUSY="$BUSY ci-runner-old-9"
: > "$MUTATIONS"; : > "$LOG"
retire_runner ci-runner-old-9 id-ci-runner-old-9 gitlab >>"$LOG" 2>&1 || fail "retiring a busy stopped manager failed"
retire_runner ci-runner-old-9 id-ci-runner-old-9 gitlab >>"$LOG" 2>&1 || fail "retiring a busy stopped manager failed"
[ -z "$(removed)" ] || fail "a stopped manager with a running job was removed"
[ "$(grep -c 'ci-runner-old-9' "$LOG")" = 1 ] || fail "the busy stopped manager was not reported once"
BUSY="${BUSY/ci-runner-old-9/}"
retire_runner ci-runner-old-9 id-ci-runner-old-9 gitlab >>"$LOG" 2>&1 || fail "retiring a finished stopped manager failed"
[ "$(removed)" = 'ci-runner-old-9' ] || fail "a finished stopped manager was not removed"
EXPECT_PROVIDER=github; STOPPED=''
: > "$MUTATIONS"

# A removal that keeps failing is reported once, not on every check.
eval "saved_$(declare -f remove_runner)"
remove_runner() { err "provider refused removal of $1"; return 1; }
EXISTING="$EXISTING ci-runner-old-10"; : > "$LOG"
for _ in 1 2 3; do
  if retire_runner ci-runner-old-10 id-ci-runner-old-10 github >>"$LOG" 2>&1; then fail "a failed removal reported success"; fi
done
[ "$(grep -c 'retire: removing ci-runner-old-10' "$LOG")" = 1 ] && [ "$(grep -c 'retire: could not remove ci-runner-old-10' "$LOG")" = 1 ] \
  || fail "a failing removal was reported on every check: $(cat "$LOG")"
eval "$(declare -f saved_remove_runner | sed '1s/saved_//')"; unset -f saved_remove_runner
drop ci-runner-old-10

# Reconcile returns 2 when it skipped a runner whose config cannot be worked
# out. The Apply drain then stops at once instead of waiting for its timeout.
BROKEN_POOL=small
rc=0; reconcile_stale_runners >>"$LOG" 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "reconcile did not report a skipped runner (rc $rc)"
load_cfg() { :; }; reload_secret_files() { :; }
sleep() { fail "the Apply drain waited instead of stopping on a skipped runner"; }
( cmd_reconcile_drain ) > "$tmp/drain.log" 2>&1 || fail "the Apply drain failed: $(cat "$tmp/drain.log")"
grep -q 'could not be worked out' "$tmp/drain.log" || fail "the Apply drain did not explain its stop: $(cat "$tmp/drain.log")"
BROKEN_POOL=none
rc=0; reconcile_stale_runners >>"$LOG" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "reconcile reported a skip with nothing skipped (rc $rc)"
unset -f sleep

# The image roll skips a retired runner and goes on with the other slots.
drain_and_recreate() { printf 'drain %s\n' "$1" >> "$MUTATIONS"; }
effective_image() { printf 'image\n'; }
EXISTING="$EXISTING ci-runner-old-11"
: > "$MUTATIONS"
imageupdate_rollover false >>"$LOG" 2>&1 || fail "the image roll failed beside a retired runner"
grep -q '^drain ci-runner-old' "$MUTATIONS" && fail "the image roll drained a retired runner"
grep -qx 'drain ci-runner-small-1' "$MUTATIONS" || fail "the image roll stopped at a retired runner: $(cat "$MUTATIONS")"
drop ci-runner-old-11
: > "$MUTATIONS"

# An invalid saved layout is a configuration error, never a retirement.
EXISTING="$EXISTING ci-runner-old-6"
RUNNER_POOLS='not-a-layout'
: > "$MUTATIONS"
if runner_pool_retired ci-runner-build-1 || runner_pool_retired ci-runner-old-6; then
  fail "an invalid layout marked runners as retired"
fi
RUNNER_POOLS="$BUILD;$SMALL"

# The single-runner layout has no pools to remove.
RUNNER_MODE=single
runner_pool_retired ci-runner-old-6 && fail "the single layout retired a runner"
RUNNER_MODE=pools

[ ! -s "$MUTATIONS" ] || fail "unexpected mutation: $(cat "$MUTATIONS")"
echo "removed-pool: OK — idle and stopped retired runners removed, busy ones finish first, other pools keep growing and keep their fingerprints, lookup failures skipped and logged once"
