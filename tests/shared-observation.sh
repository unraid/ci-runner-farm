#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'SHARED OBSERVATION FAIL: %s\n' "$*" >&2; exit 1; }
touch "$CFGDIR/shared-capacity.enabled"
fixture_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fixture_snapshot="$fixture_id|github|runner|1|generation"
managed_runner_snapshot() { [ "$1" = ci-runner-build-1 ] || return 1; printf '%s' "$fixture_snapshot"; }
timeout() { [ "$1" = 10 ] || fail 'unbounded observation'; shift; "$@"; }
fixture_state='running|false'
fixture_processes=$'PID COMMAND\n10 Runner.Listener\n11 sleep'
inspect_status=0 top_status=0
docker() {
  printf '%s\n' "$*" >> "$tmp/commands"
  case "$1" in
    inspect)
      [ "$4" = "$fixture_id" ] || fail 'state inspected a mutable name'
      printf '%s' "$fixture_state"; return "$inspect_status" ;;
    top)
      [ "$2" = "$fixture_id" ] || fail 'processes sampled a mutable name'
      printf '%s' "$fixture_processes"; return "$top_status" ;;
    *) fail 'shared status spawned an exec or used log fallback' ;;
  esac
}
expect() {
  : > "$tmp/commands"
  [ "$(github_runner_state ci-runner-build-1)" = "$1" ] || fail "$2"
  if grep -qE '^(exec|logs) ' "$tmp/commands"; then fail 'shared observation entered container'; fi
}
expect idle 'sole listener was not idle'
fixture_processes=$'PID COMMAND\n10 Runner.Listener\n12 Runner.Worker'
expect busy 'worker was not protected'
fixture_processes=$'PID COMMAND\n12 Runner.Worker'
expect busy 'worker without listener was not protected'
fixture_processes=$'wrong header\n12 Runner.Worker\ninvalid'
expect busy 'positive worker lost to other malformed evidence'
fixture_state='running|true'
expect paused 'paused owner lost its state'
if grep -q '^top ' "$tmp/commands"; then fail 'paused owner was sampled'; fi
fixture_state='running|false'
for fixture_processes in '' $'PID COMMAND' $'bad header\n10 Runner.Listener' \
  $'PID COMMAND\n0 Runner.Listener' $'PID COMMAND\ninvalid Runner.Listener' \
  $'PID COMMAND\n10 Runner.Listener extra' $'PID COMMAND\n10 sleep' \
  $'PID COMMAND\n10 Runner.Listener\n11 Runner.Listener'; do
  expect starting 'incomplete processes reported idle'
done
fixture_processes=$'PID COMMAND\n10 Runner.Listener'
top_status=1
expect starting 'failed process read reported idle'
top_status=0 inspect_status=1
expect starting 'failed inspection reported idle'
inspect_status=0
for fixture_state in 'created|false' 'exited|false' 'running' 'running|unknown'; do
  expect starting 'unproved live state reported idle'
done
fixture_state='running|false'
for fixture_snapshot in '' "$fixture_id|gitlab|runner|1|generation" "$fixture_id|github|sidecar|1|generation"; do
  expect starting 'unknown ownership reported idle'
  [ ! -s "$tmp/commands" ] || fail 'unknown ownership reached Docker'
done
managed_runner_snapshot() { return 1; }
expect starting 'unavailable ownership reported idle'
[ ! -s "$tmp/commands" ] || fail 'unavailable ownership reached Docker'
echo 'shared-observation: immutable host reads, paused/unknown truth and worker protection passed'
