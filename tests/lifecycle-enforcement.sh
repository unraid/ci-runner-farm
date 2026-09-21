#!/usr/bin/env bash
# Verify idle GitHub DinD cleanup, confirmation, PID pressure, and recycle flow.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'LIFECYCLE ENFORCEMENT FAIL: %s\n' "$*" >&2; exit 1; }

CI_PROVIDER=github
DIND=true
LIFECYCLE_CONFIRMATIONS=2
LIFECYCLE_PID_PRESSURE_PERCENT=75
RUNNER_PHASE=idle
CLEAN_RESULT=0
PID_CURRENT=100

managed_names() { printf 'ci-runner-1\n'; }
managed_runner_snapshot() { printf '%064d|github|runner|1|test-generation\n' 1; }
runner_state() { printf '%s\n' "$RUNNER_PHASE"; }

# Lifecycle code uses timeout around Docker calls. Function keeps test mocks in
# the current shell, where provider functions can observe exact command shape.
timeout() { shift; "$@"; }
docker() {
  case "${1:-}" in
    exec)
      if printf '%s' "$*" | grep -q 'echo busy'; then
        printf '%s\n' "$RUNNER_PHASE"
        return 0
      fi
      if printf '%s' "$*" | grep -q 'pids.current'; then
        printf '%s\n' "$PID_CURRENT"
        return 0
      fi
      return "$CLEAN_RESULT"
      ;;
    inspect)
      printf '4096\n'
      ;;
    logs)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

marker="$CRF_RUNDIR/github-lifecycle.ci-runner-1"
rm -f "$marker"
[ -z "$(github_lifecycle_candidate 2>/dev/null)" ] || fail "clean runner became candidate"

CLEAN_RESULT=1
[ -z "$(github_lifecycle_candidate 2>/dev/null)" ] || fail "first failed check recycled runner"
[ "$(github_lifecycle_candidate 2>/dev/null)" = ci-runner-1 ] \
  || fail "second failed check did not select runner"

RUNNER_PHASE=busy
[ -z "$(github_lifecycle_candidate 2>/dev/null)" ] || fail "busy runner became candidate"
RUNNER_PHASE=idle

CLEAN_RESULT=0
PID_CURRENT=3900
rm -f "$marker"
[ -z "$(github_lifecycle_candidate 2>/dev/null)" ] || fail "first PID pressure check recycled runner"
[ "$(github_lifecycle_candidate 2>/dev/null)" = ci-runner-1 ] \
  || fail "second PID pressure check did not select runner"

CLEAN_RESULT=1
PID_CURRENT=100
rm -f "$marker"
recycle_log="$tmp/recycle.log"
cmd_recycle() { printf '%s\n' "$1" >> "$recycle_log"; }
lifecycle_tick || fail "first lifecycle tick failed"
[ ! -s "$recycle_log" ] || fail "first lifecycle tick recycled runner"
lifecycle_tick || fail "second lifecycle tick failed"
[ "$(cat "$recycle_log")" = ci-runner-1 ] || fail "lifecycle tick did not recycle selected runner"

DIND=false
rm -f "$marker"
[ -z "$(github_lifecycle_candidate)" ] || fail "non-DinD runner became candidate"

echo 'lifecycle-enforcement: OK — idle DinD cleanup confirms before recycle'
