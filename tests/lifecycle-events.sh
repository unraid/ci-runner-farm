#!/usr/bin/env bash
# Exit-driven replacement. A Docker "die" event for a farm-owned runner makes
# the lifecycle daemon replace that slot at once, through the same lock, exit
# check, growth gate and recycle path as the tick. Slot state lives in files, so
# background processes that model a concurrent tick share it. fleet.lock is a
# real flock, so the concurrency cases exercise the real lock.
# shellcheck disable=SC2034,SC2329  # engine globals and stubs are read by sourced functions
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
cleanup() {
  [ -z "${daemon_pid:-}" ] || kill "$daemon_pid" 2>/dev/null || true
  [ ! -s "$tmp/events.pid" ] || kill "$(cat "$tmp/events.pid")" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1 CRF_GROWTH_CPU_WINDOW=0
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/slots" "$tmp/proc"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
# A stub can fail inside a subshell whose output goes to the log, so every
# failure is also recorded in a file that the test checks at the end.
fail() { printf 'LIFECYCLE EVENTS FAIL: %s\n' "$*" | tee -a "$tmp/failures" >&2; exit 1; }

CI_PROVIDER=github GH_SCOPE=org RUNNER_MODE=pools AUTOSCALE=true GROWTH_BACKPRESSURE=true
RUNNER_POOLS='v3|build|general-build|unraid,build|9|9|16|1|4|16g|builtin'
pool_base_refresh
CRF_PROC_ROOT="$tmp/proc"
STARTS="$tmp/starts"
LOG="$tmp/log"
: > "$STARTS"; : > "$LOG"

# Host state for the real growth gate: BUSY percent CPU, plenty of memory.
set_host() {
  printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\n' "$1" "$((100 - $1))" > "$CRF_PROC_ROOT/stat"
  printf 'MemTotal: 131072000 kB\nMemAvailable: 104857600 kB\n' > "$CRF_PROC_ROOT/meminfo"
  printf '%s 0 0\n' "$(( $(date +%s) - 30 ))" > "$RUNDIR/growth-cpu.sample"
  growth_gate_reset
}

# A slot file holds "<container id> <status> <role>".
new_id() { local n; n=$(( $(cat "$tmp/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$tmp/seq"; printf '%064x\n' "$n"; }
slot() { printf '%s %s %s\n' "$2" "$3" "${4:-runner}" > "$tmp/slots/$1"; }
slot_id() { [ -f "$tmp/slots/$1" ] && cut -d' ' -f1 "$tmp/slots/$1"; }
exited_slot() { local id; id="$(new_id)"; slot "$1" "$id" exited "${2:-runner}"; printf '%s\n' "$id"; }

docker() {
  if [ "${1:-}" = ps ]; then ls "$tmp/slots"; return 0; fi
  [ ! -e "$tmp/inspect-fails" ] || return 1
  [ "${1:-}" = inspect ] || fail "unexpected docker call: $*"
  local fmt="" target f id status role
  [ "${2:-}" = -f ] && { fmt="$3"; target="$4"; } || target="$2"
  for f in "$tmp"/slots/*; do
    [ -e "$f" ] || continue
    read -r id status role < "$f"
    if [ "$target" = "${f##*/}" ] || [ "$target" = "$id" ]; then
      case "$fmt" in
        *State.Pid*)
          if [ "$status" = exited ]; then echo 'exited|false|false|false|0'; else echo 'running|true|false|false|42'; fi ;;
        *State.Running*) if [ "$status" = running ]; then echo true; else echo false; fi ;;
        *'.Id'*) printf '%s|github|%s\n' "$id" "$role" ;;
        *) echo "$status" ;;
      esac
      return 0
    fi
  done
  return 1
}
managed_runner_snapshot() {
  local id; id="$(slot_id "$1")" || return 1
  printf '%s|github|runner|%s|gen\n' "$id" "${1##*-}"
}
runner_pool() { local n="${1#ci-runner-}"; printf '%s\n' "${n%-*}"; }
# A recycle removes the exited owner and starts a new running one in its place.
cmd_recycle() {
  printf '%s\n' "$1" >> "$STARTS"
  sleep 0.2
  slot "$1" "$(new_id)" running
}
reload_locked_snapshot() { :; }
LIFECYCLE_YIELD=0
autoscale_running() { printf '%s\n' "$$" > "$AUTOSCALE_PID"; }
autoscale_stopped() { rm -f "$AUTOSCALE_PID"; }
starts() { tr '\n' ' ' < "$STARTS" | sed 's/ $//'; }
# ev ID NAME [EXIT-CODE]: one exit event, as the daemon passes it on.
ev() { lifecycle_event_dispatch "$1 $2 ${3-0}"; }
autoscale_running
set_host 20

# ---- an exited runner is replaced at once ------------------------------------
id="$(exited_slot ci-runner-build-3)"
ev "$id" ci-runner-build-3 >>"$LOG" 2>&1 || fail "event replacement reported failure"
[ "$(starts)" = ci-runner-build-3 ] || fail "exited runner was not replaced: '$(starts)'"
[ "$(cut -d' ' -f2 "$tmp/slots/ci-runner-build-3")" = running ] || fail "replacement is not running"
# The same event again finds the slot already replaced.
ev "$id" ci-runner-build-3 >>"$LOG" 2>&1
[ "$(starts)" = ci-runner-build-3 ] || fail "a repeated event started the slot twice"

# ---- autoscale stopped: no replacement ----------------------------------------
: > "$STARTS"
autoscale_stopped
id="$(exited_slot ci-runner-build-4)"
ev "$id" ci-runner-build-4 >>"$LOG" 2>&1
[ -z "$(starts)" ] || fail "a runner was replaced while autoscale was stopped"
grep -q 'ci-runner-build-4 exited while autoscale is stopped' "$LOG" || fail "stopped-autoscale skip was not logged"
# A fixed fleet has no autoscale daemon. Its watchdog still replaces exits.
AUTOSCALE=false
ev "$id" ci-runner-build-4 >>"$LOG" 2>&1
[ "$(starts)" = ci-runner-build-4 ] || fail "a fixed fleet did not replace an exited runner"
AUTOSCALE=true
autoscale_running

# ---- a settings drain is running: no replacement ------------------------------
: > "$STARTS"
# The check uses the same process match as the host reboot procedure, so a
# real process with the drain's command line models the drain.
if command -v pgrep >/dev/null 2>&1; then
  ( exec -a 'runner-farm.sh reconcile-drain' sleep 30 ) &
  drain_pid=$!
  for _ in $(seq 1 20); do pgrep -f '[r]unner-farm.sh reconcile-drain' >/dev/null && break; sleep 0.1; done
  id="$(exited_slot ci-runner-build-5)"
  ev "$id" ci-runner-build-5 >>"$LOG" 2>&1
  kill "$drain_pid"; wait "$drain_pid" 2>/dev/null || true
  [ -z "$(starts)" ] || fail "a runner was replaced during a settings drain"
  ev "$id" ci-runner-build-5 >>"$LOG" 2>&1
  [ "$(starts)" = ci-runner-build-5 ] || fail "the slot was not replaced after the drain ended"
else
  echo 'lifecycle-events: pgrep is missing; skipping the settings-drain case' >&2
fi

# ---- the growth gate withholds a slot above the pool minimum ------------------
: > "$STARTS"
set_host 95
id="$(exited_slot ci-runner-build-12)"
ev "$id" ci-runner-build-12 >>"$LOG" 2>&1 || fail "a withheld slot reported failure"
[ -z "$(starts)" ] || fail "a slot above the minimum started while the gate withholds growth"
[ "$(cut -d' ' -f2 "$tmp/slots/ci-runner-build-12")" = exited ] || fail "the withheld slot was removed"
# A refill up to the minimum is never gated.
set_host 95
id="$(exited_slot ci-runner-build-9)"
ev "$id" ci-runner-build-9 >>"$LOG" 2>&1
[ "$(starts)" = ci-runner-build-9 ] || fail "a slot at the minimum was not refilled: '$(starts)'"
set_host 20

# ---- events that must never start anything ------------------------------------
: > "$STARTS"
# A newer container already holds the slot.
old="$(exited_slot ci-runner-build-6)"
slot ci-runner-build-6 "$(new_id)" running
ev "$old" ci-runner-build-6 >>"$LOG" 2>&1
# The slot was removed (stop, scale down).
rm -f "$tmp/slots/ci-runner-build-7"
ev "$(new_id)" ci-runner-build-7 >>"$LOG" 2>&1
# The container restarted under the same ID (build-cache repair stop/start).
id="$(exited_slot ci-runner-build-8)"
slot ci-runner-build-8 "$id" running
ev "$id" ci-runner-build-8 >>"$LOG" 2>&1
# A validation container, a name outside the slot namespace, and a bad ID.
id="$(exited_slot ci-runner-validate-1234 validate)"
ev "$id" ci-runner-validate-1234 >>"$LOG" 2>&1
id="$(exited_slot other-container)"
ev "$id" other-container >>"$LOG" 2>&1
id="$(exited_slot ci-runner-build-10)"
ev "not-an-id" ci-runner-build-10 >>"$LOG" 2>&1
# GitLab managers keep their own lifecycle.
CI_PROVIDER=gitlab
ev "$id" ci-runner-build-10 >>"$LOG" 2>&1
CI_PROVIDER=github
# Removed-allocator state refuses every start.
( runner_starts_allowed() { return 1; }; ev "$id" ci-runner-build-10 >>"$LOG" 2>&1 )
[ -z "$(starts)" ] || fail "an event that must be ignored started: '$(starts)'"

# ---- only a clean exit is replaced at once ------------------------------------
# A runner that fails while it starts usually exits with an error. The tick's
# confirmations keep its retries slow, so the event leaves it alone.
: > "$STARTS"
id="$(exited_slot ci-runner-build-4)"
ev "$id" ci-runner-build-4 137 >>"$LOG" 2>&1
ev "$id" ci-runner-build-4 '' >>"$LOG" 2>&1
[ -z "$(starts)" ] || fail "a failed exit was replaced at once"
grep -q 'ci-runner-build-4 exited with code 137; the periodic check replaces it' "$LOG" \
  || fail "a failed exit was not logged"

# ---- one batch has one growth budget, like one tick ---------------------------
# Three slots above the minimum and one at it exit together. The gate admits at
# most two growth starts per batch. Refills up to the minimum are not counted.
: > "$STARTS"
set_host 20
a="$(exited_slot ci-runner-build-10)"; b="$(exited_slot ci-runner-build-11)"
c="$(exited_slot ci-runner-build-12)"; d="$(exited_slot ci-runner-build-1)"
lifecycle_event_dispatch "$a ci-runner-build-10 0
$b ci-runner-build-11 0
$c ci-runner-build-12 0
$d ci-runner-build-1 0" >>"$LOG" 2>&1 || fail "a batch reported failure"
[ "$(starts)" = 'ci-runner-build-10 ci-runner-build-11 ci-runner-build-1' ] \
  || fail "a batch did not keep the per-tick growth budget: '$(starts)'"
[ "$(cut -d' ' -f2 "$tmp/slots/ci-runner-build-12")" = exited ] || fail "the third growth slot started"

# ---- an image-update drain skips a slot that an exit event already replaced ---
# The drain sleeps with fleet.lock released while the runner is busy. The runner
# finishes, exits, and the event replaces it. The drain must not recycle the
# new runner, which can already have a job.
: > "$STARTS"
slot ci-runner-build-14 "$(new_id)" running
runner_busy() { [ ! -e "$tmp/job-done" ]; }
( flock 8
  sleep() { : > "$tmp/job-done"; slot ci-runner-build-14 "$(new_id)" running; }
  drain_and_recreate ci-runner-build-14 >>"$LOG" 2>&1 ) 8>"$RUNDIR/fleet.lock" \
  || fail "the drain failed on a replaced slot"
[ -z "$(starts)" ] || fail "the drain recycled a runner that the exit event had just started"
grep -q 'ci-runner-build-14 was replaced while it drained' "$LOG" || fail "the drain skip was not logged"
# An inspect that fails after the wait defers the slot. It is not counted as
# replaced, so a later cycle still moves it to the new image.
rm -f "$tmp/job-done"
if ( flock 8
  sleep() { : > "$tmp/job-done"; : > "$tmp/inspect-fails"; }
  drain_and_recreate ci-runner-build-14 >>"$LOG" 2>&1 ) 8>"$RUNDIR/fleet.lock"; then
  fail "the drain treated a failed inspect as a replaced slot"
fi
rm -f "$tmp/inspect-fails"
[ -z "$(starts)" ] || fail "the drain recycled a slot it could not inspect"
# The same slot that was not replaced is still recycled by the drain.
( flock 8; drain_and_recreate ci-runner-build-14 >>"$LOG" 2>&1 ) 8>"$RUNDIR/fleet.lock" \
  || fail "the drain failed on an idle slot"
[ "$(starts)" = ci-runner-build-14 ] || fail "the drain did not recycle an idle slot"
unset -f runner_busy

# ---- a concurrent tick and an event never both start a slot -------------------
# The tick holds fleet.lock and replaces the slot. The event waits for the lock
# and then finds the slot already replaced.
: > "$STARTS"
id="$(exited_slot ci-runner-build-2)"
( flock 8; : > "$tmp/held"; sleep 0.5; lifecycle_replace ci-runner-build-2 >>"$LOG" 2>&1 ) 8>"$RUNDIR/fleet.lock" &
tick=$!
for _ in $(seq 1 50); do [ -e "$tmp/held" ] && break; sleep 0.1; done
[ -e "$tmp/held" ] || fail "the modeled tick did not take fleet.lock"
ev "$id" ci-runner-build-2 >>"$LOG" 2>&1
wait "$tick"
[ "$(starts)" = ci-runner-build-2 ] || fail "tick then event started the slot $(grep -c . "$STARTS") times"
# The event runs first and the tick follows: the tick finds a running slot.
: > "$STARTS"; rm -f "$tmp/held"
id="$(exited_slot ci-runner-build-2)"
( flock 8; : > "$tmp/held"; sleep 0.5; lifecycle_event_replace "$id" ci-runner-build-2 >>"$LOG" 2>&1 ) 8>"$RUNDIR/fleet.lock" &
event=$!
for _ in $(seq 1 50); do [ -e "$tmp/held" ] && break; sleep 0.1; done
( flock 8; lifecycle_replace ci-runner-build-2 >>"$LOG" 2>&1 ) 8>"$RUNDIR/fleet.lock"
wait "$event"
[ "$(starts)" = ci-runner-build-2 ] || fail "event then tick started the slot $(grep -c . "$STARTS") times"
# Two events for one exit (for example a re-read stream) start it once.
: > "$STARTS"
id="$(exited_slot ci-runner-build-1)"
ev "$id" ci-runner-build-1 >>"$LOG" 2>&1 &
first=$!
ev "$id" ci-runner-build-1 >>"$LOG" 2>&1
wait "$first"
[ "$(starts)" = ci-runner-build-1 ] || fail "two events for one exit started the slot $(grep -c . "$STARTS") times"
# An event waits for other work that holds the lock, then replaces the slot.
: > "$STARTS"; rm -f "$tmp/held"
id="$(exited_slot ci-runner-build-13)"
set_host 20
( flock 8; : > "$tmp/held"; sleep 0.5 ) 8>"$RUNDIR/fleet.lock" &
holder=$!
for _ in $(seq 1 50); do [ -e "$tmp/held" ] && break; sleep 0.1; done
ev "$id" ci-runner-build-13 >>"$LOG" 2>&1
wait "$holder"
[ "$(starts)" = ci-runner-build-13 ] || fail "an event gave up while another holder briefly had fleet.lock"
# An event that cannot get the lock in time leaves the slot to the tick.
: > "$STARTS"; rm -f "$tmp/held"
id="$(exited_slot ci-runner-build-11)"
( flock 8; : > "$tmp/held"; sleep 3 ) 8>"$RUNDIR/fleet.lock" &
holder=$!
for _ in $(seq 1 50); do [ -e "$tmp/held" ] && break; sleep 0.1; done
LIFECYCLE_EVENT_LOCK_WAIT=1 ev "$id" ci-runner-build-11 >>"$LOG" 2>&1 \
  || fail "a lock timeout reported failure"
wait "$holder"
[ -z "$(starts)" ] || fail "an event started a slot without fleet.lock"
grep -q 'fleet.lock stayed busy; the next tick replaces ci-runner-build-11' "$LOG" || fail "lock timeout was not logged"

# ---- the daemon reads events between ticks and stops cleanly ------------------
# The event stream runs as an external command, so a fake docker executable on
# PATH supplies it. The first stream sends two exits and then ends, as when
# Docker restarts. The second stream sends one exit and stays open. It records
# its PID so the test can prove it was stopped.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
[ "\$1" = events ] || exit 1
n=\$(( \$(cat "$tmp/streams" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$tmp/streams"
if [ "\$n" = 1 ]; then
  printf '%s %s 0\n' "$(printf '%064x' 4242)" ci-runner-build-3 "$(printf '%064x' 4243)" ci-runner-build-4
  exit 0
fi
echo \$\$ > "$tmp/events.pid"
printf '%s %s 0\n' "$(printf '%064x' 4244)" ci-runner-build-5
exec sleep 60
EOF
chmod +x "$tmp/bin/docker"
DISPATCHED="$tmp/dispatched"
# Work under the lock must not inherit the event pipe.
fd_open() { [ -n "$LIFECYCLE_EVENT_FD" ] && [ -e "/dev/fd/$LIFECYCLE_EVENT_FD" ]; }
lifecycle_tick() { echo tick >> "$DISPATCHED"; ! fd_open || echo 'fd-open tick' >> "$DISPATCHED"; }
with_fleet_lock() { shift; "$@"; }
lifecycle_event_dispatch() {
  printf 'event %s\n' "$(cut -d' ' -f2 <<< "$1" | tr '\n' ' ')" >> "$DISPATCHED"
  ! fd_open || echo 'fd-open event' >> "$DISPATCHED"
}
load_cfg() { :; }
LIFECYCLE_INTERVAL=1
( PATH="$tmp/bin:$PATH"; unset -f docker; lifecycle_daemon ) >>"$LOG" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 100); do grep -q 'ci-runner-build-5' "$DISPATCHED" 2>/dev/null && break; sleep 0.1; done
[ "$(head -1 "$DISPATCHED")" = tick ] || fail "the daemon did not tick first"
grep -qx 'event ci-runner-build-3 ci-runner-build-4 ' "$DISPATCHED" \
  || fail "two close exits were not one batch: $(cat "$DISPATCHED" 2>/dev/null)"
grep -q 'Docker event stream ended' "$LOG" || fail "the end of the event stream was not logged"
grep -qx 'event ci-runner-build-5 ' "$DISPATCHED" \
  || fail "the daemon did not reopen the event stream: $(cat "$DISPATCHED" 2>/dev/null)"
! grep -q '^fd-open' "$DISPATCHED" || fail "work under the lock inherited the event pipe"
events_pid="$(cat "$tmp/events.pid")"
kill -0 "$events_pid" 2>/dev/null || fail "the event stream is not running"
kill -TERM "$daemon_pid"
for _ in $(seq 1 30); do kill -0 "$daemon_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$daemon_pid" 2>/dev/null && fail "the daemon did not stop promptly on TERM"
daemon_pid=""
for _ in $(seq 1 30); do kill -0 "$events_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$events_pid" 2>/dev/null && fail "the event stream outlived the daemon"

[ ! -s "$tmp/failures" ] || fail "a stub failed inside a subshell: $(head -1 "$tmp/failures")"
echo 'lifecycle-events: OK — clean exits replaced at once, under fleet.lock, gated and never doubled'
