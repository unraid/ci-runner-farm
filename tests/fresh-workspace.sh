#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # engine globals and stubs are read by sourced functions
# Ephemeral GitHub runners with a bind workspace (no workspace tmpfs) must start
# with an empty /_work. Exercise the real adapter and start path with a stub
# Docker client and a temporary cache root.
set -euo pipefail
cd "$(dirname "$0")/.."
realpath -e -- / >/dev/null 2>&1 || { echo "SKIP: realpath -e unsupported here (needs GNU coreutils)"; exit 0; }
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'FRESH WORKSPACE FAIL: %s\n' "$*" >&2; exit 1; }

{
  CACHE_ROOT="$tmp/cache"; ACCESS_TOKEN=''; NO_REGISTER=1
  GH_SCOPE=org; GH_OWNER=example; DIND=false; SHARE_DOCKER_SOCK=false
  NETWORK_ISOLATION=off; RUNNER_LABELS=self-hosted; IMAGE_SOURCE=builtin
  CACHE_MOUNTS='npm:/home/runner/.npm'; WORK_TMPFS_SIZE=''; EPHEMERAL=true
  CPU_PINNING=false; RUNNER_DNS=''
}
mkdir -p "$CACHE_ROOT"
host() { printf 'mockhost\n'; }
runner_host_service_ipv4() { printf '192.0.2.10\n'; }
github_kvm_gid() { return 1; }
UNSAFE_ROOT=0
crf_safe_cache_root() { [ "$UNSAFE_ROOT" = 0 ] || return 1; printf '%s' "$CACHE_ROOT"; }

# Stub Docker: EXISTING lists container names that already exist. A run records
# the workspace bind source and what that directory held at creation time.
EXISTING=''; DOCKER_DOWN=0
RUN_LOG="$tmp/docker-run.log"
docker() {
  local prev='' arg src
  case "$1 ${2:-}" in
    'container inspect'|'inspect '*)
      local target="${*: -1}"
      if [ "$DOCKER_DOWN" = 1 ]; then
        echo 'Cannot connect to the Docker daemon. Is the docker daemon running?' >&2; return 1
      fi
      printf '%s\n' "$EXISTING" | tr ' ' '\n' | grep -Fxq -- "$target" && return 0
      echo "Error: No such container: $target" >&2; return 1 ;;
    'image inspect') return 0 ;;
    run*)
      for arg in "$@"; do
        if [ "$prev" = -v ]; then
          case "$arg" in
            *:/_work)
              src="${arg%:/_work}"
              printf 'RUN %s entries=%s\n' "$src" "$(find "$src" -mindepth 1 | wc -l | tr -d ' ')" >> "$RUN_LOG" ;;
          esac
        fi
        prev="$arg"
      done
      return 0 ;;
  esac
  printf 'UNEXPECTED docker %s\n' "$*" >> "$RUN_LOG"
  return 1
}

work="$CACHE_ROOT/work"
seed_workspace() { # <slot> — leave a previous job's checkout behind
  local d="$work/$1"
  mkdir -p "$d/repo/.git/hooks" "$d/repo/src/deep/er" "$d/_temp"
  printf '[core]\n\thooksPath = .git/hooks\n' > "$d/repo/.git/config"
  printf '#!/bin/sh\necho left behind\n' > "$d/repo/.git/hooks/post-checkout"
  chmod +x "$d/repo/.git/hooks/post-checkout"
  printf 'x\n' > "$d/repo/src/deep/er/file"
  printf 'y\n' > "$d/.hidden"
  # A job can leave read-only directories; only root (as on Unraid) removes them.
  [ "$(id -u)" != 0 ] || chmod 500 "$d/repo/src/deep"
}
bind_of() { grep -E ':/_work$' <<< "$(printf '%s\n' "${ARGS[@]}")" || true; }
entries() { find "$1" -mindepth 1 | wc -l | tr -d ' '; }

# 1. A new ephemeral container gets an empty workspace at the slot's bind path.
seed_workspace ci-runner-1
github_build_args 1 ci-runner-1 || fail "ephemeral build args failed"
[ "$(bind_of)" = "$work/ci-runner-1:/_work" ] || fail "ephemeral bind path changed: $(bind_of)"
[ -d "$work/ci-runner-1" ] && [ ! -L "$work/ci-runner-1" ] || fail "clean workspace is not a directory"
[ "$(entries "$work/ci-runner-1")" = 0 ] || fail "previous job's workspace survived"

# 2. Symlinks are removed, never followed, and other slots and caches are kept.
outside="$tmp/outside"; mkdir -p "$outside/keep" "$CACHE_ROOT/npm" "$CACHE_ROOT/docker/ci-runner-2"
printf 'precious\n' > "$outside/keep/data"
printf 'cache\n' > "$CACHE_ROOT/npm/blob"
printf 'dind\n' > "$CACHE_ROOT/docker/ci-runner-2/layer"
seed_workspace ci-runner-2
seed_workspace ci-runner-3
ln -s "$outside" "$work/ci-runner-2/escape"
ln -s "$outside/keep/data" "$work/ci-runner-2/repo/link-to-file"
github_build_args 2 ci-runner-2 || fail "workspace with symlinks was not reset"
[ "$(entries "$work/ci-runner-2")" = 0 ] || fail "workspace with symlinks was not emptied"
[ "$(cat "$outside/keep/data")" = precious ] || fail "reset followed a symlink out of the workspace"
[ -f "$work/ci-runner-3/repo/.git/config" ] || fail "reset touched another slot's workspace"
[ "$(cat "$CACHE_ROOT/npm/blob")" = cache ] || fail "reset touched a shared cache"
[ "$(cat "$CACHE_ROOT/docker/ci-runner-2/layer")" = dind ] || fail "reset touched the slot's Docker data"

# 3. A slot path that is itself a symlink is replaced by a real empty directory.
rm -rf "$work/ci-runner-4"; ln -s "$outside" "$work/ci-runner-4"
github_build_args 4 ci-runner-4 || fail "symlinked slot path was not replaced"
[ -d "$work/ci-runner-4" ] && [ ! -L "$work/ci-runner-4" ] || fail "symlinked slot path survived"
[ "$(entries "$work/ci-runner-4")" = 0 ] || fail "replaced slot path is not empty"
[ "$(cat "$outside/keep/data")" = precious ] || fail "symlinked slot reset deleted its target"

# 4. The old tree is renamed into work/.trash, not deleted under the caller,
#    and the background worker then empties the trash.
trash="$work/.trash"
wait_trash_empty() {
  local _
  for _ in $(seq 1 100); do
    if [ -z "$(find "$trash" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
      flock "$CRF_RUNDIR/work-trash.lock" true  # and no worker is still running
      return 0
    fi
    sleep 0.1
  done
  return 1
}
wait_trash_empty || fail "background worker did not empty the trash"
seed_workspace ci-runner-11
real_sweep="$(declare -f github_work_trash_sweep)"
github_work_trash_sweep() { :; }
github_build_args 11 ci-runner-11 || fail "reset with trash failed"
[ "$(entries "$work/ci-runner-11")" = 0 ] || fail "reset with trash did not empty the slot"
moved="$(find "$trash" -mindepth 1 -maxdepth 1 -name 'ci-runner-11.*')"
[ -n "$moved" ] && [ -f "$moved/repo/.git/config" ] || fail "old workspace was not moved into the trash"
eval "$real_sweep"
github_work_trash_sweep
[ -z "$(find "$trash" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "trash sweep left entries behind"
[ "$(cat "$outside/keep/data")" = precious ] || fail "trash sweep followed a symlink"

# 5. The background worker neither blocks the caller's output pipe nor keeps
#    the caller's fleet lock.
command -v flock >/dev/null 2>&1 || fail "flock is required for the lock check"
github_work_trash_sweep() { sleep 5; }
seed_workspace ci-runner-12
lock="$tmp/fleet.lock"
start=$SECONDS
( flock -n 8 || exit 1; got="$(github_fresh_work_dir ci-runner-12)"; [ "$got" = "$work/ci-runner-12" ] ) 8>"$lock" \
  || fail "reset under a held lock failed"
[ $((SECONDS - start)) -lt 4 ] || fail "workspace reset waited for the background delete"
flock -n "$lock" true || fail "background delete kept the caller's fleet lock"
eval "$real_sweep"

# 6. A symlinked trash is never used; the slot is removed in place instead.
wait_trash_empty || true
rm -rf "$trash"; ln -s "$outside" "$trash"
seed_workspace ci-runner-13
github_build_args 13 ci-runner-13 || fail "reset with a symlinked trash failed"
[ "$(entries "$work/ci-runner-13")" = 0 ] || fail "reset with a symlinked trash reused the workspace"
[ ! -e "$outside/ci-runner-13" ] && [ "$(ls "$outside")" = keep ] || fail "reset moved a workspace through a symlinked trash"
rm "$trash"

# Each refusal must stop the start with the expected error and create nothing.
expect_refusal() { # <slot> <why> <expected error text>
  local errors
  : > "$RUN_LOG"
  if errors="$(start_one "${1##*-}" 2>&1 >/dev/null)"; then fail "$2: the runner started"; fi
  [ ! -s "$RUN_LOG" ] || fail "$2: docker was asked to create a container"
  printf '%s\n' "$errors" | grep -qF -- "$3" || fail "$2: unexpected error: $errors"
}

# 7. An existing same-named container may still use the directory.
seed_workspace ci-runner-5
EXISTING='ci-runner-5'
if github_build_args 5 ci-runner-5 2>"$tmp/err"; then fail "existing container: build args succeeded"; fi
grep -qF "existing container ci-runner-5" "$tmp/err" || fail "existing container gave the wrong error"
[ -f "$work/ci-runner-5/repo/.git/config" ] || fail "reset ran under an existing container"
EXISTING=''

# 8. An unsafe CACHE_ROOT is refused before anything is removed.
seed_workspace ci-runner-6
UNSAFE_ROOT=1
expect_refusal ci-runner-6 "unsafe cache root" "unsafe CACHE_ROOT"
[ -f "$work/ci-runner-6/repo/.git/config" ] || fail "reset ran under an unsafe cache root"
UNSAFE_ROOT=0

# 9. A symlinked work root is refused; its target is untouched.
mv "$work" "$tmp/real-work"; ln -s "$tmp/real-work" "$work"
expect_refusal ci-runner-6 "symlinked work root" "does not resolve to itself"
[ -f "$tmp/real-work/ci-runner-6/repo/.git/config" ] || fail "reset followed a symlinked work root"
rm "$work"; mv "$tmp/real-work" "$work"

# 10. Docker errors are not proof that no container uses the directory.
seed_workspace ci-runner-14
DOCKER_DOWN=1
if github_build_args 14 ci-runner-14 2>"$tmp/err"; then fail "reset proceeded while Docker was unreachable"; fi
DOCKER_DOWN=0
grep -qF "could not confirm that no container named ci-runner-14 exists" "$tmp/err" \
  || fail "unreachable Docker gave the wrong error"
[ -f "$work/ci-runner-14/repo/.git/config" ] || fail "reset ran while Docker was unreachable"

# 11. A slot directory that is its own mount is neither emptied nor reused.
stat() {
  if [ "$*" = "-c %d -- $work/ci-runner-14" ]; then echo 4242; else command stat "$@"; fi
}
expect_refusal ci-runner-14 "slot mount" "is a separate mount"
unset -f stat
[ -f "$work/ci-runner-14/repo/.git/config" ] || fail "reset emptied a slot mount"

# 12. Names that could leave the work root are refused.
for bad in .. . .trash 'a/../../x' 'ci runner'; do
  if github_fresh_work_dir "$bad" >/dev/null 2>&1; then fail "invalid name '$bad' was accepted"; fi
done
[ "$(cat "$outside/keep/data")" = precious ] || fail "invalid name reached the filesystem"

# 13. A workspace that cannot be removed fails closed instead of being reused.
seed_workspace ci-runner-7
mv() { return 1; }
rm() { return 1; }
expect_refusal ci-runner-7 "undeletable workspace" "could not replace the previous workspace"
unset -f rm
[ -f "$work/ci-runner-7/repo/.git/config" ] || fail "undeletable workspace test lost its fixture"
# A workspace that cannot be renamed is removed in place.
github_build_args 7 ci-runner-7 2>/dev/null || fail "in-place removal fallback failed"
unset -f mv
[ "$(entries "$work/ci-runner-7")" = 0 ] || fail "in-place removal fallback reused the workspace"

# 14. Persistent runners keep their workspace, and tmpfs workspaces never touch
#    the bind directory.
EPHEMERAL=false
github_build_args 3 ci-runner-3 || fail "persistent build args failed"
[ "$(bind_of)" = "$CACHE_ROOT/work/ci-runner-3:/_work" ] || fail "persistent bind path changed"
[ -f "$work/ci-runner-3/repo/.git/config" ] || fail "persistent runner lost its workspace"
EPHEMERAL=true WORK_TMPFS_SIZE=64m
github_build_args 3 ci-runner-3 || fail "tmpfs build args failed"
[ -z "$(bind_of)" ] || fail "tmpfs workspace also bound the pool directory"
grep -qx '/_work:rw,exec,size=64m' <<< "$(printf '%s\n' "${ARGS[@]}")" || fail "tmpfs workspace changed"
[ -f "$work/ci-runner-3/repo/.git/config" ] || fail "tmpfs workspace reset the unused bind directory"
WORK_TMPFS_SIZE=''

# 15. The shared start path (fresh slots, replenish, restart recovery) and the
#     recycle call shape both create the container on an empty workspace.
seed_workspace ci-runner-8
: > "$RUN_LOG"
start_one 8 >/dev/null || fail "start_one failed"
grep -qx "RUN $work/ci-runner-8 entries=0" "$RUN_LOG" || fail "start_one created a runner on a used workspace: $(cat "$RUN_LOG")"
seed_workspace ci-runner-9
build_args 9 || fail "recycle-shaped build args failed"
[ "$(bind_of)" = "$work/ci-runner-9:/_work" ] && [ "$(entries "$work/ci-runner-9")" = 0 ] \
  || fail "recycle-shaped build args reused the workspace"
seed_workspace ci-runner-10
EXISTING='ci-runner-10'
: > "$RUN_LOG"
start_one 10 >/dev/null 2>&1 || true
[ ! -s "$RUN_LOG" ] && [ -f "$work/ci-runner-10/repo/.git/config" ] \
  || fail "start_one reset or recreated an existing slot"
EXISTING=''

echo "Fresh workspace checks passed."
