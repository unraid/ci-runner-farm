#!/usr/bin/env bash
# Behavioral tests for the CACHE_ROOT / cache-mount path guards
# (crf_safe_cache_root, crf_safe_mount_subdir) in include/runner-farm.sh.
#
# These two functions gate every destructive/expensive operation the plugin runs
# under CACHE_ROOT — rm -rf (cmd_prune_cache / cmd_cache_clear_pkg), chown -R
# (ensure_dirs), and the bind mount of a web-settable CACHE_MOUNTS entry into every
# runner (build_args). A regression that let a share/device/system root or a `../`
# escape slip through would be high-consequence, so they earn a unit test.
#
# They are pure functions of CACHE_ROOT (env) plus, for the mount guard, one
# argument — no Docker, no filesystem writes — so we extract just the two functions
# from the engine (avoiding the script's dispatch side effects) and table-test them.
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

echo "safe-paths: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
