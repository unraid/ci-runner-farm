#!/usr/bin/env bash
# Growth backpressure gate. Fake /proc files supply host CPU and memory, and a
# stub Docker records every call. The tests cover each gate condition, refills
# up to the minimum, fail-safe metrics, log-once state changes, every start
# path that can grow the fleet, and the unchanged runner fingerprint.
# shellcheck disable=SC2034,SC2329  # engine globals and stubs are read by sourced functions
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1 CRF_GROWTH_CPU_WINDOW=0
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'GROWTH BACKPRESSURE FAIL: %s\n' "$*" >&2; exit 1; }

[ "$GROWTH_BACKPRESSURE" = false ] || fail "backpressure is not off by default"
[ "$GROWTH_CPU_CEILING" = 80 ] && [ "$GROWTH_MEMORY_RESERVE" = 8g ] || fail "default thresholds changed"

PROC="$tmp/proc"
mkdir -p "$PROC"
CRF_PROC_ROOT="$PROC"
LOG="$tmp/gate.log"
MUTATIONS="$tmp/mutations"
: > "$LOG"; : > "$MUTATIONS"

# set_host BUSY_PERCENT MEM_GIB: one tick of host state. The stored previous
# sample is 30 s old and at zero, so the CPU delta equals the stat line.
set_host() {
  printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\ncpu0 1 0 0 1 0 0 0 0 0 0\n' "$1" "$((100 - $1))" > "$PROC/stat"
  printf 'MemTotal:       131072000 kB\nMemFree:          1000000 kB\nMemAvailable:   %s kB\n' \
    "$(($2 * 1048576))" > "$PROC/meminfo"
  printf '%s 0 0\n' "$(( $(date +%s) - 30 ))" > "$RUNDIR/growth-cpu.sample"
  growth_gate_reset
}
admit() { growth_gate_admit "$@" >>"$LOG"; }
expect_admit() { admit "$@" || fail "expected admission: $* ($(tail -1 "$LOG"))"; }
expect_withhold() { if admit "$@"; then fail "expected withheld: $* ($(tail -1 "$LOG"))"; fi; }
state() { cut -d'|' -f1 "$RUNDIR/growth-gate.state"; }
log_lines() { grep -c 'growth backpressure:' "$LOG" || true; }

CI_PROVIDER=github GH_SCOPE=org RUNNER_MODE=pools AUTOSCALE=true
RUNNER_POOLS='v3|build|general-build|unraid,build|9|9|16|1|4|16g|builtin;v3|small|build-small|self-hosted|3|3|3|1|1|2g|builtin'
pool_base_refresh

# ---- off is a no-op ------------------------------------------------------------
GROWTH_BACKPRESSURE=false
CRF_PROC_ROOT="$tmp/missing-proc"
expect_admit build 10 ci-runner-build-10
[ ! -e "$RUNDIR/growth-gate.state" ] && [ ! -e "$RUNDIR/growth-cpu.sample" ] \
  || fail "disabled gate read metrics or wrote state"
[ "$(growth_gate_status)" = off ] || fail "disabled gate status is not 'off'"
GROWTH_BACKPRESSURE=true
# A fixed fleet (AUTOSCALE off) never grows, so nothing is gated.
AUTOSCALE=false
expect_admit build 10 ci-runner-build-10
AUTOSCALE=true
[ ! -e "$RUNDIR/growth-gate.state" ] || fail "fixed fleet start was evaluated by the gate"
[ "$(growth_gate_status)" = 'on, no growth requested yet' ] || fail "fresh gate status changed"
CRF_PROC_ROOT="$PROC"

# ---- thresholds ----------------------------------------------------------------
set_host 50 80
expect_admit build 10 ci-runner-build-10
[ "$(state)" = admitted ] || fail "admission was not recorded"
grep -qF 'growth backpressure: admitted ci-runner-build-10: cpu 50% (ceiling 80%), MemAvailable 81920 MiB (need 16384 + reserve 8192 MiB)' "$LOG" \
  || fail "admission log lacks its numbers: $(cat "$LOG")"
# The current reading becomes the next tick's previous sample.
read -r _ sample_total sample_idle < "$RUNDIR/growth-cpu.sample"
[ "$sample_total" = 100 ] && [ "$sample_idle" = 50 ] || fail "CPU sample was not stored for the next tick"

set_host 80 80
expect_admit build 10 ci-runner-build-10        # at the ceiling is not above it
set_host 81 80
expect_withhold build 10 ci-runner-build-10
[ "$(state)" = withheld:cpu ] || fail "CPU withhold not recorded"
grep -qF 'growth backpressure: withheld ci-runner-build-10: cpu 81% (ceiling 80%)' "$LOG" || fail "CPU withhold log missing"
GROWTH_CPU_CEILING=90
set_host 81 80
expect_admit build 10 ci-runner-build-10
GROWTH_CPU_CEILING=80

set_host 10 23                                        # 23 GiB < 16g runner + 8g reserve
expect_withhold build 10 ci-runner-build-10
[ "$(state)" = withheld:memory ] || fail "memory withhold not recorded"
grep -qF 'withheld ci-runner-build-10: cpu 10% (ceiling 80%), MemAvailable 23552 MiB (need 16384 + reserve 8192 MiB)' "$LOG" \
  || fail "memory withhold log lacks its numbers"
set_host 10 24
expect_admit build 10 ci-runner-build-10
GROWTH_MEMORY_RESERVE=0
set_host 10 16
expect_admit build 10 ci-runner-build-10
GROWTH_MEMORY_RESERVE=8g
# The pool's own memory limit is used, not the global one.
set_host 10 11
expect_admit small 4 ci-runner-small-4
set_host 10 9
expect_withhold small 4 ci-runner-small-4
# Decimal sizes reach the gate exactly: a 1.5g runner plus a 0.5g reserve needs
# 2 GiB (2097152 kB). Single layout reads the global runner memory, which
# accepts decimals (pool records do not).
mem_kib() { printf 'MemTotal: 131072000 kB\nMemAvailable: %s kB\n' "$1" > "$PROC/meminfo"; }
saved_memory="$BASE_RUNNER_MEMORY"
RUNNER_MODE=single AUTOSCALE_MIN=2 BASE_RUNNER_MEMORY=1.5g GROWTH_MEMORY_RESERVE=0.5g
set_host 10 80; mem_kib 2097152
expect_admit default 3 'runner 3'
grep -qF 'MemAvailable 2048 MiB (need 1536 + reserve 512 MiB)' "$LOG" || fail "decimal sizes were not converted exactly"
set_host 10 80; mem_kib 2097151
expect_withhold default 3 'runner 3'
[ "$(state)" = withheld:memory ] || fail "decimal memory threshold did not withhold on memory"
RUNNER_MODE=pools BASE_RUNNER_MEMORY="$saved_memory" GROWTH_MEMORY_RESERVE=8g

# Each admitted start deducts its memory limit within the tick.
GROWTH_STARTS_PER_TICK=4
set_host 10 50
expect_admit build 10 ci-runner-build-10          # 50 >= 24
expect_admit build 11 ci-runner-build-11          # 34 >= 24
expect_withhold build 12 ci-runner-build-12       # 18 < 24
GROWTH_STARTS_PER_TICK=2
# At most two gated starts per tick; pacing is not a logged state change.
set_host 10 200
expect_admit build 10 ci-runner-build-10
expect_admit build 11 ci-runner-build-11
before="$(log_lines)"
expect_withhold build 12 ci-runner-build-12
[ "$(log_lines)" = "$before" ] && [ "$(state)" = admitted ] || fail "per-tick pacing was logged as a gate decision"

# CPU uses the delta since the previous sample; iowait counts as idle.
set_host 10 80
printf 'cpu  25 0 0 50 25 0 0 0 0 0\n' > "$PROC/stat"
expect_admit build 10 ci-runner-build-10
printf '%s 1000 900\n' "$(( $(date +%s) - 30 ))" > "$RUNDIR/growth-cpu.sample"
printf 'cpu  400 0 0 1000 0 0 0 0 0 0\n' > "$PROC/stat"   # dt 400, idle 100 -> 75%
growth_gate_reset
[ "$(growth_cpu_busy_percent)" = 75 ] || fail "CPU delta since the previous sample is wrong"
printf '%s 0 0\n' "$(( $(date +%s) - 30 ))" > "$RUNDIR/growth-cpu.sample"
printf 'cpu  25 0 0 50 25 0 0 0 0 0\n' > "$PROC/stat"
[ "$(growth_cpu_busy_percent)" = 25 ] || fail "iowait was counted as busy"
# With no usable previous sample, the gate measures a fresh window instead.
sleep() { printf 'cpu  110 0 0 90 0 0 0 0 0 0\n' > "$PROC/stat"; }  # +100 jiffies, 40 idle
for previous in missing old recent; do
  set_host 50 80
  case "$previous" in
    missing) rm -f "$RUNDIR/growth-cpu.sample" ;;
    old) printf '%s 0 0\n' "$(( $(date +%s) - 301 ))" > "$RUNDIR/growth-cpu.sample" ;;
    recent) printf '%s 0 0\n' "$(date +%s)" > "$RUNDIR/growth-cpu.sample"; GROWTH_CPU_WINDOW=2 ;;
  esac
  [ "$(growth_cpu_busy_percent)" = 60 ] || fail "fresh CPU window after a $previous sample is wrong"
  GROWTH_CPU_WINDOW=0
done
unset -f sleep

# Sizes: binary units, decimals, and a bound that keeps the arithmetic exact.
[ "$(growth_size_bytes 16g)" = 17179869184 ] && [ "$(growth_size_bytes 1.5G)" = 1610612736 ] \
  && [ "$(growth_size_bytes 512mib)" = 536870912 ] && [ "$(growth_size_bytes 0)" = 0 ] \
  && [ "$(growth_size_bytes 1024t)" = 1125899906842624 ] || fail "size parsing changed"
for bad in 1025t 9000000t 99999999999999999 -1g 1.5555g 16q ''; do
  if growth_size_bytes "$bad" >/dev/null; then fail "size '$bad' was accepted"; fi
done

# ---- refills up to the minimum are never gated -----------------------------------
set_host 99 1
rm -f "$PROC/stat"
for idx in 1 5 9; do expect_admit build "$idx" "ci-runner-build-$idx"; done
expect_withhold build 10 ci-runner-build-10
[ "$(state)" = withheld:metrics ] || fail "unreadable metrics were not recorded"
# Single layout uses AUTOSCALE_MIN as the floor.
RUNNER_MODE=single AUTOSCALE_MIN=2 AUTOSCALE_MAX=16
expect_admit default 2 'runner 2'
expect_withhold default 3 'runner 3'
RUNNER_MODE=pools

# ---- unreadable metrics: no growth, logged once per state change -------------------
set_host 10 80
expect_admit build 10 ci-runner-build-10
: > "$LOG"
for broken in missing-stat malformed-stat no-cpu-line missing-meminfo no-memavailable stale-sample old-sample; do
  set_host 10 80
  case "$broken" in
    missing-stat) rm -f "$PROC/stat" ;;
    malformed-stat) printf 'cpu  x 0 0 1 0 0 0 0\n' > "$PROC/stat" ;;
    no-cpu-line) printf 'intr 1 2 3\n' > "$PROC/stat" ;;
    missing-meminfo) rm -f "$PROC/meminfo" ;;
    no-memavailable) printf 'MemTotal: 1 kB\nMemFree: 1 kB\n' > "$PROC/meminfo" ;;
    # No usable previous sample, and no CPU time passes in the fresh window.
    stale-sample) rm -f "$RUNDIR/growth-cpu.sample" ;;
    old-sample) printf '%s 0 0\n' "$(( $(date +%s) - 301 ))" > "$RUNDIR/growth-cpu.sample" ;;
  esac
  expect_withhold build 10 ci-runner-build-10
  [ "$(state)" = withheld:metrics ] || fail "$broken did not withhold as unreadable metrics"
done
[ "$(log_lines)" = 1 ] || fail "unreadable metrics were logged $(log_lines) times, not once: $(cat "$LOG")"
grep -qF 'growth backpressure: withheld ci-runner-build-10: host CPU or memory metrics are unreadable' "$LOG" \
  || fail "unreadable metrics log changed"
set_host 10 80
expect_admit build 10 ci-runner-build-10
set_host 10 80
expect_admit build 10 ci-runner-build-10
[ "$(log_lines)" = 2 ] || fail "repeated admissions were logged again"

# Invalid settings withhold rather than guessing.
for bad in 'GROWTH_CPU_CEILING=0' 'GROWTH_CPU_CEILING=101' 'GROWTH_CPU_CEILING=abc' 'GROWTH_MEMORY_RESERVE=lots' 'GROWTH_MEMORY_RESERVE=9000000t'; do
  set_host 10 80
  GROWTH_CPU_CEILING=80 GROWTH_MEMORY_RESERVE=8g
  printf -v "${bad%%=*}" '%s' "${bad#*=}"
  expect_withhold build 10 ci-runner-build-10
  [ "$(state)" = withheld:settings ] || fail "$bad was not rejected"
done
GROWTH_CPU_CEILING=80 GROWTH_MEMORY_RESERVE=8g

# Status shows the latest decision with its numbers.
set_host 95 80
expect_withhold build 10 ci-runner-build-10
case "$(growth_gate_status)" in
  'withheld '*'s ago: cpu 95% (ceiling 80%)'*) ;;
  *) fail "status does not show the latest decision: $(growth_gate_status)" ;;
esac

# ---- pressure stall information -------------------------------------------------------
# psi RESOURCE SOME_AVG10 [FULL_AVG10]: one fake /proc/pressure file.
psi() {
  mkdir -p "$PROC/pressure"
  { printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\n' "$2"
    [ -z "${3:-}" ] || printf 'full avg10=%s avg60=0.00 avg300=0.00 total=1\n' "$3"; } > "$PROC/pressure/$1"
}
psi cpu 35.20 0.00; psi memory 0.00 0.00; psi io 1.40 0.05
[ "$(growth_psi_summary)" = 'cpu some 35.20%, memory some 0.00% full 0.00%, io some 1.40% (avg10)' ] \
  || fail "pressure summary changed: $(growth_psi_summary)"
set_host 10 80
expect_admit build 10 ci-runner-build-10
# The gate logs only state changes; the state file always holds the latest decision.
latest() { cut -d'|' -f3- "$RUNDIR/growth-gate.state"; }
latest | grep -qF 'memory pressure some 0.00% full 0.00% (limits 20.00% / 5.00%)' \
  || fail "the decision does not show memory pressure: $(latest)"
# Memory pressure is a safety net: "full" above 5% or "some" above 20% withholds.
for case in '0.00 5.00 admit' '0.00 5.01 withhold' '20.00 0.00 admit' '20.01 0.00 withhold'; do
  read -r some full want <<< "$case"
  psi memory "$some" "$full"; set_host 10 80
  if [ "$want" = admit ]; then
    expect_admit build 10 ci-runner-build-10
  else
    expect_withhold build 10 ci-runner-build-10
    [ "$(state)" = withheld:memory-pressure ] || fail "memory pressure some $some full $full withheld as $(state)"
  fi
done
# Pressure is sampled once per tick, with the other host metrics.
psi memory 0.00 0.00; set_host 10 80
expect_admit build 10 ci-runner-build-10
psi memory 50.00 50.00
expect_admit build 11 ci-runner-build-11
# CPU and IO pressure never withhold: host CPU busy stays the CPU signal.
psi cpu 95.00 0.00; psi memory 0.00 0.00; psi io 60.00 40.00; set_host 10 80
expect_admit build 10 ci-runner-build-10
# Each memory pressure line is checked on its own: "some" alone still counts.
printf 'some avg10=20.01 avg60=0.00 avg300=0.00 total=1\n' > "$PROC/pressure/memory"; set_host 10 80
expect_withhold build 10 ci-runner-build-10
[ "$(state)" = withheld:memory-pressure ] || fail "memory pressure without a full line was ignored"
printf 'some avg10=1.00 avg60=0.00 avg300=0.00 total=1\n' > "$PROC/pressure/memory"; set_host 10 80
expect_admit build 10 ci-runner-build-10
latest | grep -qF 'memory pressure some 1.00% full - ' || fail "a missing full line was not shown as '-': $(latest)"
# Unreadable or malformed pressure data skips the check.
printf 'garbage\n' > "$PROC/pressure/memory"; set_host 10 80
expect_admit build 10 ci-runner-build-10
if growth_psi_summary >/dev/null 2>&1; then fail "malformed pressure data produced a summary"; fi
rm -rf "$PROC/pressure"; set_host 10 80
expect_admit build 10 ci-runner-build-10
if latest | grep -q 'memory pressure'; then fail "missing pressure data was reported"; fi

# ---- pinned hosts: the chosen CPU block must not be busy -------------------------------
# Placement is stubbed; tests/cpu-pinning.sh covers what it reports.
CHOOSE_CALLS="$tmp/choose"; : > "$CHOOSE_CALLS"; CHOICE='8-11 2999 1'
crf_cpu_pinning_choose() { printf '%s\n' "$*" >> "$CHOOSE_CALLS"; [ "$CHOICE" != fail ] || return 1; printf '%s\n' "$CHOICE"; }
CPU_PINNING=false; set_host 10 80
expect_admit build 10 ci-runner-build-10
[ ! -s "$CHOOSE_CALLS" ] || fail "the gate consulted placement with pinning off"
CPU_PINNING=true; set_host 10 80
expect_admit build 10 ci-runner-build-10
grep -qx '4 ci-runner-build-10' "$CHOOSE_CALLS" || fail "placement was not asked for the pool's CPU limit and slot: $(cat "$CHOOSE_CALLS")"
latest | grep -qF 'CPU block 8-11 in use 2.99 cores (limit 3.00)' || fail "the decision does not show the block load: $(latest)"
CHOICE='8-11 3000 1'; set_host 10 80
expect_withhold build 10 ci-runner-build-10
[ "$(state)" = withheld:cpu-block ] || fail "a busy CPU block withheld as $(state)"
case "$(growth_gate_status)" in
  *'CPU block 8-11 in use 3.00 cores (limit 3.00)'*) ;;
  *) fail "status does not show the busy block: $(growth_gate_status)" ;;
esac
# Without a usage sample (count-based placement) the block check is skipped.
CHOICE='8-11 9000 0'; set_host 10 80
expect_admit build 10 ci-runner-build-10
if latest | grep -q 'CPU block'; then fail "an unmeasured block was reported"; fi
CHOICE=fail; set_host 10 80
expect_admit build 10 ci-runner-build-10
# The host CPU ceiling and the memory checks apply first, without previewing
# placement.
CHOICE='8-11 0 1'; : > "$CHOOSE_CALLS"; set_host 95 80
expect_withhold build 10 ci-runner-build-10
[ "$(state)" = withheld:cpu ] || fail "the CPU ceiling no longer applies under pinning"
set_host 10 1
expect_withhold build 10 ci-runner-build-10
[ "$(state)" = withheld:memory ] || fail "the memory floor no longer applies under pinning"
[ ! -s "$CHOOSE_CALLS" ] || fail "placement was previewed although a cheaper check withheld the start"
# A busy verdict holds for the rest of the tick: later slots are withheld
# without another preview, even if the load would now read differently.
CHOICE='8-11 3000 1'; : > "$CHOOSE_CALLS"; set_host 10 80
expect_withhold build 10 ci-runner-build-10
CHOICE='8-11 0 1'
expect_withhold build 11 ci-runner-build-11
[ "$(state)" = withheld:cpu-block ] && [ "$(wc -l < "$CHOOSE_CALLS")" -eq 1 ] \
  || fail "a busy block was previewed again in the same tick: $(cat "$CHOOSE_CALLS")"
# One start per tick passes a measured block check; the next waits quietly.
: > "$CHOOSE_CALLS"; set_host 10 80
expect_admit build 10 ci-runner-build-10
expect_withhold build 11 ci-runner-build-11
[ "$(state)" = admitted ] && [ "$(wc -l < "$CHOOSE_CALLS")" -eq 1 ] \
  || fail "a second start in the tick was previewed or logged: $(state)"
set_host 10 80
expect_admit build 11 ci-runner-build-11
# Unmeasured placement keeps the normal pacing of two starts per tick.
CHOICE='8-11 0 0'; set_host 10 80
expect_admit build 10 ci-runner-build-10
expect_admit build 11 ci-runner-build-11
# Pinning applies to GitHub runners only; GitLab never previews placement.
CHOICE='8-11 3000 1'; : > "$CHOOSE_CALLS"; set_host 10 80
CI_PROVIDER=gitlab expect_admit build 10 ci-runner-build-10
[ ! -s "$CHOOSE_CALLS" ] || fail "a GitLab start previewed CPU placement"
# Refills up to the floor never consult placement.
: > "$CHOOSE_CALLS"; set_host 10 80
expect_admit build 5 ci-runner-build-5
[ ! -s "$CHOOSE_CALLS" ] || fail "a refill consulted placement"
# Each pool's own CPU limit is used; an inherited limit uses the base one, and
# a fractional limit (never pinned) skips the check.
CHOICE='0 3000 1'; set_host 10 80
expect_withhold small 4 ci-runner-small-4
grep -qx '1 ci-runner-small-4' "$CHOOSE_CALLS" || fail "the small pool's CPU limit was not used"
saved_pools="$RUNNER_POOLS" saved_cpus="$BASE_RUNNER_CPUS"
RUNNER_POOLS='v3|build|general-build|unraid,build|9|9|16|1|inherit|16g|builtin'
BASE_RUNNER_CPUS=6; CHOICE='0-5 0 1'; : > "$CHOOSE_CALLS"; set_host 10 80
expect_admit build 10 ci-runner-build-10
grep -qx '6 ci-runner-build-10' "$CHOOSE_CALLS" || fail "an inherited CPU limit was not resolved"
BASE_RUNNER_CPUS=2.5; : > "$CHOOSE_CALLS"; set_host 10 80
expect_admit build 10 ci-runner-build-10
[ ! -s "$CHOOSE_CALLS" ] || fail "a fractional CPU limit consulted placement"
RUNNER_POOLS="$saved_pools" BASE_RUNNER_CPUS="$saved_cpus"
# Whole-core groups: the limit is three quarters of a core per thread in the
# group (6 cores for 8 threads), and never below the 3-core block limit.
CPU_PINNING_WHOLE_CORES=true
CHOICE='0-3,16-19 5999 1'; : > "$CHOOSE_CALLS"; set_host 10 80
expect_admit build 10 ci-runner-build-10
latest | grep -qF 'CPU group 0-3,16-19 in use 5.99 cores (limit 6.00)' \
  || fail "the decision does not show the group load and limit: $(latest)"
CHOICE='0-3,16-19 6000 1'; set_host 10 80
expect_withhold build 10 ci-runner-build-10
[ "$(state)" = withheld:cpu-block ] || fail "a busy CPU group withheld as $(state)"
# The thread count comes from the chosen group: 6 threads allow 4.50 cores.
CHOICE='0-2,16-18 4499 1'; set_host 10 80
expect_admit build 10 ci-runner-build-10
latest | grep -qF 'CPU group 0-2,16-18 in use 4.49 cores (limit 4.50)' \
  || fail "the group limit did not follow the group size: $(latest)"
# A busy verdict cached in the tick names the group.
CHOICE='0-3,16-19 6000 1'; set_host 10 80
expect_withhold build 10 ci-runner-build-10
expect_withhold build 11 ci-runner-build-11
latest | grep -qF 'CPU group busy (checked earlier in this tick)' || fail "the cached verdict does not name the group: $(latest)"
# A one-core group of 2 threads keeps the 3-core block limit.
CHOICE='0,16 2999 1'; set_host 10 80
expect_admit small 4 ci-runner-small-4
latest | grep -qF 'CPU group 0,16 in use 2.99 cores (limit 3.00)' \
  || fail "a one-core group did not keep the block limit: $(latest)"
# With the setting off, a block keeps the fixed 3-core limit whatever its size.
CPU_PINNING_WHOLE_CORES=false
CHOICE='0-7 3000 1'; set_host 10 80
expect_withhold build 10 ci-runner-build-10
latest | grep -qF 'CPU block 0-7 in use 3.00 cores (limit 3.00)' \
  || fail "block mode did not keep its fixed limit: $(latest)"
CPU_PINNING=false
unset -f crf_cpu_pinning_choose
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/cpu-pinning.sh

# ---- start paths ----------------------------------------------------------------------
# A stub fleet: EXISTING lists slot names, STOPPED lists stopped ones; every
# runner that exists is busy. Docker reads are answered; any other Docker
# command, removal, or stop is recorded as a mutation.
EXISTING=""; STOPPED=""; STARTS="$tmp/starts"
# shellcheck disable=SC2086  # EXISTING is a space-separated name list
managed_names() { printf '%s\n' $EXISTING; }
runner_pool() { local n="${1#ci-runner-}"; printf '%s\n' "${n%-*}"; }
managed_runner_snapshot() { printf 'id-%s|github|runner|%s|gen\n' "$1" "${1##*-}"; }
docker() {
  case "$1" in
    inspect)
      if [ "$2" = --format ]; then
        case " $STOPPED " in *" ${4#id-} "*) printf 'exited|false\n' ;; *) printf 'running|false\n' ;; esac
        return 0
      fi
      if [ "$2" = -f ]; then
        case " $STOPPED " in *" ${3#id-} "*|*" ${4#id-} "*) printf 'false\n' ;; *) printf 'true\n' ;; esac
        return 0
      fi
      case " $EXISTING " in *" $2 "*) return 0 ;; *) return 1 ;; esac ;;
    top) printf 'PID COMMAND\n1 Runner.Listener\n2 Runner.Worker\n' ;;
    ps)
      # Only the growth state listing filters on running; it skips STOPPED.
      for slot in $EXISTING; do
        case "$*:: $STOPPED " in *status=running*" $slot "*) continue ;; esac
        printf '%s\n' "$slot"
      done ;;
    *) printf 'docker %s\n' "$*" >> "$MUTATIONS"; return 1 ;;
  esac
}
remove_runner() { printf 'remove %s\n' "$*" >> "$MUTATIONS"; return 1; }
provider_stop_container() { printf 'stop %s\n' "$*" >> "$MUTATIONS"; return 1; }
# Like the real start_one, an existing slot is skipped.
start_one() {
  case " $EXISTING " in *" $NAME_PREFIX-$1 "*) return 0 ;; esac
  printf '%s-%s\n' "$NAME_PREFIX" "$1" >> "$STARTS"
}
starts() { tr '\n' ' ' < "$STARTS" | sed 's/ $//'; }

# Pool growth: min 2, idle 2, two busy runners -> target 4.
RUNNER_POOLS='v3|build|general-build|unraid,build|2|2|8|2|4|16g|builtin'
EXISTING='ci-runner-build-1 ci-runner-build-2'
# Pool growth reads only this host's runners. Every host sees the same org
# queue, so a queue-driven target would grow each host for the same jobs.
printf 'github %s 50\n' "$(date +%s)" > "$RUNDIR/queued.cache"
[ "$(pool_start_target build)" = 4 ] || fail "pool growth read the shared provider queue"
rm -f "$RUNDIR/queued.cache"
set_host 95 80; : > "$STARTS"
start_configured_capacity >>"$LOG" || fail "withheld growth reported a start failure"
[ ! -s "$STARTS" ] || fail "CPU-hot pool grew: $(starts)"
set_host 10 80; : > "$STARTS"
start_configured_capacity >>"$LOG" || fail "admitted growth failed"
[ "$(starts)" = 'ci-runner-build-3 ci-runner-build-4' ] || fail "pool with headroom did not grow: $(starts)"
# Pacing caps one tick at two gated starts (target 6 here).
RUNNER_POOLS='v3|build|general-build|unraid,build|2|2|8|4|4|16g|builtin'
set_host 10 200; : > "$STARTS"
start_configured_capacity >>"$LOG"
[ "$(starts)" = 'ci-runner-build-3 ci-runner-build-4' ] || fail "one tick admitted more than two gated starts: $(starts)"
# Refill to the minimum while metrics are unreadable; growth stays withheld.
RUNNER_POOLS='v3|build|general-build|unraid,build|3|3|8|3|4|16g|builtin'
EXISTING='ci-runner-build-3 ci-runner-build-4'
set_host 10 80; rm -f "$PROC/stat"; : > "$STARTS"
start_configured_capacity >>"$LOG"
[ "$(starts)" = 'ci-runner-build-1 ci-runner-build-2' ] || fail "refill below the minimum was gated or growth escaped: $(starts)"
# With backpressure off, growth is exactly the existing behavior.
GROWTH_BACKPRESSURE=false; : > "$STARTS"
start_configured_capacity >>"$LOG"
[ "$(starts)" = 'ci-runner-build-1 ci-runner-build-2 ci-runner-build-5' ] || fail "disabled gate changed pool growth: $(starts)"
GROWTH_BACKPRESSURE=true
# An idle target of 0 counts as 1, so such a pool still grows to busy + 1.
RUNNER_POOLS='v3|build|general-build|unraid,build|2|2|8|0|4|16g|builtin'
EXISTING='ci-runner-build-1 ci-runner-build-2'
[ "$(pool_start_target build)" = 3 ] || fail "a pool with idle=0 does not grow to busy + 1"

# Stopped slots: above the floor they stay stopped (never removed) until admitted.
RUNNER_POOLS='v3|build|general-build|unraid,build|2|2|8|1|4|16g|builtin'
EXISTING='ci-runner-build-1 ci-runner-build-5'; STOPPED='ci-runner-build-1 ci-runner-build-5'
recreate_stopped_runner() { printf '%s\n' "$1" >> "$STARTS"; }
set_host 95 80; : > "$STARTS"
start_stopped_managed >>"$LOG" || fail "withheld stopped slot reported failure"
[ "$(starts)" = 'ci-runner-build-1' ] || fail "stopped slot above the floor was recreated while CPU-hot: $(starts)"
set_host 10 80; : > "$STARTS"
start_stopped_managed >>"$LOG"
[ "$(starts)" = 'ci-runner-build-1 ci-runner-build-5' ] || fail "admitted stopped slot was not recreated: $(starts)"
STOPPED=""

# Lifecycle refill of an exited ephemeral slot: checked before any removal.
github_runner_exited() { return 0; }
cmd_recycle() { printf '%s\n' "$1" >> "$STARTS"; }
EXISTING='ci-runner-build-1 ci-runner-build-5'
set_host 95 80; : > "$STARTS"
lifecycle_replace ci-runner-build-5 >>"$LOG" || fail "withheld lifecycle refill reported failure"
lifecycle_replace ci-runner-build-1 >>"$LOG" || fail "floor lifecycle refill failed"
[ "$(starts)" = 'ci-runner-build-1' ] || fail "lifecycle refilled above the floor while CPU-hot: $(starts)"
set_host 10 80; : > "$STARTS"
lifecycle_replace ci-runner-build-5 >>"$LOG"
[ "$(starts)" = 'ci-runner-build-5' ] || fail "admitted lifecycle refill did not run: $(starts)"

# Stale-config reconcile: a stopped stale slot above the floor is started again
# only when admitted; replacing a running stale runner is not growth.
reload_locked_snapshot() { :; }
runner_state() { printf 'idle\n'; }
expected_runner_confgen() { printf 'new\n'; }
RUNNER_POOLS='v3|build|general-build|unraid,build|2|2|8|1|4|16g|builtin'
EXISTING='ci-runner-build-5 ci-runner-build-6'; STOPPED='ci-runner-build-5'
set_host 95 80; : > "$STARTS"
reconcile_stale_runners >>"$LOG" || fail "reconcile failed while withholding"
[ "$(starts)" = 'ci-runner-build-6' ] || fail "reconcile restarted a withheld stopped slot: $(starts)"
set_host 10 80; : > "$STARTS"
reconcile_stale_runners >>"$LOG"
[ "$(starts)" = 'ci-runner-build-5' ] || fail "reconcile did not restart an admitted stopped slot: $(starts)"
# Image-update drain: same rule for a stopped slot.
runner_busy() { return 1; }
set_host 95 80; : > "$STARTS"
if drain_and_recreate ci-runner-build-5 >>"$LOG"; then fail "image drain restarted a withheld stopped slot"; fi
[ ! -s "$STARTS" ] || fail "image drain recycled a withheld stopped slot: $(starts)"
set_host 10 80; : > "$STARTS"
drain_and_recreate ci-runner-build-5 >>"$LOG" || fail "admitted image drain failed"
[ "$(starts)" = 'ci-runner-build-5' ] || fail "image drain did not recycle an admitted stopped slot"
expected_runner_confgen() { printf 'gen\n'; }

# A whole pool-mode autoscale tick under pressure: ephemeral slots above the
# minimum that exit stay exited (never removed), the minimum is refilled, and
# the pool returns to size once the host has headroom.
crf_storage_pressure_cleanup() { :; }
EXISTING='ci-runner-build-1 ci-runner-build-2 ci-runner-build-3 ci-runner-build-4 ci-runner-build-5'
STOPPED='ci-runner-build-2 ci-runner-build-4 ci-runner-build-5'
set_host 95 80; : > "$STARTS"
autoscale_tick >>"$LOG" || fail "pool autoscale tick failed under pressure"
[ "$(starts)" = 'ci-runner-build-2' ] || fail "pressured pool tick restarted slots above the minimum: $(starts)"
set_host 10 200; : > "$STARTS"
autoscale_tick >>"$LOG"
[ "$(starts)" = 'ci-runner-build-2 ci-runner-build-4 ci-runner-build-5' ] \
  || fail "pool did not refill exited slots once the host had headroom: $(starts)"
# One tick shares its two gated starts between restarts and new slots.
RUNNER_POOLS='v3|build|general-build|unraid,build|2|2|8|3|4|16g|builtin'
EXISTING='ci-runner-build-1 ci-runner-build-2 ci-runner-build-3 ci-runner-build-4'; STOPPED='ci-runner-build-4'
set_host 10 200; : > "$STARTS"
autoscale_tick >>"$LOG"
[ "$(starts)" = 'ci-runner-build-4 ci-runner-build-5' ] || fail "one tick exceeded two gated starts: $(starts)"
STOPPED=""

# Single-layout autoscale tick: growth above the floor is gated, the floor is not.
RUNNER_MODE=single AUTOSCALE_MIN=2 AUTOSCALE_MAX=16 AUTOSCALE_MIN_IDLE=2 AUTOSCALE_STEP=4 AUTOSCALE_IDLE_GRACE=5
reap_dead_runners() { :; }
heal_poisoned_runners() { :; }
reconcile_stale_runners() { :; }
fleet_cur=4
provider_call() { [ "$1" = autoscale_counts ] || return 1; cur="$fleet_cur"; busy="$fleet_cur"; idle=0; }
cmd_scale() { printf 'scale %s\n' "$1" >> "$STARTS"; }
tick() { set_host "$1" "$2"; [ "${3:-}" != broken ] || rm -f "$PROC/stat"; : > "$STARTS"; autoscale_tick >>"$LOG" || fail "autoscale tick failed"; }
tick 95 80
[ ! -s "$STARTS" ] || fail "single-layout autoscale grew while CPU-hot: $(starts)"
tick 10 80
[ "$(starts)" = 'scale 6' ] || fail "single-layout growth was not paced to two starts: $(starts)"
tick 10 30
[ "$(starts)" = 'scale 5' ] || fail "single-layout growth ignored the memory budget: $(starts)"
fleet_cur=1
tick 10 80 broken
[ "$(starts)" = 'scale 2' ] || fail "single-layout floor refill was gated: $(starts)"
GROWTH_BACKPRESSURE=false fleet_cur=4
: > "$STARTS"; autoscale_tick >>"$LOG"
[ "$(starts)" = 'scale 8' ] || fail "disabled gate changed single-layout growth: $(starts)"
GROWTH_BACKPRESSURE=true
RUNNER_MODE=pools

# ---- published growth state ------------------------------------------------------
# Each autoscale tick publishes per-pool growth state for a node_exporter
# textfile collector; stopping autoscale publishes that it stopped.
PROM="$RUNDIR/metrics/ci-runner-farm.prom"
[ "$(CRF_RUNDIR='' CRF_GROWTH_METRICS_DIR='' bash -c '. src/usr/local/emhttp/plugins/ci-runner-farm/include/growth-backpressure.sh 2>/dev/null; printf %s "$GROWTH_METRICS_DIR"')" \
  = /var/run/ci-runner-farm-metrics ] || fail "the default metrics directory changed"
metric() { awk -v key="$1" 'index($0, key " ") == 1 { print $2; found=1 } END { exit !found }' "$PROM"; }
prom_valid() {
  local line
  while IFS= read -r line; do
    case "$line" in
      '# HELP ci_runner_farm_'*|'# TYPE ci_runner_farm_'*' gauge') ;;
      *) [[ "$line" =~ ^ci_runner_farm_[a-z_]+(\{[a-z_]+=\"[a-z0-9-]*\"(,[a-z_]+=\"[a-z0-9_-]*\")*\})?\ [0-9]+$ ]] \
           || fail "invalid exposition line: $line" ;;
    esac
  done < "$PROM"
}
RUNNER_POOLS='v3|build|general-build|unraid,build|2|2|8|1|4|16g|builtin'
EXISTING='ci-runner-build-1 ci-runner-build-2 ci-runner-build-3 ci-runner-build-4 ci-runner-build-5'
STOPPED='ci-runner-build-4 ci-runner-build-5'
# A manual check while the daemon is not running still reads as stopped.
rm -f "$AUTOSCALE_PID"
set_host 95 80; autoscale_tick >>"$LOG"
[ "$(metric 'ci_runner_farm_autoscale_running')" = 0 ] || fail "a check without the daemon published autoscale running"
printf '%s\n' "$$" > "$AUTOSCALE_PID"   # the daemon runs ticks; its pid is live
set_host 95 80; : > "$STARTS"
autoscale_tick >>"$LOG" || fail "tick failed while publishing growth state"
prom_valid
[ "$(metric 'ci_runner_farm_autoscale_interval_seconds')" = "$AUTOSCALE_INTERVAL" ] || fail "check interval not published"
[ "$(metric 'ci_runner_farm_autoscale_running')" = 1 ] && [ "$(metric 'ci_runner_farm_autoscale_enabled')" = 1 ] \
  || fail "running tick did not publish autoscale running"
[ "$(metric 'ci_runner_farm_pool_runners{pool="build"}')" = 3 ] || fail "running count is not the running slots: $(cat "$PROM")"
[ "$(metric 'ci_runner_farm_pool_min{pool="build"}')" = 2 ] && [ "$(metric 'ci_runner_farm_pool_max{pool="build"}')" = 8 ] \
  || fail "pool bounds missing: $(cat "$PROM")"
withheld_since="$(metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="build",state="withheld",reason="cpu"}')" \
  || fail "CPU-hot pool was not published as withheld for CPU: $(cat "$PROM")"
[ "$(stat -c %a "$PROM" 2>/dev/null || stat -f %Lp "$PROM")" = 644 ] \
  && [ "$(stat -c %a "$RUNDIR/metrics" 2>/dev/null || stat -f %Lp "$RUNDIR/metrics")" = 755 ] \
  || fail "metrics file is not readable by an unprivileged collector"
# The same state keeps the time it began.
sed -i.bak "s/|withheld:cpu|.*/|withheld:cpu|1000/" "$RUNDIR/metrics/.growth-pools.state"
set_host 95 80; autoscale_tick >>"$LOG"
[ "$(metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="build",state="withheld",reason="cpu"}')" = 1000 ] \
  || fail "an unchanged state restarted its clock: $(cat "$PROM")"
set_host 10 30; autoscale_tick >>"$LOG"
metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="build",state="withheld",reason="memory"}' >/dev/null \
  || fail "memory withhold was not published: $(cat "$PROM")"
set_host 10 200; autoscale_tick >>"$LOG"
grow_since="$(metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="build",state="growing"}')" \
  || fail "admitted pool was not published as growing: $(cat "$PROM")"
[ "$grow_since" -ge "$withheld_since" ] || fail "a new state kept the old start time"
if grep -q 'withheld' "$PROM"; then fail "a pool kept a stale withheld line: $(cat "$PROM")"; fi
STOPPED=''
EXISTING="$(printf 'ci-runner-build-%s ' 1 2 3 4 5 6 7 8)"
set_host 95 80; autoscale_tick >>"$LOG"
metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="build",state="at_max"}' >/dev/null \
  || fail "full pool was not published at its max: $(cat "$PROM")"
EXISTING='ci-runner-build-1 ci-runner-build-2'
saved_target="$(declare -f pool_start_target)"
pool_start_target() { printf '2\n'; }
set_host 95 80; autoscale_tick >>"$LOG"
metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="build",state="steady"}' >/dev/null \
  || fail "pool without demand was not published as steady: $(cat "$PROM")"
eval "$saved_target"
# A pool the check cannot prepare is published, not dropped.
saved_target="$(declare -f pool_start_target)"
pool_start_target() { return 1; }
set_host 10 200; autoscale_tick >>"$LOG" || true
metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="build",state="withheld",reason="pool-setup"}' >/dev/null \
  || fail "a pool that failed setup was not published: $(cat "$PROM")"
eval "$saved_target"
# Stopping autoscale (a drain before a reboot does this) publishes it stopped.
stop_worker_group() { :; }
autoscale_stop || fail "autoscale_stop failed"
[ "$(metric 'ci_runner_farm_autoscale_running')" = 0 ] || fail "stop did not publish autoscale stopped"
if grep -q 'pool=' "$PROM"; then fail "stopped autoscale kept pool states: $(cat "$PROM")"; fi
prom_valid
stop_worker_group() { return 1; }
if autoscale_stop; then fail "a failed stop reported success"; fi
# The daemon exiting because autoscale was turned off publishes it stopped.
set_host 10 200; autoscale_tick >>"$LOG"
( load_cfg() { AUTOSCALE=false; }; reload_secret_files() { :; }; autoscale_daemon ) >>"$LOG" 2>&1
[ "$(metric 'ci_runner_farm_autoscale_running')" = 0 ] && [ "$(metric 'ci_runner_farm_autoscale_enabled')" = 0 ] \
  || fail "a daemon that exited for disabled autoscale did not publish it: $(cat "$PROM")"
# A write failure never fails a tick.
rm -rf "$RUNDIR/metrics"; : > "$RUNDIR/metrics"
set_host 10 200; autoscale_tick >>"$LOG" || fail "an unwritable metrics directory failed the tick"
rm -f "$RUNDIR/metrics"
# Nothing is ever written to flash.
GROWTH_METRICS_DIR="$CFGDIR/metrics" GROWTH_POOLS_STATE="$CFGDIR/metrics/.growth-pools.state"
growth_state_publish; growth_state_publish_stopped
[ ! -e "$CFGDIR/metrics" ] || fail "growth state was written to flash"
GROWTH_METRICS_DIR="$RUNDIR/metrics" GROWTH_POOLS_STATE="$RUNDIR/metrics/.growth-pools.state"
# The per-pool state file stays in RAM even when the runtime directory fell back to flash.
saved_rundir="$RUNDIR"; RUNDIR="$CFGDIR"
set_host 95 80; autoscale_tick >>"$LOG"
[ -s "$saved_rundir/metrics/.growth-pools.state" ] && [ ! -e "$CFGDIR/growth-pools.state" ] \
  || fail "the per-pool state file followed the runtime directory onto flash"
RUNDIR="$saved_rundir"
# Single layout publishes one default pool bounded by the autoscale settings.
RUNNER_MODE=single fleet_cur=16
saved_provider="$(declare -f provider_call)"
provider_call() { [ "$1" = autoscale_counts ] || return 1; cur="$fleet_cur"; busy="$fleet_cur"; idle=0; }
reap_dead_runners() { :; }
set_host 10 80; : > "$STARTS"; autoscale_tick >>"$LOG"
[ "$(metric 'ci_runner_farm_pool_max{pool="default"}')" = 16 ] \
  && metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="default",state="at_max"}' >/dev/null \
  || fail "single layout did not publish its default pool at max: $(cat "$PROM")"
fleet_cur=4; set_host 95 80; autoscale_tick >>"$LOG"
metric 'ci_runner_farm_pool_growth_since_timestamp_seconds{pool="default",state="withheld",reason="cpu"}' >/dev/null \
  || fail "single layout did not publish its withheld growth: $(cat "$PROM")"
eval "$saved_provider"
RUNNER_MODE=pools STOPPED=''

# Status shows host pressure whenever the kernel exposes it and autoscale is on.
psi cpu 35.20 0.00; psi memory 0.00 0.00; psi io 1.40 0.05
saved_existing="$EXISTING"; EXISTING=''
pressure_line='host pressure: cpu some 35.20%, memory some 0.00% full 0.00%, io some 1.40% (avg10)'
status_out="$(cmd_status 2>/dev/null)"
grep -qxF "$pressure_line" <<< "$status_out" || fail "status does not show host pressure"
grep -qF "; $pressure_line" <<< "$(cmd_status_json 2>/dev/null)" || fail "status JSON does not show host pressure"
status_out="$(AUTOSCALE=false cmd_status 2>/dev/null)"
grep -q '^NAME ' <<< "$status_out" || fail "status without autoscale did not render"
if grep -q 'host pressure' <<< "$status_out"; then fail "status showed host pressure without autoscale"; fi
rm -rf "$PROC/pressure"
status_out="$(cmd_status 2>/dev/null)"
grep -q '^NAME ' <<< "$status_out" || fail "status without pressure data did not render"
if grep -q 'host pressure' <<< "$status_out"; then fail "status showed host pressure without pressure data"; fi
EXISTING="$saved_existing"

[ ! -s "$MUTATIONS" ] || fail "the gate stopped, removed, or mutated runners: $(cat "$MUTATIONS")"

# ---- configuration ---------------------------------------------------------------------
printf '%s\n' 'GROWTH_BACKPRESSURE="true"' 'GROWTH_CPU_CEILING="70"' 'GROWTH_MEMORY_RESERVE="4g"' > "$CFG"
load_cfg
[ "$GROWTH_BACKPRESSURE" = true ] && [ "$GROWTH_CPU_CEILING" = 70 ] && [ "$GROWTH_MEMORY_RESERVE" = 4g ] \
  || fail "settings did not load through the allowlist"
# shellcheck disable=SC2016  # the literal command substitution is the hostile value
printf '%s\n' 'GROWTH_CPU_CEILING="$(id)"' > "$CFG"
load_cfg 2>/dev/null
[ "$GROWTH_CPU_CEILING" = 70 ] || fail "a non-numeric CPU ceiling replaced the previous value"
[ "$GROWTH_BACKPRESSURE" = false ] || fail "an omitted toggle did not turn backpressure off"
rm -f "$CFG"

# The settings are live: they never enter the runner fingerprint.
unset -f docker
docker() { return 1; }
provider_call() { "${CI_PROVIDER}_$1" "${@:2}"; }
CACHE_ROOT="$tmp/cache"; CACHE_MOUNTS=''; USER_SHARE_MOUNTS=''
GH_OWNER='example-owner'; GH_REPOS=''; RUNNER_GROUP=''
host() { printf 'mockhost\n'; }
runner_host_service_ipv4() { printf '192.0.2.10\n'; }
github_kvm_gid() { return 1; }
pool_activate build
GROWTH_BACKPRESSURE=false
off_confgen="$(crf_confgen)"
[ -n "$off_confgen" ] || fail "fingerprint is empty"
GROWTH_BACKPRESSURE=true GROWTH_CPU_CEILING=50 GROWTH_MEMORY_RESERVE=1g
[ "$(crf_confgen)" = "$off_confgen" ] || fail "backpressure settings changed the runner fingerprint"

echo "growth-backpressure: OK — thresholds, memory budget, pacing, floor refills, fail-safe metrics, log-once, start paths, published growth state, no mutations, fingerprint"
