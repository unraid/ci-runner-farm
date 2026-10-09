#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'QUEUED POOLS FAIL: %s\n' "$*" >&2; exit 1; }
CI_PROVIDER=github GH_SCOPE=org RUNNER_MODE=pools AUTOSCALE=true ELASTIC_POOLS=true QUEUED_POOLS=true
RUNNER_POOLS='v3|build|os-build|unraid,build|5|2|6|0|3|16g|builtin;v3|build-small|build-small|self-hosted,linux,x64|1|0|6|0|1|4g|builtin;v3|build-large|os-build-large|os-build,size-large|1|0|6|0|6|16g|builtin'
pool_base_refresh
mode=sparse
shared_capacity_call() {
 [ "$1" = scale ] && [ "$2" = "$RUNNER_POOLS" ] || fail 'wrong native command'
 case "$mode" in
 sparse) printf 'build|1\nbuild-small|3\n' ;;
 zero) ;;
 unknown) return 1 ;;
 invalid) printf 'build|999\n' ;;
 esac
}
start_one() { printf '%s\n' "$NAME_PREFIX-$1" >> "$tmp/starts"; }
start_configured_capacity || fail 'sparse plan failed'
[ "$(cat "$tmp/starts")" = $'ci-runner-build-1\nci-runner-build-small-3' ] || fail 'plan expanded to 1..highest'
rm "$tmp/starts"
mode=zero
start_configured_capacity || fail 'zero plan failed'
[ ! -e "$tmp/starts" ] || fail 'zero plan resurrected owners'
mode=unknown
if start_configured_capacity; then fail 'unknown queue accepted'; fi
[ ! -e "$tmp/starts" ] || fail 'unknown queue started capacity'
mode=invalid
if start_configured_capacity; then fail 'out-of-bound slot accepted'; fi
[ ! -e "$tmp/starts" ] || fail 'invalid plan started capacity'
docker() { fail 'stopped-owner bypass'; }
start_stopped_managed || fail 'stopped restore bypassed demand'
printf 'queued-pools: sparse starts, cold zero, failed snapshot and stopped-owner guard passed\n'
