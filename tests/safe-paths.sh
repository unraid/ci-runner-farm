#!/usr/bin/env bash
# Behavioral tests for the CACHE_ROOT / cache-mount path guards and filesystem
# classifier (crf_safe_cache_root, crf_safe_mount_subdir, cache_root_problem,
# and check_cache_root) in include/runner-farm.sh.
#
# These guards gate every destructive/expensive operation the plugin runs
# under CACHE_ROOT — rm -rf (cmd_prune_cache / cmd_cache_clear_pkg), chown -R
# (ensure_dirs), and the bind mount of a web-settable CACHE_MOUNTS entry into every
# runner (build_args). A regression that let a share/device/system root or a `../`
# escape slip through would be high-consequence, so they earn a unit test.
#
# They are functions of CACHE_ROOT (env) plus, for the mount guard, one argument.
# Extract only those functions from the engine (avoiding dispatch side effects),
# then mock df for deterministic filesystem classification without requiring an
# Unraid pool on the test host.
# Requires GNU realpath (realpath -m); skips loudly where that is unavailable.
set -u
cd "$(dirname "$0")/.."
ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"

realpath -m -- / >/dev/null 2>&1 || { echo "SKIP: realpath -m unsupported here (needs GNU coreutils)"; exit 0; }

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
# Each function starts with `<name>()` at column 0 and ends at the first `}` at
# column 0 (their inner case blocks close with `esac`, not a bare `}`).
sed -n '/^crf_safe_cache_root()/,/^}/p'   "$ENGINE" >  "$tmp"
sed -n '/^crf_safe_mount_subdir()/,/^}/p' "$ENGINE" >> "$tmp"
sed -n '/^cache_root_problem()/,/^}/p'     "$ENGINE" >> "$tmp"
sed -n '/^check_cache_root()/,/^}/p'       "$ENGINE" >> "$tmp"
# shellcheck disable=SC1090  # sourcing an extracted-at-runtime snippet by design
. "$tmp"

pass=0; fail=0
root_case() { # <path> <ok|reject>
  CACHE_ROOT="$1"
  if crf_safe_cache_root >/dev/null 2>&1; then got=ok; else got=reject; fi
  if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  crf_safe_cache_root %-32s expected %-6s got %s\n' "$1" "$2" "$got"; fi
}
mount_case() { # <cache_root> <subdir> <ok|reject>
  CACHE_ROOT="$1"
  if crf_safe_mount_subdir "$2" >/dev/null 2>&1; then got=ok; else got=reject; fi
  if [ "$got" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  crf_safe_mount_subdir root=%s sub=%-14s expected %-6s got %s\n' "$1" "$2" "$3" "$got"; fi
}

# --- crf_safe_cache_root ---------------------------------------------------
# Dedicated pool/disk subdirs: accepted.
root_case /mnt/cache/github-runner        ok
root_case /mnt/disk1/github-runner        ok
root_case /mnt/github-runner              ok        # legacy default, grandfathered
root_case /mnt/cache/github-runner/       ok        # trailing slash normalized
root_case /mnt/cache/../cache/gh          ok        # .. resolves back under the pool
# Bare pool / array-disk / mnt roots: rejected.
root_case /mnt/cache                      reject
root_case /mnt/disk1                      reject
root_case /mnt                            reject
root_case /                               reject
root_case /mnt/cache/sub/..               reject    # resolves to the bare pool root
# FUSE user shares + system dirs: rejected. NB: leaf names below are deliberately
# non-existent so realpath -m normalizes them lexically instead of resolving a real
# host symlink (e.g. a share symlinked onto a pool) to a different, accepted location
# — the guard classifies by REAL resolved path, which is correct, so the test must
# not depend on any particular host's /mnt layout.
root_case /mnt/user                       reject
root_case /mnt/user/crf-guard-test        reject
root_case /mnt/user0/crf-guard-test       reject
root_case /boot/config                    reject
root_case /etc                            reject
root_case /var/lib                        reject
# Unassigned-Devices / remote / addons: the <name> level IS a data root -> rejected;
# a dedicated subdir under it is accepted (regression guard for the device-root gap).
root_case /mnt/disks/mybackup             reject
root_case /mnt/disks/mybackup/gh          ok
root_case /mnt/remotes/NAS_share          reject
root_case /mnt/remotes/NAS_share/gh       ok
root_case /mnt/addons/foo                 reject
# Outside /mnt entirely: rejected.
root_case /home/user/gh                   reject

# --- crf_safe_mount_subdir (CACHE_ROOT canonical, subdir must stay under it) --
mount_case /mnt/cache/github-runner pnpm-store   ok
mount_case /mnt/cache/github-runner npm          ok
mount_case /mnt/cache/github-runner a/b          ok        # nested subdir stays under root
mount_case /mnt/cache/github-runner ../../etc    reject    # escapes the root
mount_case /mnt/cache/github-runner ..           reject    # parent of the root
mount_case /mnt/cache/github-runner ../sibling   reject    # sibling of the root

# --- cache_root_problem / check_cache_root -------------------------------
# Keep lexical validation ahead of filesystem probing. Even if the filesystem
# classifier would report a persistent pool, a normalized system/share path
# must remain rejected and df must never be consulted for it.
df_log="$(mktemp)"
fs_tmp=""
trap 'rm -f "$tmp" "$df_log"; [ -z "$fs_tmp" ] || rm -rf -- "$fs_tmp"' EXIT
DF_FSTYPE=xfs
DF_TARGET=/mnt/mock-pool
df() {
  local path="${!#}"
  printf '%s\n' "$path" >> "$df_log"
  [ -e "$path" ] || return 1
  printf '%s\n' \
    'Filesystem Type 1024-blocks Used Available Capacity Mounted on' \
    "mockfs $DF_FSTYPE 1000 1 999 1% $DF_TARGET"
}
err() { printf '%s\n' "$*" >&2; }

check_case() { # <cache-root> <ok|reject>
  CACHE_ROOT="$1"
  if check_cache_root >/dev/null 2>&1; then got=ok; else got=reject; fi
  if [ "$got" = "$2" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL  check_cache_root %-32s expected %-6s got %s\n' "$1" "$2" "$got"
  fi
}
problem_case() { # <cache-root> <ok|reject>
  local problem
  CACHE_ROOT="$1"
  problem="$(cache_root_problem)"
  if [ -z "$problem" ]; then got=ok; else got=reject; fi
  if [ "$got" = "$2" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL  cache_root_problem %-32s expected %-6s got %s\n' "$1" "$2" "$got"
  fi
}

: > "$df_log"
DIND=true
check_case /etc/ci-runner-farm-cache reject
check_case /mnt/cache/../../etc/ci-runner-farm-cache reject
check_case /mnt/user/ci-runner-farm-cache reject
if [ -s "$df_log" ]; then
  fail=$((fail+1))
  echo 'FAIL  unsafe lexical CACHE_ROOT reached filesystem classification'
else
  pass=$((pass+1))
fi

# Isolate filesystem classification from the /mnt-only lexical guard so this
# works as an unprivileged test on both GitHub Actions and local Linux. The
# configured dedicated cache child does not exist yet (normal before first
# Start); df itself rejects nonexistent paths, so cache_root_problem must probe
# the nearest existing ancestor instead.
crf_safe_cache_root() { printf '%s' "$CACHE_ROOT"; }
fs_tmp="$(mktemp -d)"
pool="$fs_tmp/pool"
cache_child="$pool/ci-runner-farm"
mkdir -p "$pool"
: > "$df_log"
DF_FSTYPE=xfs
DF_TARGET="$pool"
DIND=true
problem_case "$cache_child" ok
check_case "$cache_child" ok

# Existing rootfs/tmpfs/overlay storage remains unsafe regardless of DinD.
# FUSE remains unsafe when DinD would place an overlay2 data root on it.
for fstype in rootfs tmpfs overlay; do
  fs_path="$fs_tmp/$fstype"
  mkdir -p "$fs_path"
  DF_FSTYPE="$fstype"
  DF_TARGET="$fs_path"
  DIND=false
  problem_case "$fs_path" reject
  check_case "$fs_path" reject
done
fs_path="$fs_tmp/fuse"
mkdir -p "$fs_path"
DF_FSTYPE=fuse.shfs
DF_TARGET="$fs_path"
DIND=true
problem_case "$fs_path" reject
check_case "$fs_path" reject

echo "safe-paths: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
