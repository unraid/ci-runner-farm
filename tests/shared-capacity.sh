#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'SHARED CAPACITY FAIL: %s\n' "$*" >&2; exit 1; }
logfile="$tmp/commands"
# The general host has a different provider root from the OS host default.
# A failed policy/plan read must never invoke the provider at that default.
php() { printf '%s' '/mnt/cache/qa-vm-service-infra-01'; }
function /usr/local/sbin/qa-vm-service() { printf 'provider %s\n' "$*" >> "$logfile"; }
shared_capacity_call prepare
grep -qx 'provider --state-root /mnt/cache/qa-vm-service-infra-01 farm-capacity prepare' "$logfile" \
  || fail 'farm helper used the default provider root'
: > "$logfile"
php() { return 1; }
if shared_capacity_call prepare >/dev/null 2>&1; then fail 'unreadable policy/plan invoked provider'; fi
[ ! -s "$logfile" ] || fail 'failed root resolution invoked provider'
unset -f php /usr/local/sbin/qa-vm-service
# Run the actual protected metadata parser in Linux root package checks.
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p "$tmp/provider"
  php() {
    local code="${2//\/boot\/config\/plugins\/qa-vm-service\//$tmp/provider/}"
    command php -r "$code"
  }
  if shared_capacity_enabled; then fail 'missing legacy metadata enabled shared mode'; fi
  printf '%s\n' '{"providerConfig":{"sharedCapacity":{"policy":{}}}}' > "$tmp/provider/host-policy.json"
  chmod 600 "$tmp/provider/host-policy.json"
  shared_capacity_enabled || fail 'durable shared policy ignored without marker'
  printf '%s\n' '{"providerConfig":{"sharedCapacity":null}}' > "$tmp/provider/host-policy.json"
  if shared_capacity_enabled; then fail 'null legacy policy enabled shared mode'; fi
  printf '%s\n' '{"sharedAdmission":{"elastic":true}}' > "$tmp/provider/runner-integration.json"
  chmod 600 "$tmp/provider/runner-integration.json"
  shared_capacity_enabled || fail 'durable shared integration ignored without marker'
  printf '%s\n' '{broken' > "$tmp/provider/runner-integration.json"
  shared_capacity_enabled || fail 'malformed integration allowed legacy fallback'
  rm "$tmp/provider/runner-integration.json"
  ln -s "$tmp/missing" "$tmp/provider/runner-integration.json"
  shared_capacity_enabled || fail 'broken integration symlink allowed legacy fallback'
  unset -f php
fi
# Legacy test fixtures have no protected provider configuration.
php() { return 1; }
docker_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
decision=75
docker() {
  printf 'docker %s\n' "$*" >> "$logfile"
  case "$1" in create) printf '%s\n' "$docker_id" ;; run|start) return 0 ;; *) return 1 ;; esac
}
shared_capacity_call() { printf 'gate %s\n' "$*" >> "$logfile"; return "$decision"; }
ARGS=(-d --name ci-runner-build-1 --memory 12g --cpus 1 --env-file "$tmp/token" image)
CI_PROVIDER=github CRF_POOL_ID=build NAME_PREFIX=ci-runner-build
touch "$CFGDIR/shared-capacity.enabled"
if run_owned_github_container 1; then fail 'queued start reported running'; else [ "$?" -eq 75 ] || fail 'queue exit status lost'; fi
grep -qF "gate start ci-runner-build-1 $docker_id" "$logfile" || fail 'immutable create did not reach gate'
if grep -qE '^docker (run|start)' "$logfile"; then fail 'queued create bypassed admission'; fi
grep -qF -- '--memory 12g --cpus 1 --env-file' "$logfile" || fail 'hard limits or private credential file changed'
if grep -qF 'create -d' "$logfile"; then fail 'detached run flag reached create'; fi

# An expired inert token must use the supported refresh before a fresh create.
shared_capacity_call() {
 printf 'gate %s\n' "$*" >> "$logfile"
 case "$1" in start) return 76 ;; refresh-queued) return 0 ;; *) return 1 ;; esac
}
github_start_one() { printf 'fresh-create %s %s\n' "$1" "$2" >> "$logfile"; return 75; }
: > "$logfile"
if shared_capacity_start ci-runner-build-1 "$docker_id"; then fail 'fresh queued owner reported running'; else [ "$?" -eq 75 ] || fail 'refreshed queue exit lost'; fi
grep -qF "gate refresh-queued ci-runner-build-1 $docker_id" "$logfile" || fail 'expired credential bypassed inert owner proof'
grep -qF 'fresh-create 1 ci-runner-build-1' "$logfile" || fail 'expired credential did not mint a fresh container'
shared_capacity_call() { printf 'gate %s\n' "$*" >> "$logfile"; return "$decision"; }

shared_capacity_build_limits() { printf '%s' '4|8|12288|1'; }
RUNNER_MODE=pools RUNNER_POOLS='v3|build|general-build|unraid,build|4|4|8|0|1|12g|builtin'
GH_SCOPE=org AUTOSCALE=true IMAGE_AUTOUPDATE=false
validate_runner_mode || fail 'shared named pool rejected autoscale'
pool_base_refresh
start_one() { printf 'slot %s\n' "$1" >> "$logfile"; return 75; }
provider_remote_image_host_pull_required() { return 1; }
GH_REPOS=unraid/core
provider_build_poison_scan() {
  [ "$NAME_PREFIX" = ci-runner-build ] || fail 'poison scan lost named owner scope'
  [ "$GH_REPOS" = unraid/core ] || fail 'poison scan lost repository scope'
  printf 'poison-scan\n' >> "$logfile"
}
: > "$logfile"
autoscale_tick || fail 'queued slots failed whole fleet'
[ "$(grep -c '^slot ' "$logfile")" -eq 8 ] || fail 'shared tick did not retry all eight stable slots'
grep -qx 'poison-scan' "$logfile" || fail 'shared tick bypassed poison detection'
grep -qx 'gate rebalance' "$logfile" || fail 'shared tick did not evaluate priority pressure'
RUNNER_POOLS="$RUNNER_POOLS;v3|extra|extra-label||1|0|1|0|1|12g|builtin"
if validate_runner_mode >/dev/null 2>&1; then fail 'unbudgeted extra pool accepted'; fi
RUNNER_MODE=single
if validate_runner_mode >/dev/null 2>&1; then fail 'legacy mode bypassed shared owner gate'; fi
rm "$CFGDIR/shared-capacity.enabled"
# Durable shared metadata keeps releases fenced after marker removal.
php() { return 0; }
decision=0
: > "$logfile"
shared_capacity_prepare_release ci-runner-build-1 "$docker_id"
shared_capacity_release ci-runner-build-1 "$docker_id"
grep -qF "gate prepare-release ci-runner-build-1 $docker_id" "$logfile" || fail 'marker removal skipped release preparation'
grep -qF "gate release ci-runner-build-1 $docker_id" "$logfile" || fail 'marker removal skipped fenced release'
: > "$logfile"
run_owned_github_container 1
if grep -qE '^docker (run|start)' "$logfile"; then fail 'marker removal bypassed durable admission'; fi
# Corrupt metadata also retains the gate; only positive legacy status bypasses.
php() { return 2; }
shared_capacity_enabled || fail 'unknown metadata disabled shared admission'
php() { return 1; }
shared_capacity_enabled && fail 'positive legacy metadata enabled shared admission'
: > "$logfile"
run_owned_github_container 1
grep -q '^docker run -d ' "$logfile" || fail 'legacy run compatibility changed'
# Closure applies even before activation, and must precede any Docker effect.
cmd_admission_close
: > "$logfile"
if run_owned_github_container 1; then fail 'legacy start bypassed adoption closure'; fi
if start_owned_container ci-runner-build-1 "$docker_id"; then fail 'recovery start bypassed adoption closure'; fi
[ ! -s "$logfile" ] || fail 'closure performed a Docker effect'
rm "$CFGDIR/shared-capacity.closed"
ln -s "$tmp/missing" "$CFGDIR/shared-capacity.closed"
if shared_capacity_require_starts_open; then fail 'broken closure marker allowed start'; fi
rm "$CFGDIR/shared-capacity.closed"
printf 'shared-capacity: native admission, queued retries, closure and mode restrictions passed\n'
# Size classes reuse named routing and one aggregate eight-slot admission pool.
touch "$CFGDIR/shared-capacity.enabled"
RUNNER_MODE=pools RUNNER_POOLS='v3|build|general-build|unraid,build|4|4|4|0|1|12g|builtin;v3|build-small|build-small||1|0|2|0|1|4g|builtin;v3|build-large|build-large||1|0|2|0|4|16g|builtin'
validate_runner_mode || fail 'bounded build size classes rejected'
pool_activate build-large || fail 'large build class lost routing'
[ "$RUNNER_MEMORY" = 16g ] && [ "$RUNNER_CPUS" = 4 ] && [ "$RUNNER_LABELS" = build-large ] || fail 'size class limits or routing differ'
shared_capacity_start ci-runner-build-large-1 "$docker_id" || [ "$?" -eq 75 ] || fail 'class bypassed or failed native admission'

for invalid in \
 'v3|build|general-build|unraid,build|4|4|8|0|1|12g|builtin;v3|build-large|build-large||1|0|1|0|4|16g|builtin' \
 'v3|build|general-build|unraid,build|4|4|4|0|1|12g|builtin;v3|build-large|build-large||1|1|2|0|4|16g|builtin' \
 'v3|build|general-build|unraid,build|4|4|4|0|1|12g|builtin;v3|other|other||1|0|2|0|1|4g|builtin' \
 'v3|build|general-build|unraid,build|4|4|4|0|1|12g|builtin;v3|build-small|build-small||1|0|2|0|0.5|4g|builtin'; do
 RUNNER_POOLS="$invalid"
 if validate_runner_mode >/dev/null 2>&1; then fail 'invalid aggregate classes accepted'; fi
done
printf 'shared-capacity: variable build classes preserve routing, hard limits, four-builder floor and aggregate eight-slot bound\n'

RUNNER_POOLS='v3|build|general-build|unraid,build,build-large|4|4|4|0|1|12g|builtin;v3|build-large|build-large||1|0|2|0|4|16g|builtin'
if validate_runner_mode >/dev/null 2>&1; then fail 'default runner advertised large-class routing'; fi
RUNNER_POOLS='v3|build|general-build|unraid,build|4|4|4|0|1|12g|builtin;v3|build-small|build-small|unraid,build|1|0|2|0|1|4g|builtin'
if validate_runner_mode >/dev/null 2>&1; then fail 'small runner advertised default build routing'; fi

RUNNER_POOLS='v3|build|general-build|unraid,build|4|4|4|0|1|12g|builtin;v3|build-small|build-small|unraid|1|0|2|0|1|4g|builtin'
if validate_runner_mode >/dev/null 2>&1; then fail 'size class advertised generic default-job routing'; fi

# A 64 GiB build-only host uses its reviewed floor and a smaller aggregate cap.
shared_capacity_build_limits() { printf '%s' '1|3|12288|4'; }
RUNNER_POOLS='v3|build|general-build|unraid,build|1|1|2|0|4|12g|builtin;v3|build-large|build-large||1|0|1|0|4|16g|builtin'
validate_runner_mode || fail 'host-specific floor and maximum rejected'
RUNNER_POOLS="${RUNNER_POOLS/|1|1|2|/|2|2|2|}"
if validate_runner_mode; then fail 'farm floor drift accepted'; fi
RUNNER_POOLS='v3|build|general-build|unraid,build|1|1|3|0|4|12g|builtin;v3|build-large|build-large||1|0|1|0|4|16g|builtin'
if validate_runner_mode; then fail 'host-specific aggregate cap exceeded'; fi
RUNNER_POOLS='v3|build|general-build|unraid,build|1|1|2|0|4|16g|builtin'
if validate_runner_mode; then fail 'default hard limits drift accepted'; fi
shared_capacity_build_limits() { return 1; }
if validate_runner_mode; then fail 'untrusted host contract accepted'; fi
printf 'shared-capacity: host-specific floor, maximum and default hard limits fail closed on drift\n'
