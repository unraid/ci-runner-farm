#!/bin/bash
# Persistent, aggregate job-duration history for the recommendation engine.
#
# The history file stores only provider, a normalized job-family key, counts,
# duration totals, min/max, and a coarse duration histogram. It intentionally
# does not persist job URLs, refs, repositories, branch names, or raw titles.
# The aggregate survives a reboot while the active-job transition cache stays
# on tmpfs.

CRF_HISTORY_RETENTION_SECONDS="${CRF_HISTORY_RETENTION_SECONDS:-7776000}" # 90 days
CRF_HISTORY_MAX_KEYS="${CRF_HISTORY_MAX_KEYS:-512}"
CRF_HISTORY_MAX_DURATION="${CRF_HISTORY_MAX_DURATION:-604800}"           # 7 days

crf_history_file() {
  printf '%s\n' "${HISTORY_FILE:-${CFGDIR:-.}/recommendations.history}"
}

crf_history_cache_file() {
  printf '%s\n' "${RUNDIR:-.}/recommendations-history.cache"
}

crf_history_refresh_cache() {
  local history cache tmp
  history="$(crf_history_file)"; cache="$(crf_history_cache_file)"
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 1
  tmp="$(mktemp "${cache}.tmp.XXXXXX")" || return 1
  if [ -f "$history" ]; then
    awk -F '\t' '$1 == "v1" && NF >= 17 { print }' "$history" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    : > "$tmp"
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$cache"
}

crf_history_read_file() {
  local history cache htime ctime
  history="$(crf_history_file)"; cache="$(crf_history_cache_file)"
  [ -f "$cache" ] || { crf_history_refresh_cache >/dev/null 2>&1 || true; }
  [ -f "$history" ] || { printf '%s\n' "$cache"; return 0; }
  [ -f "$cache" ] || { printf '%s\n' "$history"; return 0; }
  htime="$(stat -c %Y "$history" 2>/dev/null || echo 0)"
  ctime="$(stat -c %Y "$cache" 2>/dev/null || echo 0)"
  if [ "$ctime" -ge "$htime" ] 2>/dev/null; then printf '%s\n' "$cache"; else printf '%s\n' "$history"; fi
}

crf_history_decode64() {
  printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null || true
}

crf_history_epoch() {
  local timestamp="${1:-}" epoch
  case "$timestamp" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$timestamp"; return 0 ;;
  esac
  epoch="$(date -d "$timestamp" +%s 2>/dev/null || true)"
  case "$epoch" in ''|*[!0-9]*) epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" +%s 2>/dev/null || echo 0)" ;; esac
  printf '%s\n' "$epoch"
}

# Normalize dynamic run identifiers so PR-123 and PR-124 contribute to the
# same family without writing the original title to persistent storage.
crf_history_key() {
  local provider="${1:-unknown}" job="${2:-unknown}" key
  key="$(printf '%s/%s' "$provider" "$job" | tr '[:upper:]' '[:lower:]' | sed -E \
    -e 's/(pull|pr|merge)[-_ #]*[0-9]+/\1-n/g' \
    -e 's/[0-9a-f]{7,40}/sha/g' \
    -e 's/[0-9]+/n/g' \
    -e 's/[^a-z0-9]+/-/g' \
    -e 's/^-+//' -e 's/-+$//')"
  [ -n "$key" ] || key=unknown
  printf '%s\n' "${key:0:120}"
}

# Histogram buckets: <=30s, <=60s, <=5m, <=10m, <=30m, <=1h, <=2h,
# <=4h, and >4h. P95 is therefore intentionally approximate but stable.
crf_history_bucket() {
  local duration="${1:-0}"
  case "$duration" in ''|*[!0-9]*) duration=0 ;; esac
  if [ "$duration" -le 30 ]; then echo 0
  elif [ "$duration" -le 60 ]; then echo 1
  elif [ "$duration" -le 300 ]; then echo 2
  elif [ "$duration" -le 600 ]; then echo 3
  elif [ "$duration" -le 1800 ]; then echo 4
  elif [ "$duration" -le 3600 ]; then echo 5
  elif [ "$duration" -le 7200 ]; then echo 6
  elif [ "$duration" -le 14400 ]; then echo 7
  else echo 8
  fi
}

crf_history_bucket_ceiling() {
  case "${1:-8}" in
    0) echo 30 ;; 1) echo 60 ;; 2) echo 300 ;; 3) echo 600 ;; 4) echo 1800 ;;
    5) echo 3600 ;; 6) echo 7200 ;; 7) echo 14400 ;; *) echo 604800 ;;
  esac
}

# Return key|samples|p95_seconds|average_seconds|min_seconds|max_seconds|last_epoch.
crf_history_stats() {
  local provider="${1:-unknown}" job="${2:-unknown}" key line
  local version hprovider hkey count total min max b0 b1 b2 b3 b4 b5 b6 b7 b8 last
  local rank cumulative bucket p95 avg
  key="$(crf_history_key "$provider" "$job")"
  line="$(awk -F '\t' -v p="$provider" -v k="$key" \
    '$1 == "v1" && $2 == p && $3 == k && NF >= 17 { print; exit }' "$(crf_history_read_file)" 2>/dev/null || true)"
  if [ -z "$line" ]; then
    printf '%s|0|0|0|0|0|0\n' "$key"
    return 0
  fi
  IFS=$'\t' read -r version hprovider hkey count total min max b0 b1 b2 b3 b4 b5 b6 b7 b8 last <<< "$line"
  case "$count:$total:$min:$max" in *[!0-9:]*|'') printf '%s|0|0|0|0|0|0\n' "$key"; return 0 ;; esac
  rank=$(( (count * 95 + 99) / 100 )); [ "$rank" -lt 1 ] && rank=1
  cumulative=0; p95=604800
    for bucket in 0 1 2 3 4 5 6 7 8; do
    case "$bucket" in
      0) cumulative=$((cumulative + b0)) ;;
      1) cumulative=$((cumulative + b1)) ;;
      2) cumulative=$((cumulative + b2)) ;;
      3) cumulative=$((cumulative + b3)) ;;
      4) cumulative=$((cumulative + b4)) ;;
      5) cumulative=$((cumulative + b5)) ;;
      6) cumulative=$((cumulative + b6)) ;;
      7) cumulative=$((cumulative + b7)) ;;
      8) cumulative=$((cumulative + b8)) ;;
    esac
    if [ "$cumulative" -ge "$rank" ]; then p95="$(crf_history_bucket_ceiling "$bucket")"; break; fi
  done
  avg=$(( (total + count / 2) / count ))
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$key" "$count" "$p95" "$avg" "$min" "$max" "${last:-0}"
}

crf_history_summary() {
  local file; file="$(crf_history_read_file)"
  [ -f "$file" ] || { printf '0|0|0\n'; return 0; }
  awk -F '\t' '
    $1 == "v1" && NF >= 17 && $4 ~ /^[0-9]+$/ {
      keys++; samples += $4; if (($17 + 0) > last) last = $17 + 0
    }
    END { printf "%d|%d|%d\n", keys + 0, samples + 0, last + 0 }
  ' "$file" 2>/dev/null || printf '0|0|0\n'
}

crf_history_unlock() {
  command -v flock >/dev/null 2>&1 && flock -u 9 2>/dev/null || true
  exec 9>&-
}

crf_history_record_event() {
  local provider="${1:-unknown}" job="${2:-}" duration="${3:-0}" epoch="${4:-0}"
  local file key bucket cutoff tmp count sorted tmp2
  [ -n "$job" ] || return 0
  case "$duration:$epoch" in *[!0-9:]*|'') return 0 ;; esac
  [ "$duration" -ge 1 ] 2>/dev/null && [ "$duration" -le "$CRF_HISTORY_MAX_DURATION" ] 2>/dev/null || return 0
  [ "$epoch" -gt 0 ] 2>/dev/null || return 0
  file="$(crf_history_file)"; key="$(crf_history_key "$provider" "$job")"
  bucket="$(crf_history_bucket "$duration")"; cutoff=$((epoch - CRF_HISTORY_RETENTION_SECONDS))
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${RUNDIR}/recommendations-history.lock"
    flock -w 5 9 2>/dev/null || { exec 9>&-; return 1; }
  else
    # Unraid ships flock. The no-lock fallback keeps the pure helper tests
    # portable on macOS; usage-refresh already serializes production writers.
    exec 9>/dev/null
  fi
  [ -f "$file" ] || : > "$file"
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || { crf_history_unlock; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  awk -F '\t' -v OFS='\t' -v p="$provider" -v k="$key" -v d="$duration" \
    -v e="$epoch" -v b="$bucket" -v cutoff="$cutoff" '
    BEGIN { found = 0 }
    $1 == "v1" && NF >= 17 {
      if ($2 == p && $3 == k) {
        found = 1; $4 += 1; $5 += d; if ($6 == 0 || d < $6) $6 = d; if (d > $7) $7 = d
        $(8 + b) += 1; $17 = e
      }
      if (($17 + 0) >= cutoff) print
      next
    }
    END {
      if (!found) print "v1", p, k, 1, d, d, d, (b == 0), (b == 1), (b == 2), (b == 3), (b == 4), (b == 5), (b == 6), (b == 7), (b == 8), e
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; crf_history_unlock; return 1; }
  count="$(awk -F '\t' '$1 == "v1" && NF >= 17 { n++ } END { print n + 0 }' "$tmp")"
  if [ "$count" -gt "$CRF_HISTORY_MAX_KEYS" ]; then
    tmp2="$(mktemp "${file}.tmp.XXXXXX")" || { rm -f "$tmp"; crf_history_unlock; return 1; }
    sort -t $'\t' -k17,17nr "$tmp" | head -n "$CRF_HISTORY_MAX_KEYS" | sort -t $'\t' -k2,2 -k3,3 > "$tmp2"
    chmod 600 "$tmp2" 2>/dev/null || true
    mv -f "$tmp2" "$tmp"
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
  crf_history_refresh_cache >/dev/null 2>&1 || true
  crf_history_unlock
}

# Compare the previous and current provider-neutral usage snapshots. A job is
# recorded only when its runner still exists and is observed idle or running a
# different identifiable job; disappearing runners are intentionally ignored.
crf_history_record_snapshot() {
  local previous="${1:-}" current="${2:-}" now="${3:-0}"
  local row runner cpu mem phase job64 started provider project64 jobid cur
  local cur_cpu cur_mem cur_phase cur_job64 cur_started cur_provider cur_project64 cur_jobid
  local same start_epoch duration job
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$previous" ] && [ -n "$current" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    read -r runner cpu mem phase job64 started provider project64 jobid _ <<< "$row"
    [ "$phase" = busy ] || continue
    [ -n "$runner" ] && [ "$runner" != _ ] || continue
    cur="$(printf '%s\n' "$current" | awk -v n="$runner" '$1 == n { print; exit }')"
    [ -n "$cur" ] || continue
    read -r _ cur_cpu cur_mem cur_phase cur_job64 cur_started cur_provider cur_project64 cur_jobid _ <<< "$cur"
    same=false
    case "$cur_phase" in
      busy)
        if [ "$cur_provider" = "$provider" ] && [ "$jobid" != _ ] && [ "$cur_jobid" != _ ]; then
          # GitHub's current context uses workflow-run ID as the stable
          # provider identifier, so keep the job family and start time in the
          # identity check to distinguish matrix jobs and retries.
          [ "$jobid" = "$cur_jobid" ] && [ "$job64" = "$cur_job64" ] && [ "$started" = "$cur_started" ] && same=true
        elif [ "$cur_job64" = _ ] || [ "$cur_started" = _ ]; then
          same=true # incomplete live context: wait for a complete sample
        elif [ "$cur_provider" = "$provider" ] && [ "$cur_job64" = "$job64" ] && [ "$cur_started" = "$started" ]; then
          same=true
        fi
        ;;
      idle) same=false ;;
      *) continue ;;
    esac
    [ "$same" = true ] && continue
    case "$started" in ''|_) continue ;; esac
    start_epoch="$(crf_history_epoch "$started")"
    case "$start_epoch" in ''|*[!0-9]*) continue ;; esac
    duration=$((now - start_epoch)); [ "$duration" -ge 1 ] || continue
    [ "$duration" -le "$CRF_HISTORY_MAX_DURATION" ] || continue
    [ "$job64" != _ ] || continue
    job="$(crf_history_decode64 "$job64")"
    [ -n "$job" ] || continue
    crf_history_record_event "$provider" "$job" "$duration" "$now" || true
  done <<< "$previous"
}
