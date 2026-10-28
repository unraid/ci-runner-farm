#!/usr/bin/env bash
# Shared config updates use fenced native withdrawal, never a stale idle snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'shared-config-reconcile: %s\n' "$*" >&2; exit 1; }
touch "$CFGDIR/host-capacity.json"
reload_locked_snapshot() { :; }
managed_names() { printf '%s\n' ci-runner-build-{1,2,3,4}; }
managed_runner_snapshot() {
 local index=${1##*-} generation=old
 [ "$index" != 1 ] || generation=current
 printf '%064d|github|runner|%s|%s\n' "$index" "$index" "$generation"
}
expected_runner_confgen() { printf '%s' current; }
runner_state() { if [ "${1##*-}" = 2 ]; then printf busy; else printf idle; fi; }
shared_capacity_call() {
 [ "$1" = reconcile-idle ] || fail 'unexpected native action'
 printf '%s\n' "$*" >> "$tmp/effects"
 return "${decision:-75}"
}
: > "$tmp/effects"
runner_pool() { printf build; }
cmd_recycle() { fail 'shared configuration bypassed native withdrawal'; }
reconcile_stale_runners || fail 'healthy native waiting was treated as failure'
[ "$(wc -l < "$tmp/effects" | tr -d ' ')" = 1 ] || fail 'more than one stale owner was selected'
grep -q '^reconcile-idle ci-runner-build-3 ' "$tmp/effects" || fail 'current or busy owner was selected'
: > "$tmp/effects"
decision=1
if reconcile_stale_runners; then fail 'unknown native outcome was accepted'; fi
[ "$(wc -l < "$tmp/effects" | tr -d ' ')" = 1 ] || fail 'unknown outcome drained another slot'
: > "$tmp/effects"
touch "$CFGDIR/shared-capacity.closed"
reconcile_stale_runners
[ ! -s "$tmp/effects" ] || fail 'closed admission reached native mutation'
rm "$CFGDIR/shared-capacity.closed" "$CFGDIR/host-capacity.json"
shared_capacity_enabled() { return 0; }
reconcile_stale_runners
[ ! -s "$tmp/effects" ] || fail 'legacy shared owner reached unsupported native command'
printf 'shared-config-reconcile: PASS\n'

# A cached queue cooldown must not suppress independent native maintenance.
: > "$tmp/order"
touch "$CFGDIR/host-capacity.json"
AUTOSCALE=true QUEUED_POOLS=true RUNNER_POOLS='v3|build|general-build|custom|24|4|24|10|4|12g|builtin'
crf_storage_pressure_cleanup() { :; }
pool_mode_enabled() { return 0; }
validate_runner_mode() { :; }
pool_activate() { :; }
restore_warm_capacity() { printf 'warm\n' >> "$tmp/order"; }
shared_capacity_call() { [ "$1" = rebalance ] || fail 'unexpected native recovery'; printf 'rebalance\n' >> "$tmp/order"; }
reconcile_stale_runners() { printf 'reconcile\n' >> "$tmp/order"; }
php() {
 case "$2" in
  begin-recovery) printf 'recovery\n' >> "$tmp/order" ;;
  begin) printf 'cooldown\n' >> "$tmp/order"; return 75 ;;
  *) fail 'maintenance performed a queue scan' ;;
 esac
}
if autoscale_tick; then fail 'queue cooldown disappeared'; else [ "$?" -eq 75 ] || fail 'queue cooldown changed'; fi
[ "$(cat "$tmp/order")" = $'recovery\nwarm\nrebalance\nwarm\nreconcile\nwarm\ncooldown' ] || fail 'native maintenance was coupled to queue freshness'
printf 'shared-config-reconcile: native recovery precedes queue cooldown\n'

# Fixed native fleets use the same five-minute recovery gate, never lifecycle
# frequency or a general queue scan. Autoscaled fleets have their own tick.
: > "$tmp/order"
AUTOSCALE=false QUEUED_POOLS=false
start_configured_capacity() { printf 'fixed\n' >> "$tmp/order"; }
replenish_fixed_native_capacity
[ "$(cat "$tmp/order")" = $'recovery\nrebalance\nreconcile\nfixed' ] || fail 'fixed native maintenance did not restore its saved capacity'
: > "$tmp/order"
php() { [ "$2" = begin-recovery ] || fail 'fixed maintenance scanned queue'; return 75; }
replenish_fixed_native_capacity
[ ! -s "$tmp/order" ] || fail 'fixed maintenance ignored durable cooldown'
AUTOSCALE=true
php() { fail 'autoscaled fleet performed duplicate lifecycle recovery'; }
replenish_fixed_native_capacity
rm "$CFGDIR/host-capacity.json"
AUTOSCALE=false
replenish_fixed_native_capacity
printf 'shared-config-reconcile: fixed native cadence and legacy isolation PASS\n'
