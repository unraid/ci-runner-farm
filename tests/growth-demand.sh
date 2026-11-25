#!/usr/bin/env bash
# Demand-aware pool growth (include/growth-queue.sh): queue-driven targets,
# replacements that skip the CPU checks, starting runners as pending capacity,
# the smoothed CPU reading, and the GitHub queue reader. Fake /proc files and
# Docker/GitHub stubs; nothing here touches the host.
# shellcheck disable=SC2034,SC2329  # engine globals and stubs are read by sourced functions
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1 CRF_GROWTH_CPU_WINDOW=0
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/proc"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'GROWTH DEMAND FAIL: %s\n' "$*" >&2; exit 1; }

CI_PROVIDER=github GH_SCOPE=org RUNNER_MODE=pools AUTOSCALE=true GROWTH_BACKPRESSURE=true
GROWTH_CPU_CEILING=80 GROWTH_MEMORY_RESERVE=8g
# build: min 2, max 12, warm 1. quick: min 0, max 6, warm 1.
RUNNER_POOLS='v3|build|general-build|self-hosted,build|2|2|12|1|4|8g|builtin;v3|quick|quick-build|self-hosted|1|0|6|1|1|2g|builtin'
pool_base_refresh
CRF_PROC_ROOT="$tmp/proc"
LOG="$tmp/log"; : > "$LOG"
log() { printf '%s\n' "$*" >> "$LOG"; }
[ "$GROWTH_QUEUE" = true ] || fail "GROWTH_QUEUE is not on by default"

set_host() {  # <cpu busy percent>
  printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\n' "$1" "$((100 - $1))" > "$CRF_PROC_ROOT/stat"
  printf 'MemTotal: 131072000 kB\nMemAvailable: 104857600 kB\n' > "$CRF_PROC_ROOT/meminfo"
  printf '%s 0 0\n' "$(( $(date +%s) - 30 ))" > "$RUNDIR/growth-cpu.sample"
  growth_gate_reset
}

# ---- fleet model ----------------------------------------------------------
# One line per slot: "<name> <state> <ran seconds> <ended seconds ago> <exit>"
# where state is busy, idle, starting, created, exited or paused.
FLEET="$tmp/fleet"
fleet() { printf '%s\n' "$@" > "$FLEET"; }
managed_names() { cut -d' ' -f1 "$FLEET"; }
runner_pool() { local n="${1#ci-runner-}"; printf '%s\n' "${n%-*}"; }
managed_runner_snapshot() { printf '%s|github|runner|%s|gen\n' "$1" "${1##*-}"; }
slot_field() { awk -v n="$1" -v f="$2" '$1 == n { print $f }' "$FLEET"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123456789Z; }
docker() {
  local state
  case "$1" in
    inspect)
      if [ "$2" = --format ]; then
        case "$(slot_field "$4" 2)" in
          exited) echo 'exited|false' ;; created) echo 'created|false' ;; paused) echo 'running|true' ;;
          *) echo 'running|false' ;;
        esac
        return 0
      fi
      # Replacement check: Status|ExitCode|StartedAt|FinishedAt
      state="$(slot_field "$4" 2)"; [ -n "$state" ] || return 1
      local now ended ran; now="$(date +%s)"
      ended=$(( now - $(slot_field "$4" 4) )); ran="$(slot_field "$4" 3)"
      if [ "$state" = exited ]; then
        printf 'exited|%s|%s|%s\n' "$(slot_field "$4" 5)" "$(iso $(( ended - ran )))" "$(iso "$ended")"
      else
        printf 'running|0|%s|0001-01-01T00:00:00Z\n' "$(iso $(( now - 60 )))"
      fi ;;
    top)
      case "$(slot_field "$2" 2)" in
        busy) printf 'PID COMMAND\n1 Runner.Listener\n2 Runner.Worker\n' ;;
        idle) printf 'PID COMMAND\n1 Runner.Listener\n' ;;
        starting) printf 'PID COMMAND\n1 bash\n2 config.sh\n' ;;
      esac ;;
    *) fail "unexpected docker call: $*" ;;
  esac
}
SPAWNS="$tmp/spawns"; : > "$SPAWNS"
growth_queue_spawn() { echo spawn >> "$SPAWNS"; }
queue() {  # <age seconds> then "pool count" pairs
  local age="$1"; shift
  { printf 'v1 %s\n' "$(( $(date +%s) - age ))"; printf '%s %s\n' "$@"; } > "$RUNDIR/pool-queue.cache"
}

# ---- starting runners are pending, not unknown ----------------------------
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 starting 5 0 0'
rm -f "$RUNDIR/pool-queue.cache"
[ "$(pool_runner_counts build)" = '3 2 0 false' ] || fail "a starting runner was not pending: $(pool_runner_counts build)"
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 busy 60 0 0' 'ci-runner-build-4 created 0 0 0'
[ "$(pool_runner_counts build)" = '4 3 0 false' ] || fail "a created runner was not pending: $(pool_runner_counts build)"
# Three busy and one pending runner: busy + warm = 4, so the pending runner is
# the warm one and the pool holds at 4 (before, it was "unknown" and also 4).
[ "$(pool_start_target build)" = 4 ] || fail "pending runner changed the target"
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 busy 60 0 0' 'ci-runner-build-4 starting 5 0 0' 'ci-runner-build-5 busy 60 0 0'
# Four busy runners and one starting: growth continues to busy + warm = 5...
# and with one more busy, past the starting runner (before, it stopped at 5).
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 busy 60 0 0' 'ci-runner-build-4 starting 5 0 0' 'ci-runner-build-5 busy 60 0 0' 'ci-runner-build-6 busy 60 0 0'
[ "$(pool_start_target build)" = 6 ] || fail "starting runner held the target: $(pool_start_target build)"
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 paused 60 0 0' 'ci-runner-build-4 busy 60 0 0'
[ "$(pool_start_target build)" = 4 ] || fail "a paused runner did not keep growth unknown"

# ---- queue-driven targets --------------------------------------------------
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 busy 60 0 0'
queue 10 build 5 quick 0
[ "$(pool_start_target build)" = 8 ] || fail "queue present: want busy 3 + queued 5 = 8, got $(pool_start_target build)"
queue 10 build 40 quick 0
[ "$(pool_start_target build)" = 12 ] || fail "queue target was not capped at the pool maximum"
queue 10 build 0 quick 0
[ "$(pool_start_target build)" = 4 ] || fail "empty queue: want busy + warm = 4"
queue 181 build 5 quick 0
[ "$(pool_start_target build)" = 4 ] || fail "stale reading was used"
rm -f "$RUNDIR/pool-queue.cache"
[ "$(pool_start_target build)" = 4 ] || fail "missing reading did not fall back"
printf 'garbage\nbuild 5\n' > "$RUNDIR/pool-queue.cache"
[ "$(pool_start_target build)" = 4 ] || fail "malformed reading was used"
queue 10 quick 5
[ "$(pool_start_target build)" = 4 ] || fail "a reading without the pool was used"
queue 10 build 5 quick 0
GROWTH_QUEUE=false
[ "$(pool_start_target build)" = 4 ] || fail "GROWTH_QUEUE=false still used the queue"
GROWTH_QUEUE=true GROWTH_BACKPRESSURE=false
[ "$(pool_start_target build)" = 4 ] || fail "the queue was used without the growth gate"
GROWTH_BACKPRESSURE=true
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 paused 60 0 0'
[ "$(pool_start_target build)" = 3 ] || fail "the queue grew a pool with an unknown runner"

# A pool with no idle runner asks for a reading when it is due; one with an
# idle runner, or a fresh reading, does not.
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0'
: > "$SPAWNS"; rm -f "$RUNDIR/pool-queue.cache"
pool_start_target build >/dev/null
[ "$(wc -l < "$SPAWNS")" = 1 ] || fail "a saturated pool did not ask for a reading"
: > "$SPAWNS"; queue 30 build 0 quick 0
pool_start_target build >/dev/null
[ ! -s "$SPAWNS" ] || fail "a fresh reading was refreshed again"
queue 95 build 0 quick 0
pool_start_target build >/dev/null
[ -s "$SPAWNS" ] || fail "a due reading was not refreshed"
: > "$SPAWNS"; rm -f "$RUNDIR/pool-queue.cache"
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 idle 60 0 0'
pool_start_target build >/dev/null
[ ! -s "$SPAWNS" ] || fail "a pool with an idle runner asked for a reading"

# ---- replacements skip the CPU checks only while the pool has no idle runner
rm -f "$RUNDIR/pool-queue.cache"
admit_slot() { growth_gate_reset; growth_gate_admit_slot "$1" "${1##*-}"; }
set_host 95
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 busy 60 0 0' 'ci-runner-build-4 exited 300 5 0'
admit_slot ci-runner-build-4 || fail "a replacement in a saturated pool was withheld on CPU"
grep -qF 'admitted ci-runner-build-4: replacement, the pool has no idle runner (CPU checks skipped), cpu 95%' "$LOG" \
  || fail "replacement log missing: $(cat "$LOG")"
# A replacement does not use the per-tick growth pacing.
growth_gate_reset
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 exited 300 5 0' 'ci-runner-build-4 exited 300 5 0' 'ci-runner-build-5 exited 300 5 0'
for i in 3 4 5; do growth_gate_admit_slot "ci-runner-build-$i" "$i" || fail "replacement $i was paced"; done
# Nor do replacements use up the net-growth budget of the same tick.
set_host 20
growth_gate_admit_slot ci-runner-build-3 3 && growth_gate_admit_slot ci-runner-build-4 4 || fail "replacements withheld"
growth_gate_admit build 9 ci-runner-build-9 && growth_gate_admit build 10 ci-runner-build-10 \
  || fail "replacements used up the net-growth pacing"
if growth_gate_admit build 11 ci-runner-build-11; then fail "net growth was not paced"; fi
set_host 95
# Each of these is net growth or not a finished job, so the CPU gate holds it.
for slot in \
  'ci-runner-build-4 exited 300 200 0' \
  'ci-runner-build-4 exited 10 5 0' \
  'ci-runner-build-4 exited 300 5 1'; do
  fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 busy 60 0 0' "$slot"
  if admit_slot ci-runner-build-4; then fail "not a replacement but admitted at 95% CPU: $slot"; fi
done
# An idle runner in the pool means nothing waits that it could take.
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 idle 60 0 0' 'ci-runner-build-4 exited 300 5 0'
if admit_slot ci-runner-build-4; then fail "a replacement beside an idle runner skipped the CPU gate"; fi
# Memory still applies to replacements.
fleet 'ci-runner-build-1 busy 60 0 0' 'ci-runner-build-2 busy 60 0 0' 'ci-runner-build-3 busy 60 0 0' 'ci-runner-build-4 exited 300 5 0'
printf 'MemTotal: 131072000 kB\nMemAvailable: 1048576 kB\n' > "$CRF_PROC_ROOT/meminfo"
if admit_slot ci-runner-build-4; then fail "a replacement skipped the memory check"; fi
set_host 95
GROWTH_QUEUE=false
if admit_slot ci-runner-build-4; then fail "GROWTH_QUEUE=false still exempted a replacement"; fi
GROWTH_QUEUE=true
# Slots at or below the minimum are refills and always pass, as before.
fleet 'ci-runner-build-1 exited 300 500 1' 'ci-runner-build-2 idle 60 0 0'
admit_slot ci-runner-build-1 || fail "a refill below the minimum was gated"

# ---- smoothed CPU reading -------------------------------------------------
now="$(date +%s)"
# 90 s ago: 0/0. 20 s ago: 900 total, 100 idle (a busy burst). Now: 1000/500.
printf '%s 0 0\n%s 900 100\n' "$(( now - 90 ))" "$(( now - 20 ))" > "$RUNDIR/growth-cpu.sample"
printf 'cpu  500 0 0 500 0 0 0 0 0 0\n' > "$CRF_PROC_ROOT/stat"
[ "$(growth_cpu_busy_percent)" = 50 ] || fail "CPU was not measured over the minute-old sample"
# With several, the newest one at least a minute old is used: 70 s ago at
# 400 total / 300 idle gives 600 jiffies, 200 idle, so 67%.
printf '%s 0 0\n%s 400 300\n%s 900 100\n' "$(( now - 200 ))" "$(( now - 70 ))" "$(( now - 20 ))" > "$RUNDIR/growth-cpu.sample"
[ "$(growth_cpu_busy_percent)" = 67 ] || fail "CPU did not use the newest minute-old sample"
# Without a sample a minute old, the oldest usable one is used.
printf '%s 0 0\n%s 900 100\n' "$(( now - 40 ))" "$(( now - 20 ))" > "$RUNDIR/growth-cpu.sample"
[ "$(growth_cpu_busy_percent)" = 50 ] || fail "CPU did not fall back to the oldest sample"
# Samples are spaced: a reading under 10 s after the newest one is not stored.
printf '%s 0 0\n' "$(( now - 5 ))" > "$RUNDIR/growth-cpu.sample"
growth_cpu_record_sample
[ "$(wc -l < "$RUNDIR/growth-cpu.sample")" = 1 ] || fail "samples were not spaced"
printf '%s 0 0\n' "$(( now - 15 ))" > "$RUNDIR/growth-cpu.sample"
growth_cpu_record_sample
[ "$(wc -l < "$RUNDIR/growth-cpu.sample")" = 2 ] || fail "the tick sample was not stored"
# Old, future and higher-than-now samples are dropped.
printf '%s 0 0\n%s 1 1\n%s 5000 1\n' "$(( now - 400 ))" "$(( now + 50 ))" "$(( now - 30 ))" > "$RUNDIR/growth-cpu.sample"
growth_cpu_record_sample
[ "$(wc -l < "$RUNDIR/growth-cpu.sample")" = 1 ] || fail "unusable samples were kept: $(cat "$RUNDIR/growth-cpu.sample")"

# ---- GitHub queue reader --------------------------------------------------
labels="$tmp/labels"
uname() { echo aarch64; }
growth_queue_pool_labels | grep -qx 'quick quick-build,self-hosted,linux,arm64' || fail "arm64 hosts use the arm64 label"
uname() { echo x86_64; }
growth_queue_pool_labels > "$labels"
grep -qx 'build general-build,self-hosted,build,linux,x64' "$labels" || fail "build labels: $(cat "$labels")"
grep -qx 'quick quick-build,self-hosted,linux,x64' "$labels" || fail "quick labels: $(cat "$labels")"
printf '%s' '{"jobs":[
  {"id":1,"status":"queued","labels":["self-hosted","General-Build"]},
  {"id":2,"status":"queued","labels":["quick-build"]},
  {"id":3,"status":"in_progress","labels":["general-build"]},
  {"id":4,"status":"queued","labels":["self-hosted"]},
  {"id":5,"status":"queued","labels":["ubuntu-latest"]},
  {"id":6,"status":"queued","labels":[]},
  {"id":1,"status":"queued","labels":["general-build"]}]}' > "$tmp/jobs1"
printf 'not json' > "$tmp/jobs2"
counts="$(github_pool_queue_count "$labels" "$tmp/jobs1" "$tmp/jobs2" | sort)"
# Job 4 matches both pools; it counts once, in the pool with fewer labels.
[ "$counts" = $'build 1\nquick 2' ] || fail "queue counts: $counts"

printf '%s' '{"workflow_runs":[{"id":11,"status":"queued","created_at":"2026-01-01T00:02:00Z"},{"id":12,"status":"queued","created_at":"2026-01-01T00:01:00Z"},{"id":13,"status":"completed","created_at":"2026-01-01T00:00:00Z"}]}' > "$tmp/runs1"
printf '%s' '{"workflow_runs":[{"id":21,"status":"in_progress","created_at":"2026-01-01T00:01:00Z"},{"id":22,"status":"in_progress","created_at":"2026-01-01T00:03:00Z"}]}' > "$tmp/runs2"
order="$(github_pool_queue_runs "a/x=$tmp/runs1" "a/x=$tmp/runs2" "a/y=$tmp/missing" | awk '{print $4}' | tr '\n' ' ')"
[ "$order" = '12 11 22 21 ' ] || fail "run reading order: $order"
if github_pool_queue_runs "a/y=$tmp/missing" >/dev/null; then fail "no run list was treated as an empty queue"; fi

# Repositories come from busy runners on this host, limited to GH_REPOS.
GH_REPOS='acme/one acme/Two acme/three'
b64() { printf '%s' "$1" | base64 -w0; }
row() { printf '%s 1 1 %s j 0 github p _ u r r %s _ b _\n' "$1" "$2" "$(b64 "$3")"; }
{ row ci-runner-build-1 busy acme/one; row ci-runner-build-2 busy acme/two; row ci-runner-build-3 idle acme/three
  row ci-runner-build-4 busy other/repo; row ci-runner-build-5 busy 'acme/one;rm'; row ci-runner-build-6 busy acme/one; } > "$RUNDIR/usage.cache"
[ "$(github_pool_queue_repos | tr '\n' ' ')" = 'acme/Two acme/one ' ] || fail "repos: $(github_pool_queue_repos | tr '\n' ' ')"
touch -d '-200 seconds' "$RUNDIR/usage.cache"
[ -z "$(github_pool_queue_repos)" ] || fail "a stale usage snapshot was used"
touch "$RUNDIR/usage.cache"

# The refresh: two run lists per repository, then job lists; GitHub stubbed.
GH_REPOS='acme/one'
row ci-runner-build-1 busy acme/one > "$RUNDIR/usage.cache"
CALLS="$tmp/calls"; : > "$CALLS"
gh_api() {
  printf '%s\n' "$2" >> "$CALLS"
  case "$2" in
    *status=queued*) printf '%s' '{"workflow_runs":[{"id":7,"status":"queued","created_at":"2026-01-01T00:00:00Z"}]}' ;;
    *status=in_progress*) printf '%s' '{"workflow_runs":[]}' ;;
    */runs/7/jobs*) printf '%s' '{"jobs":[{"id":70,"status":"queued","labels":["general-build"]},{"id":71,"status":"queued","labels":["quick-build"]},{"id":72,"status":"queued","labels":["general-build"]}]}' ;;
    *) return 1 ;;
  esac
}
rm -f "$RUNDIR/pool-queue.cache" "$RUNDIR/gh-ratelimit"
github_pool_queue_refresh
[ "$(growth_queue_depth build)" = 2 ] && [ "$(growth_queue_depth quick)" = 1 ] || fail "refresh did not write the counts: $(cat "$RUNDIR/pool-queue.cache" 2>/dev/null)"
[ "$(wc -l < "$CALLS")" = 3 ] || fail "refresh made unexpected calls: $(cat "$CALLS")"
# Under the reader's reserve nothing is read and the old reading stays.
printf '1999 %s\n' "$(( $(date +%s) + 600 ))" > "$RUNDIR/gh-ratelimit"
queue 100 build 9 quick 9; : > "$CALLS"
github_pool_queue_refresh
[ ! -s "$CALLS" ] && [ "$(growth_queue_depth build)" = 9 ] || fail "the reader ignored its reserve"
rm -f "$RUNDIR/gh-ratelimit"
# When every run list fails, nothing is written.
gh_api() { return 1; }
queue 100 build 9 quick 9
github_pool_queue_refresh
[ "$(growth_queue_depth build)" = 9 ] || fail "a failed read replaced the reading"
# No busy repository on this host: nothing to read.
: > "$RUNDIR/usage.cache"; : > "$CALLS"
gh_api() { printf '%s\n' "$2" >> "$CALLS"; return 1; }
github_pool_queue_refresh
[ ! -s "$CALLS" ] || fail "the reader read without a busy repository"
# GitLab and single layouts never read.
RUNNER_MODE=single; row ci-runner-build-1 busy acme/one > "$RUNDIR/usage.cache"
github_pool_queue_refresh
[ ! -s "$CALLS" ] || fail "the reader ran outside pool mode"

echo 'growth-demand: OK — queue targets, fallbacks, pending starts, replacements, smoothed CPU, queue reader'
