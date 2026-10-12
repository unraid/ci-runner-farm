#!/usr/bin/env bash
# Verify missing/foreign mounts fail closed and the owned filesystem reaches jobs.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { echo "SHARED CACHE FAIL: $*" >&2; exit 1; }
SHARED_CACHE_ROOT=''
crf_shared_cache_mount || fail 'disabled feature changed existing farms'
SHARED_CACHE_ROOT=/mnt/cache/ci_object_store/mounts/shared
CI_PROVIDER=gitlab
if crf_shared_cache_mount 2>/dev/null; then fail 'unsupported provider accepted'; fi
CI_PROVIDER=github
if crf_shared_cache_mount 2>/dev/null; then fail 'missing mount accepted'; fi
(
  # Model a real canonical directory. Filesystem identity comes from findmnt,
  # independently of directory existence; a plain directory must be refused.
  [() {
    if [[ "$#" == 3 && "$1" == -d && "$2" == "$SHARED_CACHE_ROOT" ]]; then return 0; fi
    builtin [ "$@"
  }
  realpath() { printf '%s\n' "$SHARED_CACHE_ROOT"; }
  filesystem=zfs; mount_source=ci-shared-cache-v1
  findmnt() { case "$*" in *FSTYPE) echo "$filesystem";; *SOURCE) echo "$mount_source";; *) return 1;; esac; }
  timeout() { return "${stat_status:-0}"; }
  if crf_shared_cache_mount 2>/dev/null; then fail 'local directory accepted'; fi
  filesystem=fuse.seaweedfs; mount_source=foreign
  if crf_shared_cache_mount 2>/dev/null; then fail 'foreign filesystem accepted'; fi
  mount_source=ci-shared-cache-v1
  crf_shared_cache_mount || fail 'owned filesystem rejected'
  # Retry the real existing-owner start path. Only native Docker inspection
  # and admission are replaced; the mount policy and dispatch run unchanged.
  NAME_PREFIX=ci-runner-build; CRF_POOL_ID=build
  touch "$CFGDIR/shared-capacity.enabled"
  docker() { [ "$1" = inspect ]; }
  owner_id="$(printf '%064d' 1)"
  managed_runner_snapshot() { printf '%s|created\n' "$owner_id"; }
  shared_capacity_call() { printf '%s\n' "$*" >> "$tmp/admission"; }
  for state in missing local foreign disconnected; do
    filesystem=fuse.seaweedfs; mount_source=ci-shared-cache-v1; stat_status=0
    case "$state" in
      missing) filesystem='';;
      local) filesystem=zfs;;
      foreign) mount_source=foreign;;
      disconnected) stat_status=1;;
    esac
    if start_one 1 2>/dev/null; then fail "queued retry accepted $state mount"; fi
    [ ! -e "$tmp/admission" ] || fail "queued retry reached admission with $state mount"
  done
  filesystem=fuse.seaweedfs; mount_source=ci-shared-cache-v1; stat_status=0
  start_one 1 || fail 'queued retry rejected owned mount'
  grep -qx "start $NAME_PREFIX-1 $owner_id" "$tmp/admission" || fail 'queued retry lost owner identity'
  SHARED_CACHE_ROOT=''; filesystem=zfs
  start_one 1 || fail 'disabled shared cache blocked queued retry'
  [ "$(wc -l < "$tmp/admission")" -eq 2 ] || fail 'disabled cache skipped native admission'
  SHARED_CACHE_ROOT=/mnt/cache/ci_object_store/mounts/shared
  filesystem=fuse.seaweedfs
  stat_status=1
  if crf_shared_cache_mount 2>/dev/null; then fail 'disconnected filesystem accepted'; fi
  stat_status=0
  CACHE_MOUNTS='data:/mnt/ci-cache/subdir'
  if crf_shared_cache_mount 2>/dev/null; then fail 'cache destination overlap accepted'; fi
  CACHE_MOUNTS=''; USER_SHARE_MOUNTS='/mnt/user/ci/data:/mnt:rw'
  if crf_shared_cache_mount 2>/dev/null; then fail 'user-share destination overlap accepted'; fi
  USER_SHARE_MOUNTS=''
  SHARED_CACHE_ROOT=/mnt/cache/ci_object_store/mounts/../shared
  if crf_shared_cache_mount 2>/dev/null; then fail 'noncanonical source accepted'; fi
)
SHARED_CACHE_ROOT=''; before="$(github_confgen)"
SHARED_CACHE_ROOT=/mnt/cache/ci_object_store/mounts/shared
[ "$(github_confgen)" != "$before" ] || fail 'enabled mount omitted from generation'
SHARED_CACHE_ROOT=''
[ "$(github_confgen)" = "$before" ] || fail 'disabled feature changed generation'
# Generate a real runner argv after satisfying the independently tested guard.
crf_shared_cache_mount() { return 0; }
runner_host_service_ipv4() { echo 192.0.2.10; }
host() { echo fixture; }
github_registration_token() { echo registration-token; }
GH_OWNER=fixture; GH_SCOPE=org; NETWORK_ISOLATION=off; CACHE_MOUNTS=''
CACHE_ROOT="$tmp/cache"; mkdir -p "$CACHE_ROOT"
DIND=false; SHARE_DOCKER_SOCK=false; WORK_TMPFS_SIZE='1g'; RUNNER_CPUS=''; RUNNER_MEMORY=''
SHARED_CACHE_ROOT=/mnt/cache/ci_object_store/mounts/shared
github_build_args 1 || fail 'runner argv generation failed'
printf '%s\n' "${ARGS[@]}" > "$tmp/argv"
grep -qx 'type=bind,src=/mnt/cache/ci_object_store/mounts/shared,dst=/mnt/ci-cache' "$tmp/argv" || fail 'shared bind missing'
grep -qx 'CI_SHARED_CACHE=/mnt/ci-cache' "$tmp/argv" || fail 'shared path environment missing'
clear_args_tmpdir
SHARED_CACHE_ROOT=''
github_build_args 1 || fail 'disabled argv generation failed'
if printf '%s\n' "${ARGS[@]}" | grep -q CI_SHARED_CACHE; then fail 'disabled farm advertised shared cache'; fi
clear_args_tmpdir
echo 'shared cache guards and job bind passed'
