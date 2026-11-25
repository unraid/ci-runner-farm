#!/usr/bin/env bash
# Removing a runner with purge moves its large slot trees aside for background
# deletion instead of deleting them under fleet.lock (crf_stage_aside), and
# falls back to the old in-place delete when a rename is not safe.
# shellcheck disable=SC2034,SC2329  # engine globals and stubs are read by sourced functions
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'STORE PURGE FAIL: %s\n' "$*" >&2; exit 1; }

ROOT="$tmp/cache"
crf_safe_cache_root() { printf '%s\n' "$ROOT"; }
provider_stop_remove_container() { echo "rm $1" >> "$tmp/calls"; }
github_runner_registration_name() { printf '%s\n' "$1"; }
github_deregister_runner_api() { echo "deregister $1" >> "$tmp/calls"; }
github_pooled_slot_unreferenced() { [ ! -e "$tmp/referenced" ]; }
layer_integrity_reap_evicted() { echo "reap $1" >> "$tmp/calls"; }
github_work_trash_sweep_async() { echo "sweep" >> "$tmp/calls"; }
slot() {  # a slot with a Docker store and a pooled workspace
  rm -rf "$ROOT"; mkdir -p "$ROOT/docker/$1/overlay2/l" "$ROOT/work/$1/podman-root" "$ROOT/work/$1/workspace"
  echo layer > "$ROOT/docker/$1/overlay2/l/data"; : > "$tmp/calls"
}
staged() { find "$ROOT/$1" -mindepth 1 -maxdepth 1 -name "$2.*" 2>/dev/null | wc -l | tr -d ' '; }

# ---- purge moves both trees aside and starts the background deletes ---------
slot ci-runner-build-3
github_remove_runner ci-runner-build-3 true || fail "purge failed"
[ ! -e "$ROOT/docker/ci-runner-build-3" ] && [ ! -e "$ROOT/work/ci-runner-build-3" ] || fail "slot trees still in place"
[ "$(staged docker-evicted ci-runner-build-3)" = 1 ] || fail "Docker store not moved to docker-evicted"
[ "$(staged work/.trash ci-runner-build-3)" = 1 ] || fail "pooled workspace not moved to work/.trash"
[ -f "$ROOT/docker-evicted/$(ls "$ROOT/docker-evicted")/overlay2/l/data" ] || fail "store content lost before the background delete"
grep -qx "reap $ROOT/docker-evicted" "$tmp/calls" && grep -qx sweep "$tmp/calls" || fail "background deletes not started: $(cat "$tmp/calls")"
# The container is removed and deregistered first, as before.
[ "$(head -2 "$tmp/calls" | tr '\n' ' ')" = "rm ci-runner-build-3 deregister ci-runner-build-3 " ] || fail "removal order changed: $(cat "$tmp/calls")"

# ---- no purge touches nothing --------------------------------------------------
slot ci-runner-build-4
github_remove_runner ci-runner-build-4 false || fail "remove without purge failed"
[ -d "$ROOT/docker/ci-runner-build-4" ] && [ -d "$ROOT/work/ci-runner-build-4" ] || fail "remove without purge deleted a tree"

# ---- a referenced pooled store is kept, as before --------------------------------
slot ci-runner-build-5; touch "$tmp/referenced"
if github_remove_runner ci-runner-build-5 true; then fail "a referenced pooled store was purged"; fi
[ -d "$ROOT/work/ci-runner-build-5" ] && [ -d "$ROOT/docker/ci-runner-build-5" ] || fail "a referenced slot lost a tree"
rm -f "$tmp/referenced"

# ---- unsafe renames fall back to the in-place delete -------------------------------
# A symlinked store: the link is removed, its target is untouched, nothing staged.
slot ci-runner-build-6; mkdir -p "$tmp/elsewhere"; echo keep > "$tmp/elsewhere/file"
rm -rf "$ROOT/docker/ci-runner-build-6"; ln -s "$tmp/elsewhere" "$ROOT/docker/ci-runner-build-6"
github_remove_runner ci-runner-build-6 true || fail "symlinked store purge failed"
[ ! -L "$ROOT/docker/ci-runner-build-6" ] && [ -f "$tmp/elsewhere/file" ] || fail "symlinked store handled unsafely"
[ "$(staged docker-evicted ci-runner-build-6)" = 0 ] || fail "a symlink was staged"
# A store on another filesystem (different device): deleted in place, never copied.
slot ci-runner-build-7
stat() { if [ "${*: -1}" = "$ROOT/docker-evicted" ] || [ "${*: -1}" = "$ROOT/work/.trash" ]; then echo 999; else command stat "$@"; fi; }
github_remove_runner ci-runner-build-7 true || fail "cross-device purge failed"
unset -f stat
[ ! -e "$ROOT/docker/ci-runner-build-7" ] && [ ! -e "$ROOT/work/ci-runner-build-7" ] || fail "cross-device trees not deleted"
[ "$(staged docker-evicted ci-runner-build-7)" = 0 ] && [ "$(staged work/.trash ci-runner-build-7)" = 0 ] || fail "a cross-device tree was staged"
# A trash folder that is a symlink is never used.
slot ci-runner-build-8; rm -rf "$ROOT/docker-evicted"; ln -s "$tmp/elsewhere" "$ROOT/docker-evicted"
github_remove_runner ci-runner-build-8 true || fail "purge with a symlinked trash failed"
[ ! -e "$ROOT/docker/ci-runner-build-8" ] && [ "$(ls "$tmp/elsewhere")" = file ] || fail "a symlinked trash was used"
rm -f "$ROOT/docker-evicted"
# A missing store is fine.
slot ci-runner-build-9; rm -rf "$ROOT/docker/ci-runner-build-9"
github_remove_runner ci-runner-build-9 true || fail "purge of a missing store failed"

# ---- leftovers restart the reaper; an empty folder does not ----------------------
slot ci-runner-build-1; mkdir -p "$ROOT/docker-evicted"; : > "$tmp/calls"
crf_reap_staged_stores
[ ! -s "$tmp/calls" ] || fail "reaper started for empty folders: $(cat "$tmp/calls")"
mkdir -p "$ROOT/docker-evicted/ci-runner-build-1.1.1.1"
crf_reap_staged_stores
grep -qx "reap $ROOT/docker-evicted" "$tmp/calls" || fail "leftovers did not restart the reaper"

# ---- in-place purge on request (pressure cleanup) --------------------------------
slot ci-runner-build-10
CRF_PURGE_INPLACE=1 github_remove_runner ci-runner-build-10 true || fail "in-place purge failed"
[ ! -e "$ROOT/docker/ci-runner-build-10" ] && [ "$(staged docker-evicted ci-runner-build-10)" = 0 ] \
  && [ "$(staged work/.trash ci-runner-build-10)" = 0 ] || fail "in-place purge staged a tree"
# ---- a store on a different mount of the same device is deleted in place ----------
slot ci-runner-build-11
stat() { if [ "$1 $2" = "-c %m" ] && [ "${*: -1}" = "$ROOT/docker-evicted" ]; then echo /elsewhere; else command stat "$@"; fi; }
github_remove_runner ci-runner-build-11 true || fail "cross-mount purge failed"
unset -f stat
[ ! -e "$ROOT/docker/ci-runner-build-11" ] && [ "$(staged docker-evicted ci-runner-build-11)" = 0 ] || fail "a cross-mount store was staged"
# ---- pooled-trash leftovers restart their sweep too; old stores are reported -----
rm -rf "$ROOT/docker-evicted"/*; mkdir -p "$ROOT/work/.trash/x.1"; : > "$tmp/calls"
crf_reap_staged_stores
grep -qx sweep "$tmp/calls" || fail "pooled trash leftovers did not restart the sweep"
mkdir -p "$ROOT/docker-evicted/old.1"; touch -d '-7 hours' "$ROOT/docker-evicted/old.1"
log_err="$(crf_reap_staged_stores 2>&1)"
[[ "$log_err" == *"could not be deleted for over six hours"* ]] || fail "stuck store not reported: $log_err"
[ -z "$(crf_reap_staged_stores 2>&1)" ] || fail "stuck store reported more than once an hour"
# The lifecycle check runs the leftover sweep.
grep -q 'crf_reap_staged_stores' <(declare -f lifecycle_tick_steps) || fail "lifecycle tick does not restart leftover deletes"

# ---- the real reaper deletes every moved-aside store in the background ------------
unset -f layer_integrity_reap_evicted
. <(sed -n '/^layer_integrity_reap_evicted() {/,/^}/p' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh)
rm -rf "$ROOT/docker-evicted"; mkdir -p "$ROOT/docker-evicted/a.1/x" "$ROOT/docker-evicted/b.2/y"
layer_integrity_reap_evicted "$ROOT/docker-evicted"
for _ in $(seq 1 50); do [ -z "$(ls -A "$ROOT/docker-evicted")" ] && break; sleep 0.1; done
[ -z "$(ls -A "$ROOT/docker-evicted")" ] || fail "reaper left stores: $(ls "$ROOT/docker-evicted")"

echo 'store-purge: OK — stores and pooled workspaces moved aside, background deletes, safe fallbacks, leftovers reaped'
