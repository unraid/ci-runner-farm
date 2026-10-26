#!/usr/bin/env bash
# Exercise the real provider image-preparation and native create paths without Docker.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'COLD IMAGE AUTH FAIL: %s\n' "$*" >&2; exit 1; }
export CI_PROVIDER=github GH_SCOPE=org NAME_PREFIX=ci-runner-build CRF_POOL_ID=build
export IMAGE_SOURCE=remote IMAGE=ghcr.io/example/runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export RUNNER_CPUS=6 RUNNER_MEMORY=16g
cached=false login_ok=true pull_ok=true native=true
log() { :; }
registry_login() { echo login >> "$tmp/order"; [ "$login_ok" = true ]; }
docker() {
 case "$1" in
 image) [ "$2" = inspect ] && [ "$3" = "$IMAGE" ] || fail 'wrong image inspection'; echo inspect >> "$tmp/order"; [ "$cached" = true ] ;;
 --config)
  [ "$2" = "$HOST_DOCKER_CONFIG" ] && [ "$3" = pull ] && [ "$4" = -- ] && [ "$5" = "$IMAGE" ] || fail 'pull lost private authentication configuration'
  echo pull >> "$tmp/order"; [ "$pull_ok" = true ] ;;
 create) [ "$2" = --no-healthcheck ] || fail 'native create lost healthcheck guard'; echo create >> "$tmp/order"; printf '%064d\n' 1 ;;
 run) echo run >> "$tmp/order" ;;
 *) fail 'unexpected Docker operation' ;;
 esac
}
github_build_args() { echo registration >> "$tmp/order"; ARGS=(-d --name "$2" "$IMAGE"); }
clear_args_tmpdir() { [ "${ARGS[${#ARGS[@]}-1]}" = "$IMAGE" ] || fail 'runner argv lost image'; echo cleanup >> "$tmp/order"; }
shared_capacity_enabled() { [ "$native" = true ]; }
shared_capacity_start() {
 [ "$1" = ci-runner-build-1 ] && [ "$2" = "$(printf '%064d' 1)" ] || fail 'admission lost immutable owner identity'
 echo admission >> "$tmp/order"; return 75
}
run_queued() {
 if github_start_one 1 ci-runner-build-1; then fail 'queued admission reported success'; else [ "$?" = 75 ] || fail 'native queued result changed'; fi
}
run_queued
[ "$(cat "$tmp/order")" = $'inspect\nlogin\npull\nregistration\ncreate\nadmission\ncleanup' ] || fail 'cold private image was not authenticated before registration and admitted create'
: > "$tmp/order"; cached=true
run_queued
[ "$(cat "$tmp/order")" = $'inspect\nregistration\ncreate\nadmission\ncleanup' ] || fail 'cached image performed unnecessary authentication or pull'
for failure in login pull; do
 : > "$tmp/order"; cached=false login_ok=true pull_ok=true
 if [ "$failure" = login ]; then login_ok=false; else pull_ok=false; fi
 if github_start_one 1 ci-runner-build-1; then fail 'failed image preparation accepted'; fi
 if grep -Eq 'registration|create|admission' "$tmp/order"; then fail 'image preparation failure minted credentials or created an owner'; fi
done
: > "$tmp/order"; IMAGE_SOURCE=builtin login_ok=true pull_ok=true
run_queued
[ "$(cat "$tmp/order")" = $'registration\ncreate\nadmission\ncleanup' ] || fail 'built-in startup changed'
# Empty remote settings select the existing built-in image and never authenticate.
(
 : > "$tmp/order"; IMAGE_SOURCE=remote IMAGE=""
 run_queued
 [ "$(cat "$tmp/order")" = $'registration\ncreate\nadmission\ncleanup' ] || fail 'empty remote setting changed built-in admission'
)
: > "$tmp/order"; IMAGE_SOURCE=remote native=false cached=false
github_start_one 1 ci-runner-build-1
[ "$(cat "$tmp/order")" = $'inspect\nlogin\npull\nregistration\nrun\ncleanup' ] || fail 'legacy startup lost authenticated image preparation'
printf 'cold-image-auth: cold, cached, login/pull refusal, native queued and legacy startup passed\n'
