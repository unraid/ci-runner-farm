#!/usr/bin/env bash
# Retired-store reporting is read-only, even when an external writer races it.
set -euo pipefail
cd "$(dirname "$0")/.."
realpath -m -- / >/dev/null 2>&1 || { echo "SKIP: retired Docker inventory needs GNU realpath"; exit 0; }
tmp="$(realpath -m -- "$(mktemp -d)")"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { echo "retired-docker-cache: $*" >&2; exit 1; }
fixture_root="$tmp/cache with spaces"
mkdir -p "$fixture_root/docker"
crf_safe_cache_root() { printf '%s\n' "$fixture_root"; }
fixture_id="1111111111111111111111111111111111111111111111111111111111111111"
fixture_refs=''; fixture_mounts='/'; fixture_daemon=/var/lib/docker; broken=''
# Counters persist across the command substitutions used by the engine.
docker() {
  printf '%s\n' "$1" >> "$tmp/calls"
  case "$1" in
    ps) [ "$broken" != ps ] || return 1; printf '%s\n' "$fixture_id" ;;
    inspect)
      [ "$broken" != inspect ] || return 1
      [ "${*: -1}" = "$fixture_id" ] || return 1
      count=$(cat "$tmp/inspect-count"); count=$((count+1)); echo "$count" > "$tmp/inspect-count"
      # Reproduces the old loss: the returned snapshot predates an external
      # Docker client binding the store before the subsequent rm -rf.
      if [ "$count" -eq 2 ]; then printf '%s\n' "$fixture_root/docker/ci-runner-build-2" > "$tmp/foreign-reference"; fi
      if [ -n "$fixture_refs" ]; then printf '%s\n' "$fixture_refs"; fi ;;
    info) [ "$broken" != info ] || return 1; printf '%s\n' "$fixture_daemon" ;;
    *) return 1 ;;
  esac
}
findmnt() {
  printf 'findmnt\n' >> "$tmp/calls"
  [ "$broken" != mounts ] || return 1
  printf '%s\n' "$fixture_mounts"
}
fixture() {
  mkdir -p "$fixture_root/docker/ci-runner-build-1" "$fixture_root/docker/ci-runner-build-2" "$fixture_root/docker/unrelated"
  touch "$fixture_root/docker/ci-runner-build-1/retained" "$fixture_root/docker/ci-runner-build-2/retired" "$fixture_root/docker/unrelated/data"
  fixture_refs="$fixture_root/docker/ci-runner-build-1"; fixture_mounts='/'; fixture_daemon=/var/lib/docker; broken=''
  : > "$tmp/calls"; echo 0 > "$tmp/inspect-count"
}
assert_not_reported() {
  if grep -q 'snapshot: ci-runner-build-2' "$tmp/output"; then fail "$1 reported as unreferenced"; fi
  [ -e "$fixture_root/docker/ci-runner-build-2/retired" ] || fail "$1 changed data"
}
fixture
if cmd_prune_retired_docker --apply > "$tmp/output" 2>&1; then fail 'destructive mode accepted'; fi
[ ! -s "$tmp/calls" ] || fail 'destructive request reached ownership commands'
[ -e "$fixture_root/docker/ci-runner-build-2/retired" ] || fail 'racing consumer lost data'
grep -q 'read-only' "$tmp/output" || fail 'destructive rejection lacks explanation'
# Also verify the real dispatcher rejects before opening its fleet lock.
if CRF_SOURCE_ONLY=0 bash src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh prune-retired-docker --apply > "$tmp/output" 2>&1; then fail 'dispatcher accepted destructive mode'; fi
[ ! -e "$CRF_RUNDIR/fleet.lock" ] || fail 'destructive request opened fleet lock'
grep -q 'read-only' "$tmp/output" || fail 'dispatcher rejection lacks explanation'
fixture
before=$(find "$fixture_root" -printf '%y %i %s %p\n' | sort)
cmd_prune_retired_docker > "$tmp/output"
grep -q 'unreferenced in this snapshot: ci-runner-build-2' "$tmp/output" || fail 'unreferenced store not discovered'
if grep -q 'snapshot: ci-runner-build-1' "$tmp/output"; then fail 'live store reported'; fi
if grep -qE 'eligible|safe to delete' "$tmp/output"; then fail 'snapshot implies deletion authority'; fi
grep 'snapshot' "$tmp/output" | sed 's/^.*Docker /Docker /' > "$tmp/first"
cmd_prune_retired_docker --dry-run > "$tmp/output"
grep 'snapshot' "$tmp/output" | sed 's/^.*Docker /Docker /' > "$tmp/second"
cmp "$tmp/first" "$tmp/second" || fail 'snapshot is not repeatable'
after=$(find "$fixture_root" -printf '%y %i %s %p\n' | sort)
[ "$before" = "$after" ] || fail 'snapshot changed filesystem identities or contents'
for broken in ps inspect info mounts; do
  broken_test="$broken"; fixture; broken="$broken_test"
  if cmd_prune_retired_docker > "$tmp/output" 2>&1; then fail "accepted unavailable $broken"; fi
  [ -e "$fixture_root/docker/ci-runner-build-2/retired" ] || fail 'failure changed data'
done
for overlap in parent child exact; do
  fixture
  case "$overlap" in parent) fixture_refs="$fixture_root";; child) fixture_refs="$fixture_root/docker/ci-runner-build-2/subdir";; exact) fixture_refs="$fixture_root/docker/ci-runner-build-2";; esac
  cmd_prune_retired_docker > "$tmp/output"
  assert_not_reported "$overlap bind"
done
fixture; fixture_id=invalid
if cmd_prune_retired_docker > "$tmp/output" 2>&1; then fail 'invalid immutable ID accepted'; fi
[ -e "$fixture_root/docker/ci-runner-build-2/retired" ] || fail 'invalid owner changed data'
fixture_id="1111111111111111111111111111111111111111111111111111111111111111"
fixture; fixture_id=''; fixture_refs=''
cmd_prune_retired_docker > "$tmp/output"
grep -q 'snapshot: ci-runner-build-2' "$tmp/output" || fail 'empty fleet omitted store'
[ -e "$fixture_root/docker/ci-runner-build-2/retired" ] || fail 'empty fleet changed data'
fixture_id="1111111111111111111111111111111111111111111111111111111111111111"
fixture; fixture_refs=''; fixture_daemon="$fixture_root/docker"
cmd_prune_retired_docker > "$tmp/output"; assert_not_reported 'host Docker root'
fixture; fixture_refs=''; fixture_mounts="$(printf '%s' "$fixture_root/docker/ci-runner-build-2/overlay/merged" | sed 's/ /\\x20/g')"
cmd_prune_retired_docker > "$tmp/output"; assert_not_reported 'nested host mount'
fixture; mkdir -p "$tmp/foreign"; touch "$tmp/foreign/data"
ln -s "$tmp/foreign" "$fixture_root/docker/ci-runner-build-3"
cmd_prune_retired_docker > "$tmp/output"
[ -e "$tmp/foreign/data" ] && [ -L "$fixture_root/docker/ci-runner-build-3" ] || fail 'symlink candidate changed'
if grep -q 'snapshot: ci-runner-build-3' "$tmp/output"; then fail 'symlink candidate reported'; fi
mv "$fixture_root/docker" "$fixture_root/old-docker"; ln -s "$fixture_root/old-docker" "$fixture_root/docker"
if cmd_prune_retired_docker > "$tmp/output" 2>&1; then fail 'symlink parent accepted'; fi
[ -e "$tmp/foreign/data" ] || fail 'symlink parent changed foreign data'
if cmd_prune_retired_docker --force > "$tmp/output" 2>&1; then fail 'unknown mode accepted'; fi
echo 'retired Docker read-only inventory and destructive-mode regression passed'
