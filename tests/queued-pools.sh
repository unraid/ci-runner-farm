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

# General queues are read by Farm before short native owner leases. No failed
# scan, missing capability, or unknown apply may fall back to QA queue reads.
RUNNER_POOLS="${RUNNER_POOLS/os-build/general-build}"
pool_base_refresh
mode=good
php() {
 case "$2" in
 warm-targets) printf '%s\n' warm-targets >> "$tmp/order"; printf '{}';;
 scan) printf '%s\n' scan >> "$tmp/order"; [ "$mode" != scan-fails ] || return 1; printf '{}';;
 targets) printf '%s\n' targets >> "$tmp/order"; [ "$mode" != targets-fails ] || return 1; printf '{}';;
 *) fail 'unexpected PHP action';;
 esac
}
shared_capacity_call() {
 case "$1" in
 demand-warm) printf '%s\n' warm >> "$tmp/order"; [ "$mode" != capability-missing ] || return 1; printf 'build|2\n';;
 demand-observe) printf '%s\n' observe >> "$tmp/order"; [ "$mode" != capability-missing ] || return 1; printf '{}';;
 demand-apply) printf '%s\n' apply >> "$tmp/order"; [ "$mode" != apply-unknown ] || return 1; printf 'build|1\n';;
 *) fail 'general demand fell back to QA scale';;
 esac
}
start_configured_capacity || fail 'Farm general plan failed'
[ "$(cat "$tmp/order")" = $'warm-targets\nwarm\nscan\nobserve\ntargets\napply' ] || fail 'warm recovery or queue lease order differs'
rm "$tmp/starts"
for mode in scan-fails capability-missing targets-fails apply-unknown; do
 if start_configured_capacity; then fail "accepted $mode"; fi
 if [ "$mode" = capability-missing ]; then
  [ ! -e "$tmp/starts" ] || fail "started after unknown native capability"
 else
  [ "$(cat "$tmp/starts")" = ci-runner-build-2 ] || fail "failed queue evidence changed warm-only effects"
  rm "$tmp/starts"
 fi
done
printf 'queued-pools: Farm owns general queue sizing; staged capability/unknown evidence preserves owners\n'

# Full planning (including native reads) stops before effects during cooldown.
mode=deferred
php() {
 case "$2" in begin) printf 'begin\n' >> "$tmp/rate-order"; [ "$mode" != deferred ];; *) fail 'deferred pass reached network scan';; esac
}
crf_storage_pressure_cleanup() { :; }
validate_runner_mode() { :; }
shared_capacity_poison_scan() { fail 'cooldown reached poison planning'; }
shared_capacity_call() { fail 'cooldown reached native planning'; }
if autoscale_tick; then fail 'cooldown reported applied plan'; else [ "$?" -eq 75 ] || fail 'cooldown lost deferred status'; fi
[ "$(cat "$tmp/rate-order")" = begin ] || fail 'background rate gate not reached'
# Closing inherited lock descriptors must not hide later daemon errors.
(
 load_cfg() { AUTOSCALE=false; printf 'visible-daemon-error\n' >&2; }
 reload_secret_files() { :; }
 autoscale_daemon
) > "$tmp/daemon-out" 2> "$tmp/daemon-err"
grep -qx visible-daemon-error "$tmp/daemon-err" || fail 'daemon discarded operational errors'
printf 'queued-pools: durable background cooldown precedes all remote effects; daemon errors stay visible\n'

# Cooldown defers capacity, but startup must establish controllers that retry it.
(
 shared_capacity_require_starts_open() { :; }
 shared_capacity_enabled() { return 0; }
 shared_capacity_poison_scan() { :; }
 restore_warm_capacity() { :; }
 shared_capacity_call() { [ "$1" = rebalance ] || fail 'unexpected startup effect'; return 75; }
 validate_runner_mode() { :; }
 pool_tokens_ready() { :; }
 public_repo_problem() { :; }
 gitlab_assert_no_orphan_manager_configs() { :; }
 managed_names() { :; }
 provision_preflight() { :; }
 gitlab_cleanup_orphan_sidecars() { :; }
 start_stopped_managed() { :; }
 reap_dead_runners() { :; }
 start_configured_capacity() { return 75; }
 current_count() { echo 1; }
 lifecycle_start() { echo lifecycle >> "$tmp/startup"; }
 recommendation_history_start() { echo history >> "$tmp/startup"; }
 autoscale_start() { echo autoscale >> "$tmp/startup"; }
 NETWORK_ISOLATION=off IMAGE_AUTOUPDATE=false
 if cmd_start; then fail 'deferred startup reported healthy capacity'; fi
)
[ "$(cat "$tmp/startup")" = $'lifecycle\nhistory\nautoscale' ] || fail 'cooldown stranded retry controllers'
