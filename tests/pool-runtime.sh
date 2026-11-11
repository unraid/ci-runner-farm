#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/cache"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'POOL RUNTIME FAIL: %s\n' "$*" >&2; exit 1; }

CRF_SOURCE_ONLY=0
ip() { printf '1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.55 uid 0\n'; }
[ "$(runner_host_service_ipv4)" = 192.0.2.55 ] || fail 'local farm service address resolution failed'
unset -f ip
CRF_SOURCE_ONLY=1

build='v3|build|ci-build|linux,x64|2|0|2|0|2|8g|builtin'
qa='v3|qa-vm|qa-vm-client|linux,x64|1|0|1|0|1.5|4g|ghcr.io/unraid/qa-vm-client:latest'
RUNNER_MODE=pools RUNNER_POOLS="$build;$qa" GH_SCOPE=org CI_PROVIDER=github
RUNNER_CPUS='' RUNNER_MEMORY=16g IMAGE_SOURCE=builtin IMAGE=''
CACHE_ROOT="$tmp/cache" CACHE_MOUNTS='' WORK_TMPFS_SIZE=1g
ACCESS_TOKEN='' NO_REGISTER=1 DIND=false SHARE_DOCKER_SOCK=false NETWORK_ISOLATION=off
pool_base_refresh

validate_runner_mode || fail "$POOL_CONFIG_ERROR"
pool_activate qa-vm || fail 'GitHub pool activation failed'
[ "$NAME_PREFIX" = ci-runner-qa-vm ] || fail 'pool name prefix is wrong'
[ "$RUNNER_LABELS" = qa-vm-client,linux,x64 ] || fail 'pool labels are wrong'
[ "$RUNNER_CPUS" = 1.5 ] && [ "$RUNNER_MEMORY" = 4g ] || fail 'pool resources are wrong'
[ "$(effective_image)" = ghcr.io/unraid/qa-vm-client:latest ] || fail 'pool image is wrong'
github_build_args 1 ci-runner-qa-vm-1 || fail 'GitHub pool argv failed'
args="$(printf '%s\n' "${ARGS[@]}")"
printf '%s\n' "$args" | grep -qx 'net.unraid.ci-runner-farm.pool=qa-vm' || fail 'GitHub pool label missing'
printf '%s\n' "$args" | grep -qx 'LABELS=qa-vm-client,linux,x64' || fail 'GitHub routing labels missing'
printf '%s\n' "$args" | grep -qx 'NO_DEFAULT_LABELS=true' \
  || fail 'pool without self-hosted kept GitHub default labels'
# An existing pool that omits self-hosted must drain onto the exact labels.
exact_generation="$(github_confgen)"
github_pool_labels_exact() { return 1; }
[ "$(github_confgen)" != "$exact_generation" ] || fail 'exact labels did not change the config generation'
unset -f github_pool_labels_exact
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/providers/github.sh
printf '%s\n' "$args" | grep -qx 'host.docker.internal:host-gateway' \
  || fail 'GitHub runner does not expose its local farm host gateway'
printf '%s\n' "$args" | grep -qx 'runner-farm.host:192.0.2.10' \
  || fail 'GitHub runner does not expose its local farm service address'
printf '%s\n' "$args" | grep -qx 'ghcr.io/unraid/qa-vm-client:latest' || fail 'GitHub pool image missing'

# A pool that lists self-hosted, and every single-layout runner, keep the defaults.
RUNNER_POOLS='v3|build|ci-build|self-hosted,linux,x64|2|0|2|0|2|8g|builtin'
pool_base_refresh
validate_runner_mode || fail "$POOL_CONFIG_ERROR"
pool_activate build || fail 'self-hosted pool activation failed'
github_build_args 1 ci-runner-build-1 || fail 'self-hosted pool argv failed'
grep -q NO_DEFAULT_LABELS <<< "$(printf '%s\n' "${ARGS[@]}")" && fail 'pool with self-hosted lost GitHub default labels'
RUNNER_MODE=single RUNNER_POOLS='' RUNNER_LABELS=ci-build
pool_base_refresh
validate_runner_mode || fail "$POOL_CONFIG_ERROR"
github_build_args 1 ci-runner-1 || fail 'single-layout argv failed'
grep -q NO_DEFAULT_LABELS <<< "$(printf '%s\n' "${ARGS[@]}")" && fail 'single-layout runner lost GitHub default labels'
RUNNER_MODE=pools RUNNER_POOLS="$build;$qa" RUNNER_LABELS='self-hosted,unraid,build'
pool_base_refresh
validate_runner_mode || fail "$POOL_CONFIG_ERROR"

start_log="$tmp/starts"
provider_remote_image_host_pull_required() { return 1; }
start_one() { printf '%s|%s|%s|%s\n' "$CRF_POOL_ID" "$1" "$RUNNER_LABELS" "$(effective_image)" >> "$start_log"; }
start_configured_capacity || fail 'configured pool capacity failed'
[ "$(grep -c '^build|' "$start_log")" -eq 2 ] || fail 'build fixed capacity was not started'
[ "$(grep -c '^qa-vm|' "$start_log")" -eq 1 ] || fail 'QA-VM fixed capacity was not started'
grep -qF 'qa-vm|1|qa-vm-client,linux,x64|ghcr.io/unraid/qa-vm-client:latest' "$start_log" \
  || fail 'QA-VM pool start did not retain its image and labels'

# One image serves distinct repository audiences without sharing private binds.
(
  RUNNER_GROUP=Default CACHE_MOUNTS='common:/home/runner/.cache/common' USER_SHARE_MOUNTS=''
  RUNNER_UID=1001 RUNNER_GID=121 RUN_AS_ROOT=false
  RUNNER_POOLS="$build;${qa%|*}|builtin"
  RUNNER_POOL_CONTEXTS='v1|qa-vm|runner_group=Private Builds|cache_mounts=private-cache:/home/runner/.cache/private|user_share_mounts=/mnt/user/ci/data:/mnt/data:rw'
  pool_base_refresh
  validate_runner_mode || fail 'valid scoped execution settings rejected'
  crf_user_share_mount_source() { printf '%s' "$1"; }
  provider_validate_settings || fail 'effective pool mount validation failed'
  pool_activate qa-vm || fail 'private pool activation failed'
  [ "$RUNNER_GROUP" = 'Private Builds' ] || fail 'private group not selected'
  [ "$CACHE_MOUNTS" = 'private-cache:/home/runner/.cache/private' ] || fail 'private cache not selected'
  [ "$USER_SHARE_MOUNTS" = '/mnt/user/ci/data:/mnt/data:rw' ] || fail 'private share not selected'
  private_image="$(effective_image)"; private_generation="$(github_confgen)"
  github_build_args 1 ci-runner-qa-vm-1 || fail 'private pool argv failed'
  printf '%s\n' "${ARGS[@]}" | grep -qx 'RUNNER_GROUP=Private Builds' || fail 'private registration group missing'
  printf '%s\n' "${ARGS[@]}" | grep -qx "${CACHE_ROOT}/private-cache:/home/runner/.cache/private" || fail 'private cache bind missing'
  printf '%s\n' "${ARGS[@]}" | grep -qx 'type=bind,src=/mnt/user/ci/data,dst=/mnt/data' || fail 'private share bind missing'
  pool_activate build || fail 'general pool activation failed'
  [ "$RUNNER_GROUP" = Default ] && [ "$USER_SHARE_MOUNTS" = '' ] \
    && [ "$CACHE_MOUNTS" = 'common:/home/runner/.cache/common' ] || fail 'private settings leaked into general pool'
  [ "$(effective_image)" = "$private_image" ] || fail 'contexts selected different generic images'
  general_generation="$(github_confgen)"
  github_build_args 1 ci-runner-build-1 || fail 'general pool argv failed'
  if printf '%s\n' "${ARGS[@]}" | grep -E 'private-cache|/mnt/data|Private Builds'; then fail 'private grant leaked into general argv'; fi
  pool_activate qa-vm || fail 'return to private pool failed'
  [ "$(github_confgen)" = "$private_generation" ] || fail 'context switching changed private identity'
  RUNNER_POOL_CONTEXTS="${RUNNER_POOL_CONTEXTS/Private Builds/Other Builds}"
  pool_activate qa-vm
  [ "$(github_confgen)" != "$private_generation" ] || fail 'group change did not invalidate private runner'
  pool_activate build
  [ "$(github_confgen)" = "$general_generation" ] || fail 'private change invalidated unrelated general runner'

  # Provision the effective union, without re-owning existing cache contents.
  chown() { printf '%s\n' "$*" >> "$tmp/chown-calls"; }
  ensure_dirs || fail 'configured cache union was not provisioned'
  [ -d "$CACHE_ROOT/common" ] && [ -d "$CACHE_ROOT/private-cache" ] || fail 'pool-only cache was not created'
  grep -Fq "1001:121 $CACHE_ROOT/private-cache" "$tmp/chown-calls" || fail 'pool-only cache owner not assigned'
  calls="$(wc -l < "$tmp/chown-calls")"
  ensure_dirs
  [ "$(wc -l < "$tmp/chown-calls")" = "$calls" ] || fail 'existing cache was recursively re-owned'

  RUNNER_POOL_CONTEXTS='v1|qa-vm|cache_mounts=private-cache:/mnt/data/subdir|user_share_mounts=/mnt/user/ci/data:/mnt/data:rw'
  if provider_validate_settings 2>/dev/null; then fail 'private cross-mount overlap was accepted'; fi
  (
    CACHE_ROOT="$tmp/refused-before-provision"
    RUNNER_POOL_CONTEXTS='v1|unknown|cache_mounts=private-cache:/home/runner/.cache/private'
    if ensure_dirs 2>/dev/null; then fail 'unknown context was provisioned'; fi
    [ ! -e "$CACHE_ROOT" ] || fail 'invalid context created cache directories'
  )
  RUNNER_POOL_CONTEXTS='v1|qa-vm|cache_mounts=private-cache:/home/runner/.cache/private'
  crf_safe_cache_root() { printf '%s' "$CACHE_ROOT"; }
  crf_cache_mutation_idle() { return 1; }
  if cmd_prune_cache; then fail 'active cache prune was accepted'; fi
  [ -d "$CACHE_ROOT/private-cache" ] || fail 'active private cache was removed'
  mkdir "$CACHE_ROOT/unrelated"
  crf_cache_mutation_idle() { return 0; }
  cmd_prune_cache || fail 'idle cache prune failed'
  [ ! -e "$CACHE_ROOT/private-cache" ] && [ ! -e "$CACHE_ROOT/common" ] \
    && [ -d "$CACHE_ROOT/unrelated" ] || fail 'cache prune escaped configured pool children'

  RUNNER_POOL_CONTEXTS='v1|qa-vm|runner_group=|cache_mounts=|user_share_mounts='
  pool_activate qa-vm
  [ -z "$RUNNER_GROUP$CACHE_MOUNTS$USER_SHARE_MOUNTS" ] || fail 'explicit clear inherited a global setting'

  # Removing the optional companion must clear it during a locked reload.
  RUNNER_POOL_CONTEXTS='v1|qa-vm|runner_group=Private Builds|cache_mounts=|user_share_mounts='
  pool_activate qa-vm
  printf 'RUNNER_GROUP="Default"\nCACHE_MOUNTS="common:/home/runner/.cache/common"\nUSER_SHARE_MOUNTS=""\n' > "$CFG"
  reload_locked_snapshot || fail 'locked reload failed'
  [ "$RUNNER_POOL_CONTEXTS" = '' ] && [ "$RUNNER_GROUP" = Default ] \
    && [ "$CACHE_MOUNTS" = 'common:/home/runner/.cache/common' ] \
    && [ "$USER_SHARE_MOUNTS" = '' ] || fail 'removed context survived reload'
)

CI_PROVIDER=gitlab GH_SCOPE=repo
RUNNER_LABELS='self-hosted,unraid,build' RUNNER_CPUS='' RUNNER_MEMORY=16g IMAGE_SOURCE=builtin IMAGE=''
printf '%s\n' 'glrt-pooltoken0000000000' > "$CRF_CFGDIR/gitlab-runner-token.qa-vm"
pool_base_refresh
validate_runner_mode || fail "GitLab pool validation failed: $POOL_CONFIG_ERROR"
pool_activate qa-vm || fail 'GitLab pool activation failed'
[ "$GITLAB_RUNNER_TOKEN" = glrt-pooltoken0000000000 ] || fail 'GitLab pool token was not selected'
[ "$(effective_image)" = ghcr.io/unraid/qa-vm-client:latest ] || fail 'GitLab pool image is wrong'

rm -f "$CRF_CFGDIR/gitlab-runner-token.qa-vm"
if pool_activate qa-vm 2>/dev/null; then fail 'GitLab pool accepted a missing pool token'; fi

printf 'pool-runtime: provider-neutral pool activation and image routing passed\n'
