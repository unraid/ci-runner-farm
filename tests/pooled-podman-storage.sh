#!/usr/bin/env bash
# Exercise actual adapter arguments, per-slot lifetime and opt-in boundaries.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
cd "$(dirname "$0")/.."
realpath -e -- / >/dev/null 2>&1 || { echo 'GNU coreutils required' >&2; exit 1; }
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'POOLED PODMAN FAIL: %s\n' "$*" >&2; exit 1; }
CACHE_ROOT="$tmp/cache"; ACCESS_TOKEN=''; NO_REGISTER=1
CI_PROVIDER=github; GH_SCOPE=org; GH_OWNER=example; DIND=true; SHARE_DOCKER_SOCK=false
NETWORK_ISOLATION=off; RUNNER_LABELS=self-hosted; IMAGE_SOURCE=builtin
CACHE_MOUNTS='npm:/home/runner/.npm'; USER_SHARE_MOUNTS=''; WORK_TMPFS_SIZE=''; EPHEMERAL=true
CPU_PINNING=false; RUNNER_DNS=''; PODMAN_POOL_STORAGE=true
host() { printf 'mockhost\n'; }
runner_host_service_ipv4() { printf '192.0.2.10\n'; }
crf_safe_cache_root() { printf '%s' "$CACHE_ROOT"; }
# The portable test records intended ownership; the native runtime gate verifies it.
chown() { printf '%s\n' "$*" >> "$tmp/chown"; }
docker() {
  case "$1 ${2:-}" in
    'container inspect') echo 'Error: No such container' >&2; return 1 ;;
    'image inspect') return 0 ;;
    *) fail "unexpected Docker effect $1" ;;
  esac
}
bind_of() {
  local previous='' value
  for value in "${ARGS[@]}"; do
    if [ "$previous" = -v ] && [ "${value#*:}" = "$1" ]; then printf '%s\n' "${value%:*}"; fi
    previous="$value"
  done
}
mkdir -p "$CACHE_ROOT"
github_build_args 1 ci-runner-1 || fail 'valid opt-in rejected'
slot="$CACHE_ROOT/work/ci-runner-1"
rootful="$(bind_of /var/lib/containers/storage)"
rootless="$(bind_of /home/runner/.local/share/containers/storage)"
workspace="$(bind_of /_work)"
[ "$rootful" = "$slot/podman-root" ] || fail 'rootful Podman still uses the runner writable layer'
[ "$rootless" = "$slot/podman-runner" ] || fail 'runner Podman still uses the runner writable layer'
[ "$workspace" = "$slot/workspace" ] || fail 'stores are exposed through the workspace bind'
for path in "$rootful" "$rootless" "$workspace"; do
  [ -d "$path" ] && [ ! -L "$path" ] && [ "$(realpath -e -- "$path")" = "$path" ] || fail 'noncanonical slot layout'
done
[ "$(stat -c %a "$rootful")" = 700 ] || fail 'rootful mode is not private'
[ "$(stat -c %a "$rootless")" = 700 ] || fail 'runner mode is not private'
grep -Fq "0:0 $rootful" "$tmp/chown" || fail 'rootful ownership was not assigned'
grep -Fq "$RUNNER_UID:$RUNNER_GID $rootless" "$tmp/chown" || fail 'runner ownership was not assigned'
printf 'rootful\n' > "$rootful/marker"; printf 'runner\n' > "$rootless/marker"
mkdir "$workspace/repo"; rm -rf -- "$workspace/repo"
[ -f "$rootful/marker" ] && [ -f "$rootless/marker" ] || fail 'workspace cleanup erased a store'
github_build_args 2 ci-runner-2 || fail 'second slot rejected'
[ "$(bind_of /var/lib/containers/storage)" != "$rootful" ] || fail 'slots share rootful state'
[ ! -e "$(bind_of /var/lib/containers/storage)/marker" ] || fail 'slot saw another store'

# Unsupported opt-ins fail before directory creation or retirement.
for variant in persistent tmpfs no-dind gitlab malformed; do
  (
    case "$variant" in
      persistent) EPHEMERAL=false ;; tmpfs) WORK_TMPFS_SIZE=1g ;;
      no-dind) DIND=false ;; gitlab) CI_PROVIDER=gitlab ;; malformed) PODMAN_POOL_STORAGE=maybe ;;
    esac
    if github_build_args 3 ci-runner-3 > "$tmp/reject" 2>&1; then fail "accepted unsupported $variant"; fi
    [ ! -e "$CACHE_ROOT/work/ci-runner-3" ] && [ ! -e "$CACHE_ROOT/docker/ci-runner-3" ] || fail 'rejection had storage effects'
  )
done
for mount in 'other:/var/lib/containers' 'other:/home/runner/.local/share/containers/storage/cache'; do
  (
    CACHE_MOUNTS="$mount"
    if github_build_args 3 ci-runner-3 > "$tmp/reject" 2>&1; then fail 'overlapping cache accepted'; fi
    [ ! -e "$CACHE_ROOT/work/ci-runner-3" ] || fail 'overlap retired a workspace'
  )
done
# Cleanup needs both the native validation name and its captured workspace bind.
validation="$NAME_PREFIX-validate-012345abcdef"
validation_root="$CACHE_ROOT/work/$validation"
mkdir -p "$validation_root/podman-root" "$validation_root/podman-runner" "$validation_root/workspace"
printf 'retained\n' > "$validation_root/podman-root/marker"
REFERENCES=''
crf_docker_storage_references() { [ "$REFERENCES" != unknown ] || return 1; printf '%s' "$REFERENCES"; }
if github_cleanup_validation_storage "$validation" /foreign/workspace > "$tmp/reject" 2>&1; then fail 'foreign validation bind accepted'; fi
[ -f "$validation_root/podman-root/marker" ] || fail 'wrong binding deleted storage'
REFERENCES="mount|$validation_root/podman-root/merged"
if github_cleanup_validation_storage "$validation" "$validation_root/workspace" > "$tmp/reject" 2>&1; then fail 'mounted validation store deleted'; fi
REFERENCES=''
github_cleanup_validation_storage "$validation" "$validation_root/workspace" || fail 'settled validation cleanup failed'
[ ! -e "$validation_root" ] || fail 'settled private stores leaked'
# Disabled behavior keeps the preexisting bind and never adds Podman mounts.
# Existing stores remain while another container, mount or unknown inventory exists.
REFERENCES=''
crf_docker_storage_references() { [ "$REFERENCES" != unknown ] || return 1; printf '%s' "$REFERENCES"; }
for REFERENCES in "consumer|$rootful" "mount|$rootful/merged" unknown; do
  if github_build_args 1 ci-runner-1 > "$tmp/reject" 2>&1; then fail 'referenced slot was retired'; fi
  [ -f "$rootful/marker" ] || fail 'reference rejection destroyed storage'
done
REFERENCES=''
# A stale opt-in must not survive configuration reload with the key omitted.
printf 'PODMAN_POOL_STORAGE="true"\n' > "$CFG"
load_cfg; [ "$PODMAN_POOL_STORAGE" = true ] || fail 'opt-in did not load'
printf '' > "$CFG"
load_cfg; [ "$PODMAN_POOL_STORAGE" = false ] || fail 'omitted opt-in stayed enabled'
github_build_args 4 ci-runner-4 || fail 'disabled old behavior rejected'
[ "$(bind_of /_work)" = "$CACHE_ROOT/work/ci-runner-4" ] || fail 'disabled workspace changed'
[ -z "$(bind_of /var/lib/containers/storage)" ] || fail 'disabled rootful bind added'
# Execute the real validator boundary with mocked Docker, checking its remote
# program syntax and both users without running a second host engine.
(
  calls="$tmp/validate-calls"; : > "$calls"
  docker() {
    [ "$1" = exec ] || fail 'validator dispatched a non-exec effect'
    printf '%s\n' "$*" >> "$calls"
    local previous='' argument script=''
    for argument in "$@"; do
      [ "$previous" != -ec ] || script="$argument"
      previous="$argument"
    done
    [ -z "$script" ] || /bin/sh -n <<EOF
$script
EOF
  }
  github_validate_pooled_podman immutable-validation-id || fail 'native validator arguments failed'
  [ "$(wc -l < "$calls")" -gt 3 ] || fail 'both native users were not probed'
  grep -q '1001:121' "$calls" || fail 'runner identity was not probed'
  grep -q 'podman build --isolation=chroot --network=none' "$calls" || fail 'native image build was omitted'
)
printf 'pooled Podman adapter contracts passed.\n' 
