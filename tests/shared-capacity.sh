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
