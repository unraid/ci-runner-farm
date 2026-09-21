#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config"
export CRF_RUNDIR="$tmp/run"
export CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"

# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'recommendation-boundaries: FAIL: %s\n' "$*" >&2; exit 1; }

# The production host is Linux, but focused tests also run on macOS.
stat() {
  if [ "${1:-}" = -c ] && [ "${2:-}" = %Y ]; then
    if [ "${STAT_STALE_QUEUE:-0}" = 1 ] && [ "${3:-}" = "$CRF_RUNDIR/queued.cache" ]; then
      printf '1\n'
      return 0
    fi
    command stat -c %Y "$3" 2>/dev/null || command stat -f %m "$3"
  else
    command stat "$@"
  fi
}

write_usage() {
  local phase="$1" job="${2:-}" started="${3:-_}"
  printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
    ci-runner-1 20 512 "$phase" "$(_b64 "$job")" "$started" github _ _ _ _ _ _ _ _ _ \
    > "$CRF_RUNDIR/usage.cache"
  touch "$CRF_RUNDIR/usage.cache"
}

write_queue() {
  printf 'github %s %s\n' "$(date +%s)" "$1" > "$CRF_RUNDIR/queued.cache"
  touch "$CRF_RUNDIR/queued.cache"
}

assert_case() {
  local body="$1" name="$2"
  JSON="$body" CASE="$name" python3 - <<'PY'
import json
import os

body = json.loads(os.environ["JSON"])
case = os.environ["CASE"]
recs = body["recommendations"]

if case == "routing":
    assert body["queue"]["count"] == 2
    assert recs[0]["priority"] == "high" and recs[0]["kind"] == "routing"
elif case == "capacity":
    assert body["queue"]["count"] == 2
    assert recs[0]["priority"] == "high" and recs[0]["kind"] == "capacity"
elif case == "telemetry":
    assert body["queue"]["count"] == 2
    assert recs[0]["priority"] == "medium" and recs[0]["kind"] == "telemetry"
elif case == "stale-queue":
    assert body["queue"]["count"] == -1
    assert recs == []
elif case == "empty":
    assert body["confidence"] == "low"
    assert body["jobs"] == [] and recs == []
elif case == "unassigned":
    assert body["jobs"][0]["target_pool"] == "unassigned"
    assert any(r["kind"] == "placement" and "general fleet" in r["message"] for r in recs)
else:
    raise AssertionError(case)
PY
}

# Queue pressure with idle capacity means routing is suspect.
write_usage idle
write_queue 2
assert_case "$(cmd_recommendations_json)" routing

# Queue pressure with no idle capacity means capacity is suspect.
write_usage busy 'Build Fedora Core artifact'
write_queue 2
assert_case "$(cmd_recommendations_json)" capacity

# Queue pressure without fresh usage must not trigger a capacity recommendation.
rm -f "$CRF_RUNDIR/usage.cache"
write_queue 2
assert_case "$(cmd_recommendations_json)" telemetry

# Old queue data must not create a current alarm.
write_usage idle
printf 'github 1 2\n' > "$CRF_RUNDIR/queued.cache"
assert_case "$(cmd_recommendations_json)" stale-queue

# Empty live usage returns a low-confidence, no-active-job response.
rm -f "$CRF_RUNDIR/usage.cache" "$CRF_RUNDIR/queued.cache"
assert_case "$(cmd_recommendations_json)" empty

# A heavy job with no matching pool must produce an explicit unassigned warning.
RUNNER_MODE=pools
pool_records() { printf 'v3|small|small|linux,x64|2|0|2|0|1|2g|builtin\n'; }
pool_effective_labels() { printf 'small,linux,x64\n'; }
write_usage busy 'Build Fedora Core artifact'
assert_case "$(cmd_recommendations_json)" unassigned

# Historical P95 is gated until three completed samples exist.
IFS='|' read -r class score _ < <(crf_recommendation_weight 'JS lint' 20 300 0 7200 2)
[ "$class" = light ] && [ "$score" = 1 ] || fail 'two historical samples changed recommendation'
IFS='|' read -r class score _ < <(crf_recommendation_weight 'JS lint' 20 300 0 7200 3)
[ "$class" = standard ] && [ "$score" = 3 ] || fail 'three historical samples did not raise recommendation'

echo "recommendation-boundaries: OK"
