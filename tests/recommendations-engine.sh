#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp tests/fixtures/recommendations-usage.cache "$tmp/usage.cache"

json="$(CRF_SOURCE_ONLY=1 bash -c '
  source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
  RUNDIR="$1"
  HISTORY_FILE="$1/history"
  RUNNER_MODE=single
  managed_names() { printf "ci-runner-1\\n"; }
  crf_history_record_event github "Build Fedora Core artifact" 2100 "$(( $(date +%s) - 3 ))"
  crf_history_record_event github "Build Fedora Core artifact" 2400 "$(( $(date +%s) - 2 ))"
  crf_history_record_event github "Build Fedora Core artifact" 2700 "$(( $(date +%s) - 1 ))"
  cmd_recommendations_json
' bash "$tmp")"

JSON="$json" python3 - <<'PY'
import json
import os

body = json.loads(os.environ["JSON"])
assert body["confidence"] == "medium"
assert body["jobs"][0]["class"] == "heavy"
assert body["jobs"][0]["score"] == 5
assert body["jobs"][0]["target_pool"] == "default"
assert body["recommendations"][0]["kind"] == "placement"
assert body["source"] == "live-historical"
assert body["history"]["samples"] == 3
assert body["jobs"][0]["history"]["samples"] == 3
assert body["jobs"][0]["history"]["p95_seconds"] == 3600
assert "historical P95" in body["jobs"][0]["reason"]
PY

echo "recommendations-engine: OK"
