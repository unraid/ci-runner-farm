#!/usr/bin/env bash
# Run the real native recovery pass with isolated stores and provider boundaries.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
CACHE_ROOT="$tmp/cache"; CACHE_MOUNTS='pnpm-store:/opt/store'; CI_PROVIDER=github; EPHEMERAL=true
BASE_NAME_PREFIX=ci-runner
fail() { echo "PNPM RECOVERY FAIL: $*" >&2; exit 1; }
crf_safe_cache_root() { printf '%s' "$CACHE_ROOT"; }
fixture_id="$(printf '%064d' 1)"
managed_names() { [ ! -f "$tmp/managed" ] || echo ci-runner-1; }
managed_runner_snapshot() { echo "$fixture_id|github|runner|1|generation"; }
runner_pool() { echo ''; }
remove_runner() {
  [ "$2" = false ] && [ "$3" = "$fixture_id" ] && [ "$4" = github ] || return 1
  touch "$tmp/removed"; rm "$tmp/managed"
}
# Model only external control-plane/process observations. Store mutation is real.
docker() {
  case "$1:$2" in
    inspect:-f)
      case "$3" in
        '{{json .Mounts}}')
          [ "${mode:-}" != unavailable ] || return 1
          printf '[{"Source":"%s"}]\n' "$CACHE_ROOT/pnpm-store" ;;
        '{{.State.Status}}') echo running ;;
        *) return 1 ;;
      esac ;;
    exec:*) [ "${mode:-}" = idle ] ;;
    ps:-aq) if [ -f "$tmp/managed" ] || [ "${mode:-}" = foreign ]; then echo "$fixture_id"; fi ;;
    *) return 1 ;;
  esac
}
timeout() { shift; "$@"; }
sqlite3() {
  case "${fixture_integrity:-corrupt}" in healthy) echo ok ;; corrupt) echo 'Page 2: never used' ;; unknown) return 1 ;; esac
}
fuser() { [ "${mode:-}" != host_writer ] || return 0; return 1; }
reset_store() {
  rm -rf "$CACHE_ROOT" "$tmp/removed" "$tmp/managed"
  mkdir -p "$CACHE_ROOT/pnpm-store/v11/files"
  printf corrupt > "$CACHE_ROOT/pnpm-store/v11/index.db"
  printf wal > "$CACHE_ROOT/pnpm-store/v11/index.db-wal"
  printf shm > "$CACHE_ROOT/pnpm-store/v11/index.db-shm"
  printf sqlite-integrity-v1'\n' > "$CACHE_ROOT/pnpm-store/.farm-pnpm-recovery-v1"
  fixture_integrity=corrupt
}
for mode in busy unavailable foreign host_writer; do
  reset_store
  [ "$mode" != foreign ] && [ "$mode" != host_writer ] && touch "$tmp/managed"
  if pnpm_recovery_tick >/dev/null 2>&1; then fail "accepted $mode"; fi
  [ "$(cat "$CACHE_ROOT/pnpm-store/v11/index.db")" = corrupt ] || fail "changed $mode store"
  pnpm_recovery_pending || fail "lost $mode fence"
done
reset_store; mode=idle; touch "$tmp/managed"
if runner_starts_allowed >/dev/null 2>&1; then fail 'pending request permits starts'; fi
pnpm_recovery_tick || fail 'idle recovery refused'
[ -f "$tmp/removed" ] || fail 'idle owner not drained'
[ -d "$CACHE_ROOT/pnpm-store/v11/files" ] || fail 'fresh native CAS not initialized'
[ ! -e "$CACHE_ROOT/pnpm-store/v11/index.db" ] || fail 'corrupt DB remains live'
[ "$(cat "$CACHE_ROOT"/pnpm-quarantine/recovery.*/v11/index.db)" = corrupt ] || fail 'corrupt DB not retained'
[ "$(cat "$CACHE_ROOT"/pnpm-quarantine/recovery.*/v11/index.db-wal)" = wal ] || fail 'WAL not retained'
[ "$(cat "$CACHE_ROOT"/pnpm-quarantine/recovery.*/v11/index.db-shm)" = shm ] || fail 'SHM not retained'
if pnpm_recovery_pending; then fail 'success retains fence'; fi
runner_starts_allowed || fail 'success does not permit starts'
reset_store; mode=idle; fixture_integrity=healthy; touch "$tmp/managed"
pnpm_recovery_tick || fail 'healthy request refused'
[ -f "$tmp/managed" ] && [ ! -f "$tmp/removed" ] || fail 'healthy request drained runners'
[ ! -d "$CACHE_ROOT/pnpm-quarantine" ] || fail 'healthy request changed store'
reset_store; fixture_integrity=unknown
if pnpm_recovery_tick >/dev/null 2>&1; then fail 'unknown integrity accepted'; fi
pnpm_recovery_pending || fail 'unknown integrity lost fence'
reset_store
rm "$CACHE_ROOT/pnpm-store/.farm-pnpm-recovery-v1"
ln -s "$CACHE_ROOT/pnpm-store/v11/index.db" "$CACHE_ROOT/pnpm-store/.farm-pnpm-recovery-v1"
if pnpm_recovery_tick >/dev/null 2>&1; then fail 'symlink request accepted'; fi
[ "$(cat "$CACHE_ROOT/pnpm-store/v11/index.db")" = corrupt ] || fail 'symlink followed'
reset_store
ln -s "$tmp" "$CACHE_ROOT/pnpm-quarantine"
if pnpm_recovery_tick >/dev/null 2>&1; then fail 'symlink quarantine accepted'; fi
[ -f "$CACHE_ROOT/pnpm-store/v11/index.db" ] || fail 'unsafe quarantine moved store'
reset_store; mode=idle
flock() { return 1; }
if pnpm_recovery_tick >/dev/null 2>&1; then fail 'contended initialization lock accepted'; fi
[ -f "$CACHE_ROOT/pnpm-store/v11/index.db" ] || fail 'contended lock changed store'
unset -f flock
reset_store; mode=idle
mv() { return 1; }
if pnpm_recovery_tick >/dev/null 2>&1; then fail 'failed quarantine accepted'; fi
[ -f "$CACHE_ROOT/pnpm-store/v11/index.db" ] || fail 'failed quarantine changed store'
pnpm_recovery_pending || fail 'failed quarantine released fence'
unset -f mv
reset_store; mode=idle
mv() {
  if [ "$3" = "$CACHE_ROOT/pnpm-store/v11" ]; then command mv "$@"; else return 1; fi
}
if pnpm_recovery_tick >/dev/null 2>&1; then fail 'failed fresh publication accepted'; fi
pnpm_recovery_pending || fail 'failed publication released fence'
[ "$(cat "$CACHE_ROOT"/pnpm-quarantine/recovery.*/v11/index.db)" = corrupt ] || fail 'failed publication lost quarantine'
unset -f mv
reset_store
printf invalid > "$CACHE_ROOT/pnpm-store/.farm-pnpm-recovery-v1"
if pnpm_recovery_tick >/dev/null 2>&1; then fail 'invalid request accepted'; fi
pnpm_recovery_pending || fail 'invalid request lost fence'
echo 'pnpm guarded recovery tests passed'
