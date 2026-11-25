#!/bin/bash
# Demand-aware pool growth (GROWTH_QUEUE, on by default).
#
# With the growth gate on, every start above a pool's minimum re-checks host
# CPU, including the restart of a slot whose runner just finished a job. Under
# a burst the host is busy, so finished slots stay exited and pools shrink
# while jobs wait. Growth past the highest slot also stops at busy + one warm
# runner, because the farm cannot see the queue. This module adds two things:
#
#   * Replacements. Restarting a slot whose runner finished a job keeps the
#     pool's size; it adds no load the host did not already carry. When the
#     pool on this host has no idle runner, there may be jobs waiting for it,
#     so such a restart skips the gate's CPU checks and its per-tick pacing.
#     Memory checks still apply. An idle runner takes a matching queued job
#     within seconds, so a pool with an idle runner has nothing waiting that it
#     could take, and its restarts are gated as before: that is how a pool
#     shrinks after demand ends. A restart counts as a replacement only when
#     the old runner exited with code 0 in the last GROWTH_REPLACE_WINDOW
#     seconds after running for at least GROWTH_REPLACE_MIN_RUN seconds, so a
#     runner that fails while it starts cannot restart in a fast loop, and a
#     slot that has been held back longer is net growth.
#
#   * A per-pool queued job count. pool_start_target grows a pool toward busy
#     + queued (not only busy + warm), still capped by the pool maximum and
#     admitted by the gate. The count comes from the GitHub REST API
#     (providers/github.sh, github_pool_queue_refresh) and is written to
#     $RUNDIR/pool-queue.cache by a background command. An autoscale check
#     asks for a new reading only while one of its pools has no idle runner,
#     at most every GROWTH_QUEUE_REFRESH_AGE seconds. A reading older than
#     GROWTH_QUEUE_MAX_AGE, a missing or malformed file, or a pool the reading
#     does not name all mean "unknown", and the target is then busy + warm, as
#     before. The reading can undercount, which only means less growth.
#
# Both act only for GitHub pools (RUNNER_MODE=pools) with AUTOSCALE and
# GROWTH_BACKPRESSURE on, so the pool maximum, memory checks, and for net
# growth the host CPU ceiling, still bound every start.
#
# Safe to source from tests. Callers provide RUNDIR, pool_mode_enabled,
# pool_records, pool_effective_labels, pool_runner_counts and
# growth_gate_enabled.

GROWTH_QUEUE_REFRESH_AGE=90 # seconds before a check asks for a new reading
GROWTH_QUEUE_MAX_AGE=180    # older readings are not used
GROWTH_REPLACE_WINDOW=120   # seconds after a clean exit that a restart is a replacement
GROWTH_REPLACE_MIN_RUN=30   # seconds the old runner must have run

growth_queue_enabled() {
  [ "${GROWTH_QUEUE:-true}" = true ] && [ "${AUTOSCALE:-false}" = true ] && [ "${CI_PROVIDER:-github}" = github ] \
    && pool_mode_enabled && growth_gate_enabled
}

growth_queue_cache() { printf '%s/pool-queue.cache\n' "$RUNDIR"; }

# Age in seconds of the current reading, or fail when there is none.
growth_queue_age() {
  local file version ts now
  file="$(growth_queue_cache)"
  [ -f "$file" ] || return 1
  read -r version ts _ < "$file" 2>/dev/null || return 1
  [ "$version" = v1 ] && growth_uint "$ts" || return 1
  now="$(date +%s)"
  [ "$ts" -le "$now" ] || return 1
  printf '%s\n' "$(( now - ts ))"
}

# Print the queued job count for <pool> from a fresh reading, or fail.
growth_queue_depth() {
  local age count
  growth_queue_enabled || return 1
  age="$(growth_queue_age)" && [ "$age" -le "$GROWTH_QUEUE_MAX_AGE" ] || return 1
  count="$(awk -v pool="$1" 'NR > 1 && $1 == pool { print $2; exit }' "$(growth_queue_cache)" 2>/dev/null)"
  growth_uint "$count" || return 1
  printf '%s\n' "$count"
}

# Start a background reading when the current one is missing or due. The
# child closes the fleet lock descriptors it inherits, so the refresh never
# holds the lock, and its own flock keeps one refresh at a time.
growth_queue_request() {
  local age
  growth_queue_enabled || return 0
  if age="$(growth_queue_age)" && [ "$age" -lt "$GROWTH_QUEUE_REFRESH_AGE" ]; then return 0; fi
  growth_queue_spawn
}

growth_queue_spawn() {
  ( exec 8>&- 7>&-; flock -n 9 || exit 0; exec "$0" pool-queue-refresh ) \
    9>"$RUNDIR/pool-queue.lock" </dev/null >/dev/null 2>&1 &
}

# The labels each pool's runners register with, one "pool label,label" line
# per pool, lowercase. A pool that carries self-hosted also gets GitHub's
# default OS and architecture labels (see github_pool_labels_exact).
growth_queue_pool_labels() {
  local pool labels arch
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch="" ;;
  esac
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    labels="$(pool_effective_labels "$pool")" || return 1
    labels="$(printf '%s' "$labels" | tr '[:upper:]' '[:lower:]')"
    case ",$labels," in *,self-hosted,*) labels+=",linux${arch:+,$arch}" ;; esac
    printf '%s %s\n' "$pool" "$labels"
  done < <(pool_records | cut -d'|' -f2)
}

# Replace the reading with stdin ("pool count" lines) stamped now.
growth_queue_write() {
  local file tmp
  file="$(growth_queue_cache)"; tmp="$file.tmp.$$"
  { printf 'v1 %s\n' "$(date +%s)"; cat; } > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Seconds since the epoch for a Docker timestamp, or fail.
growth_epoch() {
  local epoch
  epoch="$(date -d "$1" +%s 2>/dev/null)" && growth_uint "$epoch" || return 1
  printf '%s\n' "$epoch"
}

# Print why restarting container <c> of <pool> is a replacement, or fail. The
# pool's idle count is read once per gate process (GROWTH_POOL_IDLE): a
# replacement started in the same batch is still starting, not idle.
growth_replacement_reason() {
  local pool="$1" c="$2" state status code started finished start end now counts idle
  growth_queue_enabled || return 1
  state="$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{.State.StartedAt}}|{{.State.FinishedAt}}' "$c" 2>/dev/null)" \
    || return 1
  IFS='|' read -r status code started finished <<< "$state"
  [ "$status" = exited ] && [ "$code" = 0 ] || return 1
  start="$(growth_epoch "$started")" && end="$(growth_epoch "$finished")" || return 1
  now="$(date +%s)"
  [ "$end" -le "$now" ] && [ $(( now - end )) -le "$GROWTH_REPLACE_WINDOW" ] || return 1
  [ $(( end - start )) -ge "$GROWTH_REPLACE_MIN_RUN" ] || return 1
  idle="${GROWTH_POOL_IDLE[$pool]:-}"
  if [ -z "$idle" ]; then
    counts="$(pool_runner_counts "$pool")" || return 1
    read -r _ _ idle _ <<< "$counts"
    growth_uint "$idle" || return 1
    GROWTH_POOL_IDLE["$pool"]="$idle"
  fi
  [ "$idle" -eq 0 ] || return 1
  printf 'the pool has no idle runner\n'
}
