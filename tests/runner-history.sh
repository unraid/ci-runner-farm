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

  # An unchanged provider/run ID with incomplete current context is still the
  # same live job. Do not record a false completion while telemetry fills in.
  current_incomplete="ci-runner-1 20 300 busy _ _ github repo 101 _ _ _ _ _ _ _ _"
  crf_history_record_snapshot "$previous" "$current_incomplete" "$now"
  snapshot_stats="$(crf_history_stats github "JS lint")"
  IFS="|" read -r _ snapshot_count _ _ _ _ _ <<< "$snapshot_stats"
  [ "$snapshot_count" = 2 ]

  # The same busy job observed twice is not a completion.
  current_busy="ci-runner-1 20 300 busy $job64 $start github repo 101 _ _ _ _ _ _ _ _"
  crf_history_record_snapshot "$previous" "$current_busy" "$now"
  snapshot_stats="$(crf_history_stats github "JS lint")"
  IFS="|" read -r _ snapshot_count _ _ _ _ _ <<< "$snapshot_stats"
  [ "$snapshot_count" = 2 ]

  # A disappearing runner, incomplete job context, and an invalid duration must
  # not create a false completion.
  disappeared="ci-runner-1 20 300 busy $job64 $start github repo 101 _ _ _ _ _ _ _ _"
  crf_history_record_snapshot "$disappeared" "ci-runner-2 20 300 idle _ _ github _ _ _ _ _ _ _ _ _" "$now"
  incomplete="ci-runner-1 20 300 busy _ $start github repo 101 _ _ _ _ _ _ _ _"
  crf_history_record_snapshot "$incomplete" "$current" "$now"
  crf_history_record_event github "invalid-zero" 0 "$now"
  crf_history_record_event github "invalid-too-long" 604801 "$now"
  [ "$(crf_history_stats github "invalid-zero" | cut -d"|" -f2)" = 0 ]
  [ "$(crf_history_stats github "invalid-too-long" | cut -d"|" -f2)" = 0 ]

  # Provider remains part of the aggregate identity, and GitLab uses the same
  # provider-neutral snapshot contract.
  gitlab_job64="$(b64 "GitLab package")"
  gitlab_previous="ci-runner-2 20 300 busy $gitlab_job64 $start gitlab group/project 42 _ _ _ _ _ _ _"
  gitlab_current="ci-runner-2 20 300 idle _ _ gitlab _ _ _ _ _ _ _ _ _ _"
  crf_history_record_snapshot "$gitlab_previous" "$gitlab_current" "$now"
  [ "$(crf_history_stats gitlab "GitLab package" | cut -d"|" -f2)" = 1 ]

  # Retention removes old aggregates when the next event is written.
  CRF_HISTORY_RETENTION_SECONDS=100
  old_epoch="$((now - 101))"
  crf_history_record_event github "old-family" 30 "$old_epoch"
  [ "$(crf_history_stats github "old-family" | cut -d"|" -f2)" = 0 ]
  crf_history_record_event github "new-family" 30 "$now"
  [ "$(crf_history_stats github "old-family" | cut -d"|" -f2)" = 0 ]
  [ "$(crf_history_stats github "new-family" | cut -d"|" -f2)" = 1 ]

  # Key and duration caps remain bounded, and raw job metadata does not persist.
  CRF_HISTORY_RETENTION_SECONDS=7776000
  CRF_HISTORY_MAX_KEYS=2
  sensitive="Build PR-123 https://github.example.test/org/repo/tree/secret-branch"
  crf_history_record_event github "$sensitive" 30 "$now"
  crf_history_record_event github "second-family" 30 "$((now + 1))"
  crf_history_record_event github "third-family" 30 "$((now + 2))"
  [ "$(crf_history_summary | cut -d"|" -f1)" = 2 ]
  ! grep -Fq "https://github.example.test/org/repo/tree/secret-branch" "$HISTORY_FILE"
  ! grep -Fq "$sensitive" "$HISTORY_FILE"
  mode="$(stat -c '%a' "$HISTORY_FILE" 2>/dev/null || stat -f '%Lp' "$HISTORY_FILE")"
  [ "$mode" = 600 ] || [ "$mode" = 0600 ]
  echo "runner-history: OK"
' bash
