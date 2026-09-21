#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" bash -c '
  set -euo pipefail
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  CFGDIR="$CRF_CFGDIR"
  RUNDIR="$CRF_RUNDIR"
  HISTORY_FILE="$CRF_CFGDIR/history"
  source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-history.sh

  now="$(date +%s)"
  crf_history_record_event github "Build Fedora Core artifact" 120 "$((now - 3))"
  crf_history_record_event github "Build Fedora Core artifact" 210 "$((now - 2))"
  crf_history_record_event github "Build Fedora Core artifact" 240 "$((now - 1))"
  stats="$(crf_history_stats github "Build Fedora Core artifact")"
  IFS="|" read -r _ count p95 average min max _ <<< "$stats"
  [ "$count" = 3 ]
  [ "$p95" = 300 ]
  [ "$average" = 190 ]
  [ "$min" = 120 ]
  [ "$max" = 240 ]

  b64() { printf "%s" "$1" | base64 | tr -d "\\n"; }
  start="$((now - 90))"
  job64="$(b64 "JS lint")"
  previous="ci-runner-1 20 300 busy $job64 $start github repo 101 _ _ _ _ _ _ _ _"
  current="ci-runner-1 20 300 idle _ _ github _ _ _ _ _ _ _ _ _ _"
  crf_history_record_snapshot "$previous" "$current" "$now"
  snapshot_stats="$(crf_history_stats github "JS lint")"
  IFS="|" read -r _ snapshot_count _ _ _ _ _ <<< "$snapshot_stats"
  [ "$snapshot_count" = 1 ]

  # GitHub run IDs are shared by matrix jobs; a changed job name/start marks a
  # completion even when the run ID is unchanged.
  next_job64="$(b64 "Build Fedora Core artifact")"
  current_matrix="ci-runner-1 20 300 busy $next_job64 $((now - 1)) github repo 101 _ _ _ _ _ _ _ _"
  crf_history_record_snapshot "$previous" "$current_matrix" "$now"
  snapshot_stats="$(crf_history_stats github "JS lint")"
  IFS="|" read -r _ snapshot_count _ _ _ _ _ <<< "$snapshot_stats"
  [ "$snapshot_count" = 2 ]

  # The same busy job observed twice is not a completion.
  current_busy="ci-runner-1 20 300 busy $job64 $start github repo 101 _ _ _ _ _ _ _ _"
  crf_history_record_snapshot "$previous" "$current_busy" "$now"
  snapshot_stats="$(crf_history_stats github "JS lint")"
  IFS="|" read -r _ snapshot_count _ _ _ _ _ <<< "$snapshot_stats"
  [ "$snapshot_count" = 2 ]
  echo "runner-history: OK"
' bash
