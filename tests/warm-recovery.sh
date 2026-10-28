#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'WARM RECOVERY FAIL: %s\n' "$*" >&2; exit 1; }
CI_PROVIDER=github GH_SCOPE=org RUNNER_MODE=pools AUTOSCALE=true ELASTIC_POOLS=true QUEUED_POOLS=true
RUNNER_POOLS='v3|build|general-build|self-hosted,linux,x64|24|4|24|10|4|12g|builtin;v3|build-small|build-small|self-hosted,linux,x64|1|0|10|1|2|4g|builtin'
pool_base_refresh
mode=denied
php() {
 case "$2" in
 warm-targets) printf 'warm-targets\n' >> "$tmp/order"; printf '{}';;
 scan) printf 'scan\n' >> "$tmp/order"; return 1;;
 *) fail 'queue failure reached a queue-driven effect';;
 esac
}
shared_capacity_call() {
 [ "$1" = demand-warm ] || fail 'unexpected native effect'
 printf 'warm-plan\n' >> "$tmp/order"
 [ "$mode" != unknown ] || return 1
 printf 'build|2\nbuild-small|1\n'
}
start_one() { printf '%s\n' "$NAME_PREFIX-$1" >> "$tmp/starts"; }
if start_configured_capacity; then fail 'queue denial reported as complete evidence'; fi
[ "$(cat "$tmp/starts" 2>/dev/null)" = $'ci-runner-build-2\nci-runner-build-small-1' ] || fail 'queue denial blocked warm recovery'
[ "$(cat "$tmp/order")" = $'warm-targets\nwarm-plan\nscan' ] || fail 'warm recovery depends on network scan'
rm "$tmp/starts" "$tmp/order"
mode=unknown
if start_configured_capacity; then fail 'unknown warm native outcome accepted'; fi
[ ! -e "$tmp/starts" ] || fail 'unknown warm outcome started a container'
! grep -q scan "$tmp/order" || fail 'unknown native outcome fell back to queue effects'
printf 'warm-recovery: denied queue preserves additive recovery; unknown native outcomes fail closed\n'

# A failed warm start must not prevent the existing owner from settling grants.
# After settlement, retry through the same native warm/admission path.
for failure in transient persistent; do
 (
  rm -f "$tmp/settled" "$tmp/recovery-order" "$tmp/recovery-starts"
  crf_storage_pressure_cleanup() { :; }
  validate_runner_mode() { :; }
  shared_capacity_poison_scan() { :; }
  php() {
   case "$2" in
    begin-recovery|begin|warm-targets|scan|targets) printf '{}';;
    *) fail 'unexpected recovery planning action';;
   esac
  }
  shared_capacity_call() {
   printf '%s\n' "$1" >> "$tmp/recovery-order"
   case "$1" in
    demand-warm)
     [ "$failure" != persistent ] && [ -e "$tmp/settled" ] || return 1
     printf 'build|2\n';;
    rebalance) touch "$tmp/settled";;
    demand-observe) printf '{}';;
    demand-apply) :;;
    *) fail 'recovery bypassed the native controller';;
   esac
  }
  start_one() {
   [ -e "$tmp/settled" ] || fail 'start preceded owner settlement'
   printf '%s\n' "$NAME_PREFIX-$1" >> "$tmp/recovery-starts"
  }
  if autoscale_tick; then
   [ "$failure" = transient ] || fail 'persistent warm failure reported success'
  else
   [ "$failure" = persistent ] || fail 'settlement could not repair transient warm failure'
  fi
  [ -e "$tmp/settled" ] || fail 'warm failure stranded stale grants'
  if [ "$failure" = transient ]; then
   [ "$(cat "$tmp/recovery-order")" = $'demand-warm\nrebalance\ndemand-warm\ndemand-warm\ndemand-observe\ndemand-apply' ] || fail 'recovery did not settle then retry gated planning'
   [ "$(cat "$tmp/recovery-starts")" = $'ci-runner-build-2\nci-runner-build-2' ] || fail 'recovery did not retry only the native selected slot'
  else
   [ "$(cat "$tmp/recovery-order")" = $'demand-warm\nrebalance\ndemand-warm' ] || fail 'persistent failure reached burst planning'
   [ ! -e "$tmp/recovery-starts" ] || fail 'persistent failure bypassed native warm planning'
  fi
 )
done
printf 'warm-recovery: failed warm restoration still settles owners before a gated retry\n'
