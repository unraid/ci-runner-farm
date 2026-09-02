#!/usr/bin/env bash
# Verify that a locally healthy GitHub runner is recycled after GitHub reports
# it offline, while API failures and busy runners remain non-destructive.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source "$ENGINE"

ACCESS_TOKEN='github-test-token'
CI_PROVIDER=github
GH_SCOPE=org
GH_OWNER=example-owner
host() { printf 'mockhost\n'; }
runner_busy() { return 1; }

api_log="$tmp/api.log"
: > "$api_log"
gh_api() {
  printf '%s %s\n' "$1" "$2" >> "$api_log"
  case "$1 $2" in
    'GET /orgs/example-owner/actions/runners?per_page=100')
      printf '%s\n' '{"total_count":2,"runners":[{"id":1,"name":"mockhost-ci-runner-1","os":"Linux","status":"offline","busy":false},{"id":2,"name":"mockhost-ci-runner-2","os":"Linux","status":"online","busy":false}]}'
      ;;
    *) return 1 ;;
  esac
}

github_runner_liveness_refresh || { echo 'github-liveness: refresh failed' >&2; exit 1; }
[ "$(wc -l < "$api_log" | tr -d ' ')" = 1 ] || { echo 'github-liveness: expected one inventory request' >&2; exit 1; }
[ "$(github_runner_liveness_status ci-runner-1)" = offline ] || { echo 'github-liveness: offline status was not read' >&2; exit 1; }
[ "$(github_runner_liveness_status ci-runner-2)" = online ] || { echo 'github-liveness: online status was not read' >&2; exit 1; }
[ "$(wc -l < "$api_log" | tr -d ' ')" = 1 ] || { echo 'github-liveness: fresh cache was not reused' >&2; exit 1; }

cache_key="$(printf '%s\0' "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" | sha256sum | cut -c1-12)"
now="$(date +%s)"
printf '%s %s\n' "$((now - GITHUB_LIVENESS_TTL + 1))" "$cache_key" > "$GITHUB_LIVENESS_CACHE"
github_runner_liveness_refresh || { echo 'github-liveness: cache expired too early' >&2; exit 1; }
[ "$(wc -l < "$api_log" | tr -d ' ')" = 1 ] || { echo 'github-liveness: cache did not remain valid for five minutes' >&2; exit 1; }
printf '%s %s\n' "$((now - GITHUB_LIVENESS_TTL - 1))" "$cache_key" > "$GITHUB_LIVENESS_CACHE"
github_runner_liveness_refresh || { echo 'github-liveness: expired cache was not refreshed' >&2; exit 1; }
[ "$(wc -l < "$api_log" | tr -d ' ')" = 2 ] || { echo 'github-liveness: expired cache refresh was not requested' >&2; exit 1; }

if github_offline_runner_confirmed ci-runner-1; then
  echo 'github-liveness: recycled an offline runner after one reading' >&2
  exit 1
fi
github_offline_runner_confirmed ci-runner-1 || { echo 'github-liveness: did not confirm two offline readings' >&2; exit 1; }

runner_busy() { return 0; }
rm -f "$RUNDIR/github-offline.ci-runner-1"
if github_offline_runner_confirmed ci-runner-1; then
  echo 'github-liveness: recycled a busy offline runner' >&2
  exit 1
fi

runner_busy() { return 1; }
rm -f "$GITHUB_LIVENESS_CACHE" "$RUNDIR/github-offline.ci-runner-1"
managed_names() { printf 'ci-runner-1\n'; }
managed_runner_snapshot() { printf '%064d|github|runner|1|test-generation\n' 1; }
docker() {
  case "$1" in
    inspect)
      case "$*" in
        *State.Status*) printf 'running\n' ;;
        *State.Health*) printf 'healthy\n' ;;
      esac
      ;;
  esac
}
removed=0
remove_runner() { removed=$((removed + 1)); }
reap_dead_runners || { echo 'github-liveness: reaper failed' >&2; exit 1; }
[ "$removed" = 0 ] || { echo 'github-liveness: reaper acted after one offline reading' >&2; exit 1; }
reap_dead_runners || { echo 'github-liveness: reaper failed on confirmation' >&2; exit 1; }
[ "$removed" = 1 ] || { echo 'github-liveness: reaper did not replace confirmed offline runner' >&2; exit 1; }

rm -f "$GITHUB_LIVENESS_CACHE"
gh_api() { return 1; }
if github_runner_liveness_refresh; then
  echo 'github-liveness: treated an API failure as a valid inventory' >&2
  exit 1
fi

echo 'github-liveness: PASS'
