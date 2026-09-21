#!/bin/bash
# Pure job-weight and pool-target helpers for the advisory recommendation engine.
#
# These helpers deliberately do not call Docker, GitHub, GitLab, or mutate
# configuration. The engine supplies live job name, CPU, memory, and age data;
# the result is an explainable heuristic that an operator can review.

crf_recommendation_weight() {
  local job="${1:-}" cpu="${2:-}" memory="${3:-}" elapsed="${4:-0}"
  local historical_p95="${5:-0}" historical_samples="${6:-0}"
  local lower score reason class
  lower="$(printf '%s' "$job" | tr '[:upper:]' '[:lower:]')"
  score=2
  reason="general workload"

  case "$lower" in
    *fedora*|*build*|*compile*|*docker*|*buildx*|*release*|*artifact*|*native*|*e2e*|*integration*|*package*)
      score=4; reason="build or artifact workload" ;;
    *test*|*quality*|*exunit*|*unit*|*plugin*|*deploy*|*migration*)
      score=3; reason="test or quality workload" ;;
    *lint*|*format*|*check*|*policy*|*docs*)
      score=1; reason="short validation workload" ;;
  esac

  case "$elapsed" in ''|*[!0-9]*) elapsed=0 ;; esac
  if [ "$elapsed" -ge 7200 ]; then
    score=$((score + 2)); reason="$reason, running over two hours"
  elif [ "$elapsed" -ge 1800 ]; then
    score=$((score + 1)); reason="$reason, running over thirty minutes"
  fi

  # Historical duration is deliberately gated on three completed samples. A
  # single slow run should be visible in telemetry, not strong enough to move
  # every future run into the heavy class.
  case "$historical_p95:$historical_samples" in
    *[!0-9:]*|'') historical_p95=0; historical_samples=0 ;;
  esac
  if [ "$historical_samples" -ge 3 ] 2>/dev/null && [ "$historical_p95" -ge 7200 ] 2>/dev/null; then
    score=$((score + 2)); reason="$reason, historical P95 exceeds two hours"
  elif [ "$historical_samples" -ge 3 ] 2>/dev/null && [ "$historical_p95" -ge 1800 ] 2>/dev/null; then
    score=$((score + 1)); reason="$reason, historical P95 exceeds thirty minutes"
  fi

  # Docker stats reports CPU as a percentage of one host CPU and memory in MiB.
  # Treat these as corroborating signals, not hard resource contracts.
  if printf '%s\n' "$cpu" | awk '$1 ~ /^[0-9]+([.][0-9]+)?$/ && $1 >= 150 {found=1} END {exit found ? 0 : 1}'; then
    score=$((score + 1)); reason="$reason, high CPU use"
  fi
  if printf '%s\n' "$memory" | awk '$1 ~ /^[0-9]+([.][0-9]+)?$/ && $1 >= 4096 {found=1} END {exit found ? 0 : 1}'; then
    score=$((score + 1)); reason="$reason, high memory use"
  fi

  [ "$score" -gt 5 ] && score=5
  if [ "$score" -ge 4 ]; then class=heavy
  elif [ "$score" -le 1 ]; then class=light
  else class=standard
  fi
  printf '%s|%s|%s\n' "$class" "$score" "$reason"
}

crf_recommendation_target_pool() {
  local class="${1:-standard}" targets labels rec pool target=""
  if ! pool_mode_enabled; then
    printf 'default\n'
    return 0
  fi

  case "$class" in
    light) targets='size-small small light' ;;
    heavy) targets='size-large large heavy build-large' ;;
    *)     targets='size-standard standard medium build-standard' ;;
  esac

  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    pool="$(printf '%s' "$rec" | cut -d'|' -f2)"
    labels="$(pool_effective_labels "$pool" 2>/dev/null || true)"
    for target in $targets; do
      case ",$labels," in
        *",$target,"*) printf '%s\n' "$pool"; return 0 ;;
      esac
    done
  done < <(pool_records 2>/dev/null)
  printf 'unassigned\n'
}
