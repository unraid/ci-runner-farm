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
printf '%s\n' "$args" | grep -qx 'host.docker.internal:host-gateway' \
  || fail 'GitHub runner does not expose its local farm host gateway'
printf '%s\n' "$args" | grep -qx 'runner-farm.host:192.0.2.10' \
  || fail 'GitHub runner does not expose its local farm service address'
printf '%s\n' "$args" | grep -qx 'ghcr.io/unraid/qa-vm-client:latest' || fail 'GitHub pool image missing'

start_log="$tmp/starts"
provider_remote_image_host_pull_required() { return 1; }
start_one() { printf '%s|%s|%s|%s\n' "$CRF_POOL_ID" "$1" "$RUNNER_LABELS" "$(effective_image)" >> "$start_log"; }
start_configured_capacity || fail 'configured pool capacity failed'
[ "$(grep -c '^build|' "$start_log")" -eq 2 ] || fail 'build fixed capacity was not started'
[ "$(grep -c '^qa-vm|' "$start_log")" -eq 1 ] || fail 'QA-VM fixed capacity was not started'
grep -qF 'qa-vm|1|qa-vm-client,linux,x64|ghcr.io/unraid/qa-vm-client:latest' "$start_log" \
  || fail 'QA-VM pool start did not retain its image and labels'

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
