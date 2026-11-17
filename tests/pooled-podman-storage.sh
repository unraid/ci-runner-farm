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
crf_docker_storage_references() { return 0; }
github_work_trash_sweep_async() { github_work_trash_sweep; }
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
# Noncanonical destinations must reject before touching an existing slot.
for destination in /var/lib/containers/storage/ /; do
  (
    CACHE_MOUNTS="other:$destination"
    if github_build_args 1 ci-runner-1 > "$tmp/reject" 2>&1; then fail 'noncanonical destination retired an existing slot'; fi
    [ -f "$rootful/marker" ] || fail 'noncanonical rejection lost the old store'
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
# Ordinary purge must retire settled pooled stores, but retain referenced trees.
(
  root="$tmp/removal"; CACHE_ROOT="$root"; name=ci-runner-9
  directory="$root/work/$name"
  provider_stop_remove_container() { [ "${STOP_FAIL:-false}" = false ]; }
  github_deregister_runner_api() { return 0; }
  github_runner_registration_name() { printf fixture; }
  mkdir -p "$directory/podman-root"
  echo retained > "$directory/podman-root/marker"
  STOP_FAIL=true
  if github_remove_runner "$name" true > "$tmp/reject" 2>&1; then fail 'failed stop allowed store removal'; fi
  [ -f "$directory/podman-root/marker" ] || fail 'failed stop lost pooled stores'
  STOP_FAIL=false
  REFERENCES=unknown
  github_remove_runner "$name" false || fail 'non-purging removal changed behavior'
  [ -f "$directory/podman-root/marker" ] || fail 'non-purging removal lost pooled stores'
  for reference in "consumer|$directory/podman-root" "mount|$directory/podman-runner/merged" unknown ''; do
    mkdir -p "$directory/podman-root" "$directory/podman-runner" "$root/docker/$name"
    echo retained > "$directory/podman-root/marker"
    REFERENCES="$reference"
    if [ -n "$reference" ]; then
      if github_remove_runner "$name" true > "$tmp/reject" 2>&1; then fail 'purge accepted referenced pooled stores'; fi
      [ -f "$directory/podman-root/marker" ] || fail 'purge erased referenced pooled store'
    else
      github_remove_runner "$name" true || fail 'settled pooled purge rejected'
      [ ! -e "$directory" ] || fail 'retired pooled stores leaked after successful removal'
    fi
  done
  # Existing workspaces without stores keep their legacy lifetime, even with
  # unknown pooled-store references and a disabled option.
  mkdir -p "$directory"
  echo retained > "$directory/legacy"
  PODMAN_POOL_STORAGE=false; REFERENCES=unknown
  github_remove_runner "$name" true || fail 'legacy removal changed behavior'
  [ -f "$directory/legacy" ] || fail 'legacy workspace was unexpectedly purged'
)
# Full cache prune must apply the same reference fence to work, including when
# the opt-in has since been disabled. No unmanaged consumer is safe to erase.
(
  root="$tmp/prune"; CACHE_ROOT="$root"; PODMAN_POOL_STORAGE=false
  directory="$root/work/ci-runner-8"
  crf_cache_mutation_idle() { return 0; }
  for reference in "consumer|$directory/podman-root" "mount|$directory/podman-root/merged" unknown ''; do
    mkdir -p "$directory/podman-root"
    echo retained > "$directory/podman-root/marker"
    REFERENCES="$reference"
    if [ -n "$reference" ]; then
      if cmd_prune_cache > "$tmp/reject" 2>&1; then fail 'prune accepted a referenced work layout'; fi
      [ -f "$directory/podman-root/marker" ] || fail 'prune erased referenced pooled storage'
    else
      cmd_prune_cache > "$tmp/prune-log" || fail 'unreferenced cache prune rejected'
      [ ! -e "$directory" ] || fail 'unreferenced work layout leaked'
    fi
  done
)
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
  grep -Fq 'exec --user 0:0 --env HOME=/root immutable-validation-id sh -ec' "$calls" || fail 'root probe identity changed'
  grep -Fq 'exec --user 1001:121 --env HOME=/home/runner immutable-validation-id sh -ec' "$calls" || fail 'runner probe identity changed'
  grep -q 'podman build --isolation=chroot --network=host --pull=never' "$calls" || fail 'native image build was omitted'
)
# Execute the actual remote programs through controlled command boundaries.
# This catches shell exit semantics that syntax and argument checks cannot prove.
(
  mkdir "$tmp/probe-bin"
  cat > "$tmp/probe-bin/id" <<'SH'
#!/bin/sh
case "$1" in -u) echo "${PROBE_UID:-1001}" ;; -g) echo "${PROBE_GID:-121}" ;; *) exit 1 ;; esac
SH
  cat > "$tmp/probe-bin/getent" <<'SH'
#!/bin/sh
printf 'runner:x:1001:121::%s:/bin/sh\n' "${PROBE_HOME:-/home/runner}"
SH
  cat > "$tmp/probe-bin/podman" <<'SH'
#!/bin/sh
case "$1 $2" in
  'info --format')
    [ "${PROBE_INFO_EXIT:-0}" = 0 ] || exit "$PROBE_INFO_EXIT"
    if [ "${PROBE_REQUIRE_CONFIG_PARENT:-false}" = true ] && [ "$PROBE_EXPECTED" = /home/runner/.local/share/containers/storage ]; then
      [ -f "$PROBE_CONFIG_PARENT/runner-owned" ] || exit 72
    fi
    graphroot="${PROBE_GRAPHROOT:-$PROBE_EXPECTED}"
    if [ "$PROBE_EXPECTED" = /home/runner/.local/share/containers/storage ]; then
      graphroot="${PROBE_RUNNER_GRAPHROOT:-$graphroot}"
    fi
    printf '%s\n' "$graphroot" ;;
  'build --isolation=chroot')
    [ "$3" = --network=host ] && [ "$4" = --pull=never ] || exit 96
    for context do :; done
    [ "$(cat "$context/Containerfile")" = "$(printf 'FROM scratch\nCOPY payload /payload\n')" ] || exit 97
    exit "${PROBE_BUILD_EXIT:-0}" ;;
  'image inspect') [ "${PROBE_INSPECT_EXIT:-0}" = 0 ] || exit "$PROBE_INSPECT_EXIT"; echo 'sha256:probe-image' ;;
  *) exit 95 ;;
esac
SH
  cat > "$tmp/probe-bin/df" <<'SH'
#!/bin/sh
exit "${PROBE_DF_EXIT:-0}"
SH
  cat > "$tmp/probe-bin/chown" <<'SH'
#!/bin/sh
# Execute the ownership boundary without requiring root or touching host home.
[ "$#" = 2 ] && [ "$1" = 1001:121 ] && [ "$2" = "$PROBE_CONFIG_PARENT" ] || exit 73
[ "${PROBE_CHOWN_EXIT:-0}" = 0 ] || exit "$PROBE_CHOWN_EXIT"
touch "$PROBE_CONFIG_PARENT/runner-owned"
SH
  chmod +x "$tmp/probe-bin/"*
  export PROBE_CONFIG_PARENT="$tmp/config-parent"
  mkdir "$PROBE_CONFIG_PARENT"
  docker() {
    local previous='' argument script='' expected=''
    for argument in "$@"; do
      [ "$previous" != -ec ] || script="$argument"
      previous="$argument"; expected="$argument"
    done
    [ -n "$script" ] || return 94
    # Redirect only the config-parent boundary into this private fixture.
    script="${script//\/home\/runner\/.config/$PROBE_CONFIG_PARENT}"
    PATH="$tmp/probe-bin:$PATH" PROBE_EXPECTED="$expected" /bin/sh -ec "$script" sh "$expected"
  }
  github_validate_pooled_podman immutable-validation-id > "$tmp/probe-log" 2>&1 || fail 'valid executed probe rejected'
  grep -qx 'pooled-podman result user=root step=complete exit=0 store=root_store' "$tmp/probe-log" || fail 'root completion was not recorded'
  grep -qx 'pooled-podman result user=runner step=complete exit=0 store=runner_store' "$tmp/probe-log" || fail 'runner completion was not recorded'
  rm -f "$PROBE_CONFIG_PARENT/runner-owned"
  PROBE_REQUIRE_CONFIG_PARENT=true github_validate_pooled_podman immutable-validation-id > "$tmp/probe-log" 2>&1 \
    || fail 'Docker-created cache parent was not prepared before the runner Podman probe'
  (
    export PROBE_CHOWN_EXIT=74
    if github_validate_pooled_podman immutable-validation-id > "$tmp/probe-log" 2>&1; then
      fail 'ownership preparation failure was accepted'
    fi
    grep -qx 'pooled-podman result user=image step=identity exit=74 store=unobserved' "$tmp/probe-log" \
      || fail 'ownership failure lost its closed identity result'
  )
  mv "$PROBE_CONFIG_PARENT" "$tmp/config-parent-target"
  ln -s "$tmp/config-parent-target" "$PROBE_CONFIG_PARENT"
  if github_validate_pooled_podman immutable-validation-id > "$tmp/probe-log" 2>&1; then
    fail 'symlinked config parent was accepted'
  fi
  rm "$PROBE_CONFIG_PARENT"
  mv "$tmp/config-parent-target" "$PROBE_CONFIG_PARENT"
  for invalid in uid gid home graphroot runner-graphroot info df build inspect; do
    (
      expected_user=image; expected_step=identity; expected_exit=1; expected_store=unobserved
      case "$invalid" in
        uid) export PROBE_UID=1002 ;; gid) export PROBE_GID=122 ;;
        home) export PROBE_HOME=/wrong ;;
        graphroot) export PROBE_GRAPHROOT=/wrong; expected_user=root; expected_step=graphroot_check; expected_store=other ;;
        runner-graphroot) export PROBE_RUNNER_GRAPHROOT=/private/SECRET-CANARY; expected_user=runner; expected_step=graphroot_check; expected_store=other ;;
        info) export PROBE_INFO_EXIT=17; expected_user=root; expected_step=info; expected_exit=17 ;;
        df) export PROBE_DF_EXIT=18; expected_user=root; expected_step=df; expected_exit=18; expected_store=root_store ;;
        build) export PROBE_BUILD_EXIT=23; expected_user=root; expected_step=build; expected_exit=23; expected_store=root_store ;;
        inspect) export PROBE_INSPECT_EXIT=19; expected_user=root; expected_step=inspect; expected_exit=19; expected_store=root_store ;;
      esac
      if github_validate_pooled_podman immutable-validation-id > "$tmp/probe-log" 2>&1; then
        fail "executed validator accepted wrong $invalid"
      fi
      grep -qx "pooled-podman result user=$expected_user step=$expected_step exit=$expected_exit store=$expected_store" "$tmp/probe-log" \
        || fail "failed $invalid probe lost its specific failure record"
      if [ "$invalid" = runner-graphroot ]; then
        grep -q '^pooled-podman graphroot=/var/lib/containers/storage uid=' "$tmp/probe-log" || fail 'runner test skipped root probe'
        ! grep -q 'SECRET-CANARY' "$tmp/probe-log" || fail 'graphroot failure exposed an arbitrary path'
        ! grep -q 'user=runner step=complete exit=0 store=runner_store' "$tmp/probe-log" || fail 'failed runner probe reported completion'
      fi
    )
  done
  (
    export PROBE_GRAPHROOT=/wrong
    if github_validate_pooled_podman immutable-validation-id > "$tmp/probe-log" 2>&1; then
      fail 'graphroot mismatch unexpectedly passed'
    fi
    grep -qx 'pooled-podman result user=root step=graphroot_check exit=1 store=other' "$tmp/probe-log" \
      || fail 'failed native probe did not identify its closed user/step/exit'
  )
)
printf 'pooled Podman adapter contracts passed.\n'
