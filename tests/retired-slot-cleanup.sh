#!/usr/bin/env bash
# Opt-in cleanup of storage left by slots that no longer exist: the pool was
# removed or the index is above its maximum, and no container has the name.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'RETIRED SLOT FAIL: %s\n' "$*" >&2; exit 1; }
image=ghcr.io/unraid/ci-runner-image@sha256:$(printf 'a%.0s' {1..64})
CI_PROVIDER=github; GH_SCOPE=org; RUNNER_MODE=pools; CACHE_ROOT="$tmp/cache"
RUNNER_POOLS="v3|build|general-build|linux,x64|9|9|18|1|4|16g|$image;v3|build-evidence|evidence-wait|evidence-only|3|3|10|1|1|2g|$image"
crf_safe_cache_root() { printf '%s\n' "$CACHE_ROOT"; }
docker() {
  [ "$1 $2" = 'container inspect' ] || fail "unexpected docker $*"
  case "$3" in
    ci-runner-build-24) return 0 ;;
    ci-runner-build-19) echo 'Cannot connect to the Docker daemon' >&2; return 1 ;;
    *) echo "Error: No such container: $3" >&2; return 1 ;;
  esac
}
crf_docker_storage_references() {
  printf 'consumer|%s\n' "$CACHE_ROOT/docker/ci-runner-build-22" /var/lib/docker
  printf 'mount|%s\n' / "$CACHE_ROOT/work/ci-runner-build-25/podman-root/merged"
}
reaped=0; layer_integrity_reap_evicted() { reaped=$((reaped + 1)); }
github_work_trash_sweep() { fail 'synchronous trash sweep under the fleet lock'; }
swept=0; github_work_trash_sweep_async() { swept=$((swept + 1)); }
old() { mkdir -p "$1"; echo data > "$1/marker"; touch -d '3 hours ago' "$1"; }
for slot in build-3 build-18 build-evidence-10 build-19 build-22 build-23 build-24 build-25 small-2; do
  old "$CACHE_ROOT/docker/ci-runner-$slot"
done
old "$CACHE_ROOT/work/ci-runner-build-23"; old "$CACHE_ROOT/dind-logs/ci-runner-build-23"
old "$CACHE_ROOT/work/ci-runner-build-25"
mkdir -p "$CACHE_ROOT/docker/ci-runner-build-21" "$CACHE_ROOT/docker/not-a-slot" "$tmp/elsewhere"; touch -d '3 hours ago' "$CACHE_ROOT/docker/not-a-slot"
ln -s "$tmp/elsewhere" "$CACHE_ROOT/docker/ci-runner-build-20"
touch -d '3 hours ago' "$CACHE_ROOT/docker"

# Off by default: nothing moves.
crf_retired_slot_cleanup
[ -d "$CACHE_ROOT/docker/ci-runner-build-23" ] || fail 'cleanup ran without the opt-in'

RETIRED_STORE_CLEANUP=true
crf_retired_slot_cleanup > "$tmp/log" 2>&1 || fail "cleanup failed: $(cat "$tmp/log")"
# Moved: above the pool maximum (all three folders), and a removed pool.
for gone in docker/ci-runner-build-23 work/ci-runner-build-23 dind-logs/ci-runner-build-23; do
  [ ! -e "$CACHE_ROOT/$gone" ] || fail "retired $gone was kept"
done
[ "$(find "$CACHE_ROOT/docker-evicted" -mindepth 1 -maxdepth 1 -name 'ci-runner-build-23.*' | wc -l)" -eq 1 ] || fail 'retired store not moved into docker-evicted'
[ "$(find "$CACHE_ROOT/work/.trash" -mindepth 1 -maxdepth 1 -name 'ci-runner-build-23.*' | wc -l)" -eq 1 ] || fail 'retired workspace not moved into work/.trash'
[ "$reaped" -ge 1 ] || fail 'background reaper was not started'
# Two slots per pass: the removed-pool store goes on the next pass.
grep -q 'retired slot storage moved aside: ci-runner-build-23' "$tmp/log" || fail 'move not logged'
# Kept: configured slots, a live or unknown container, a referenced store, a
# store holding a mount, a fresh store, a symlink and an unknown name.
for kept in build-3 build-18 build-evidence-10 build-19 build-22 build-24 build-25 build-21 build-20; do
  [ -e "$CACHE_ROOT/docker/ci-runner-$kept" ] || fail "kept slot ci-runner-$kept was moved"
done
[ -d "$tmp/elsewhere" ] && [ -d "$CACHE_ROOT/docker/not-a-slot" ] || fail 'symlink target or unknown name touched'
# The next pass is rate-limited; after the interval it takes the next slot.
crf_retired_slot_cleanup > "$tmp/log" 2>&1
[ -d "$CACHE_ROOT/docker/ci-runner-small-2" ] || [ ! -s "$tmp/log" ] || fail 'rate limit ignored'
touch -d '20 minutes ago' "$CRF_RUNDIR/retired-cleanup.last"
crf_retired_slot_cleanup > "$tmp/log" 2>&1
[ ! -e "$CACHE_ROOT/docker/ci-runner-small-2" ] || fail 'store of a removed pool was kept'
[ "$swept" -ge 1 ] || fail 'background workspace sweep not started'
# A layout read that fails after validation yields no names: keep everything.
old "$CACHE_ROOT/docker/ci-runner-build-31"; touch -d '20 minutes ago' "$CRF_RUNDIR/retired-cleanup.last"
( pool_records() { return 1; }; crf_retired_slot_cleanup > "$tmp/log" 2>&1 || true )
[ -d "$CACHE_ROOT/docker/ci-runner-build-31" ] || fail 'store moved after a failed pool layout read'
# A folder that came into use between the inventory and the move goes back.
touch -d '20 minutes ago' "$CRF_RUNDIR/retired-cleanup.last"
echo 0 > "$tmp/ref-calls"
crf_docker_storage_references() {
  local calls; calls=$(( $(cat "$tmp/ref-calls") + 1 )); echo "$calls" > "$tmp/ref-calls"
  if [ "$calls" -ge 2 ]; then printf 'consumer|%s\n' "$CACHE_ROOT/docker/ci-runner-build-31"; fi
  printf 'consumer|%s\n' "$CACHE_ROOT/docker/ci-runner-build-22"
  printf 'mount|%s\n' / "$CACHE_ROOT/work/ci-runner-build-25/podman-root/merged"
}
crf_retired_slot_cleanup > "$tmp/log" 2>&1
[ -d "$CACHE_ROOT/docker/ci-runner-build-31" ] && [ -f "$CACHE_ROOT/docker/ci-runner-build-31/marker" ] \
  || fail "store that came into use was not restored: $(cat "$tmp/log")"
grep -q 'came into use; restored it' "$tmp/log" || fail 'restore not logged'
rm -rf "$CACHE_ROOT/docker/ci-runner-build-31"
# An unreadable reference inventory or pool layout keeps everything.
old "$CACHE_ROOT/docker/ci-runner-build-30"; touch -d '20 minutes ago' "$CRF_RUNDIR/retired-cleanup.last"
crf_docker_storage_references() { return 1; }
crf_retired_slot_cleanup > "$tmp/log" 2>&1 || true
[ -d "$CACHE_ROOT/docker/ci-runner-build-30" ] || fail 'store moved without a reference inventory'
printf 'retired slot cleanup: opt-in, configured and referenced slots kept, rate-limited PASS\n'
