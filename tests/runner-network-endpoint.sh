#!/usr/bin/env bash
# Exercise dangling runner-network endpoint cleanup on the real creation path without Docker.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'RUNNER NETWORK ENDPOINT FAIL: %s\n' "$*" >&2; exit 1; }
logfile="$tmp/calls"
slot=ci-runner-build-9
live_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export CI_PROVIDER=github CRF_POOL_ID=build NAME_PREFIX=ci-runner-build RUNNER_NETWORK=ci-runner-net
ARGS=(-d --name "$slot" --network ci-runner-net image)
log() { :; }
shared_capacity_require_starts_open() { return 0; }
shared=true
shared_capacity_enabled() { [ "$shared" = true ]; }
shared_capacity_start() { printf 'admission %s %s\n' "$1" "$2" >> "$logfile"; return 75; }
docker() {
  printf 'docker %s\n' "$*" >> "$logfile"
  case "$1" in
    ps) [ "$ps_ok" = true ] && printf '%s\n' "$listed_names" ;;
    network)
      case "$2" in
        inspect) [ "$inspect_ok" = true ] && printf '%s\n' "$listed_endpoints" ;;
        disconnect) [ "$disconnect_ok" = true ] ;;
        *) fail "unexpected network operation: $*" ;;
      esac ;;
    create) printf '%064d\n' 1 ;;
    run) return 0 ;;
    *) fail "unexpected Docker operation: $*" ;;
  esac
}
create() {
  : > "$logfile"
  if run_owned_github_container 9; then return 0; else return "$?"; fi
}
reset() {
  NETWORK_ISOLATION=isolate ps_ok=true inspect_ok=true disconnect_ok=true shared=true
  listed_names=$'ci-runner-build-1\nci-runner-build-10'
  listed_endpoints="$live_id|ci-runner-build-1"$'\n'"ep-0123456789ab|$slot"$'\n'
}

# A dangling endpoint is removed by name, before the fresh container exists.
reset
if create; then fail 'queued create reported running'; else [ "$?" -eq 75 ] || fail 'queued exit lost'; fi
[ "$(grep -n "^docker network disconnect -f ci-runner-net $slot\$" "$logfile" | cut -d: -f1)" = 3 ] \
  || fail 'dangling endpoint was not removed by exact name before creation'
[ "$(sed -n 4p "$logfile")" = 'docker create --no-healthcheck --name ci-runner-build-9 --network ci-runner-net image' ] \
  || fail 'creation did not follow endpoint cleanup'
grep -qx "admission $slot $(printf '%064d' 1)" "$logfile" || fail 'fresh owner skipped admission'

# The legacy run path uses the same guard.
reset; shared=false
create || fail 'legacy run failed'
grep -qx "docker network disconnect -f ci-runner-net $slot" "$logfile" || fail 'legacy run kept the dangling endpoint'
grep -q '^docker run -d ' "$logfile" || fail 'legacy run did not create the slot'

# An endpoint owned by any container, or a held name, is never touched.
for scenario in held-name live-endpoint other-name; do
  reset
  case "$scenario" in
    held-name) listed_names=$'ci-runner-build-1\nci-runner-build-9' ;;
    live-endpoint) listed_endpoints="ep-0123456789ab|$slot"$'\n'"$live_id|$slot" ;;
    other-name) listed_endpoints="ep-0123456789ab|ci-runner-build-90" ;;
  esac
  if create; then :; else [ "$?" -eq 75 ] || fail "$scenario blocked creation"; fi
  if grep -q '^docker network disconnect' "$logfile"; then fail "$scenario removed an endpoint"; fi
  grep -q '^docker create ' "$logfile" || fail "$scenario skipped creation"
done
# Runners on the default bridge keep their existing creation path.
reset; NETWORK_ISOLATION=off
if create; then :; else [ "$?" -eq 75 ] || fail 'isolation off blocked creation'; fi
if grep -qE '^docker (ps|network)' "$logfile"; then fail 'isolation off inspected the runner network'; fi
grep -q '^docker create ' "$logfile" || fail 'isolation off skipped creation'

# Unknown Docker state or a failed removal refuses creation instead of guessing.
for scenario in ps inspect disconnect; do
  reset
  case "$scenario" in
    ps) ps_ok=false ;;
    inspect) inspect_ok=false ;;
    disconnect) disconnect_ok=false ;;
  esac
  if create 2>/dev/null; then fail "$scenario failure created the slot"; else [ "$?" -eq 1 ] || fail "$scenario failure status changed"; fi
  if grep -qE '^docker (create|run)|^admission' "$logfile"; then fail "$scenario failure created the slot"; fi
done
printf 'runner-network-endpoint: dangling endpoints cleared by exact name; live, held and unknown states preserved\n'
