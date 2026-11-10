#!/bin/bash
# Opt-in resource backpressure for runner growth (GROWTH_BACKPRESSURE=true).
#
# Autoscaled fleets grow from their minimum toward their maximum on demand. A
# fixed slot count can leave a host underused while jobs queue, but growth past
# the minimum must not push the host into CPU or memory exhaustion. This gate
# checks live host resources before each start that would take a slot above
# the minimum:
#   * host CPU busy percent must not be above GROWTH_CPU_CEILING;
#   * MemAvailable must stay at or above the runner's memory limit plus
#     GROWTH_MEMORY_RESERVE. Each start admitted in a tick deducts its memory
#     limit, because a new runner does not reduce MemAvailable until it works.
#   * With CPU_PINNING on (GitHub runners), the CPU block the new runner would
#     get must not already be busy: its occupants' measured CPU use, plus half
#     the use on its SMT sibling CPUs, must stay below GROWTH_BLOCK_CORES_LIMIT
#     (3 cores, about 75% of a 4-CPU block, so a new runner still gets about a
#     core). Busy runners average about 1.8 cores, so a lower limit withholds
#     growth on most blocks while the host is far from its CPU ceiling.
#     Runners started since the last usage sample count as fully busy. Without
#     a measured pinned runner this check is skipped. At most one start per
#     tick passes this check, because the next preview cannot see a runner
#     that is not created yet.
#   * When the kernel exposes pressure stall information, memory pressure
#     (avg10) must stay at or below 5% "full" and 20% "some". This is a safety
#     net beside MemAvailable; without /proc/pressure it is skipped.
#   * At most GROWTH_STARTS_PER_TICK gated starts are admitted per tick, because
#     a new runner's CPU use is not visible until its next job runs.
#
# The gate only withholds starts. It never stops, drains, or removes a runner,
# and a start that refills a slot up to the minimum is never checked. When the
# metrics cannot be read, it withholds growth (refills continue). Decisions are
# logged only when the state changes, and the latest decision is kept in
# $RUNDIR/growth-gate.state for status output.
#
# Every tick runs in its own process (with_fleet_lock subshell or CLI call), so
# the per-tick sample and counters below are process-local. Ticks also call
# growth_gate_reset explicitly.
#
# Safe to source from tests. Callers provide log(), RUNDIR, pool_mode_enabled,
# pool_min, pool_memory, pool_cpus, autoscale_floor, BASE_RUNNER_MEMORY,
# BASE_RUNNER_CPUS, CPU_PINNING, CI_PROVIDER and crf_cpu_pinning_choose.
# CRF_PROC_ROOT (default /proc) lets tests supply fake proc files.

GROWTH_STARTS_PER_TICK="${CRF_GROWTH_STARTS_PER_TICK:-2}"  # internal pacing, not web-settable
GROWTH_CPU_WINDOW="${CRF_GROWTH_CPU_WINDOW:-2}"            # seconds for a fresh CPU sample
GROWTH_CPU_SAMPLE_MAX_AGE=300                              # older stored samples are not reused
GROWTH_BLOCK_CORES_LIMIT=3000                              # thousandths of a core, pinned hosts
GROWTH_MEMORY_PRESSURE_FULL_LIMIT=500                      # hundredths of a percent (5%)
GROWTH_MEMORY_PRESSURE_SOME_LIMIT=2000                     # hundredths of a percent (20%)

growth_gate_reset() {
  GROWTH_SAMPLED=false
  GROWTH_CPU_PCT=""
  GROWTH_MEM_AVAIL=""
  GROWTH_ADMITTED=0
  GROWTH_DEDUCTED=0
  GROWTH_MEM_PSI_SOME=""
  GROWTH_MEM_PSI_FULL=""
  GROWTH_BLOCK_BUSY=""
  GROWTH_BLOCK_ADMITTED=false
}
growth_gate_reset

growth_gate_enabled() { [ "${GROWTH_BACKPRESSURE:-false}" = true ]; }

growth_uint() { [[ "$1" =~ ^[0-9]{1,18}$ ]]; }

# Convert a Docker-style size (16g, 1.5g, 512m, 8gib, 0) to bytes. Units are
# binary, as Docker treats them. Sizes above 1 PiB are rejected so the
# arithmetic cannot overflow into a value that disables the memory check.
growth_size_bytes() {
  local value whole frac unit mult bytes
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" =~ ^([0-9]{1,16})(\.([0-9]{1,3}))?(b|k|kb|ki|kib|m|mb|mi|mib|g|gb|gi|gib|t|tb|ti|tib)?$ ]] || return 1
  whole="$((10#${BASH_REMATCH[1]}))"; frac="${BASH_REMATCH[3]}"; unit="${BASH_REMATCH[4]}"
  case "$unit" in
    ''|b) mult=1 ;;
    k*) mult=1024 ;;
    m*) mult=1048576 ;;
    g*) mult=1073741824 ;;
    t*) mult=1099511627776 ;;
  esac
  [ "$whole" -le $(( 1125899906842624 / mult )) ] || return 1
  bytes=$(( whole * mult ))
  [ -z "$frac" ] || bytes=$(( bytes + 10#$frac * mult / 10 ** ${#frac} ))
  [ "$bytes" -le 1125899906842624 ] || return 1
  printf '%s\n' "$bytes"
}

# Print "total idle" jiffies from the aggregate cpu line of /proc/stat. Idle
# includes iowait; steal counts as busy.
growth_proc_cpu_jiffies() {
  local file="${CRF_PROC_ROOT:-/proc}/stat" label user nice system idle iowait irq softirq steal field
  [ -r "$file" ] || return 1
  read -r label user nice system idle iowait irq softirq steal _ < "$file" || return 1
  [ "$label" = cpu ] || return 1
  for field in "$user" "$nice" "$system" "$idle" "$iowait" "$irq" "$softirq" "$steal"; do
    growth_uint "$field" || return 1
  done
  printf '%s %s\n' \
    "$(( 10#$user + 10#$nice + 10#$system + 10#$idle + 10#$iowait + 10#$irq + 10#$softirq + 10#$steal ))" \
    "$(( 10#$idle + 10#$iowait ))"
}

# Host CPU busy percent over the time since the previous stored sample (the
# previous tick), or over a fresh GROWTH_CPU_WINDOW when that sample is
# missing, too recent, or too old. Stores the current reading for the next tick.
growth_cpu_busy_percent() {
  local sample="$RUNDIR/growth-cpu.sample" cur total idle now prev_ts="" prev_total="" prev_idle="" window dt di
  cur="$(growth_proc_cpu_jiffies)" || return 1
  read -r total idle <<< "$cur"
  now="$(date +%s)"
  if [ -f "$sample" ]; then read -r prev_ts prev_total prev_idle _ < "$sample" 2>/dev/null || true; fi
  window=-1
  if growth_uint "$prev_ts" && growth_uint "$prev_total" && growth_uint "$prev_idle"; then
    window=$(( now - prev_ts ))
  fi
  if [ "$window" -lt "$GROWTH_CPU_WINDOW" ] || [ "$window" -gt "$GROWTH_CPU_SAMPLE_MAX_AGE" ] \
    || [ "$total" -le "$prev_total" ]; then
    prev_total="$total"; prev_idle="$idle"
    sleep "$GROWTH_CPU_WINDOW"
    cur="$(growth_proc_cpu_jiffies)" || return 1
    read -r total idle <<< "$cur"
    now="$(date +%s)"
  fi
  dt=$(( total - prev_total )); di=$(( idle - prev_idle ))
  [ "$dt" -gt 0 ] && [ "$di" -ge 0 ] && [ "$di" -le "$dt" ] || return 1
  ( umask 077; printf '%s %s %s\n' "$now" "$total" "$idle" > "$sample.tmp.$$" \
    && mv -f "$sample.tmp.$$" "$sample" ) 2>/dev/null || rm -f "$sample.tmp.$$" 2>/dev/null
  printf '%s\n' "$(( ((dt - di) * 100 + dt / 2) / dt ))"
}

growth_mem_available_bytes() {
  local file="${CRF_PROC_ROOT:-/proc}/meminfo" kib
  [ -r "$file" ] || return 1
  kib="$(awk '$1 == "MemAvailable:" && $3 == "kB" { print $2; exit }' "$file" 2>/dev/null)"
  growth_uint "$kib" || return 1
  printf '%s\n' "$(( 10#$kib * 1024 ))"
}

# Print the avg10 value of pressure line <some|full> in /proc/pressure/<resource>
# as hundredths of a percent. Fails when the kernel exposes no pressure data.
growth_psi_avg10() {
  local file="${CRF_PROC_ROOT:-/proc}/pressure/$1" value
  [ -r "$file" ] || return 1
  value="$(awk -v kind="$2" '$1 == kind {
      for (i = 2; i <= NF; i++) if ($i ~ /^avg10=[0-9]+(\.[0-9]+)?$/) { split($i, a, "="); printf "%d", a[2] * 100 + 0.5; exit }
    }' "$file" 2>/dev/null)"
  growth_uint "$value" || return 1
  printf '%s\n' "$value"
}

growth_pct() { printf '%d.%02d%%' "$(( $1 / 100 ))" "$(( $1 % 100 ))"; }
growth_pct_or_dash() { if growth_uint "$1"; then growth_pct "$1"; else printf -- '-'; fi; }

# One line of host pressure (avg10) for status output; fails without PSI.
growth_psi_summary() {
  local cpu mem_some mem_full io
  cpu="$(growth_psi_avg10 cpu some)" || return 1
  mem_some="$(growth_psi_avg10 memory some)" || return 1
  mem_full="$(growth_psi_avg10 memory full)" || return 1
  io="$(growth_psi_avg10 io some)" || return 1
  printf 'cpu some %s, memory some %s full %s, io some %s (avg10)\n' \
    "$(growth_pct "$cpu")" "$(growth_pct "$mem_some")" "$(growth_pct "$mem_full")" "$(growth_pct "$io")"
}

# The host CPU and memory source for the gate: prints "cpu_busy_percent
# mem_available_bytes", or fails when either cannot be read.
growth_host_metrics() {
  local cpu mem
  cpu="$(growth_cpu_busy_percent)" || return 1
  mem="$(growth_mem_available_bytes)" || return 1
  printf '%s %s\n' "$cpu" "$mem"
}

# The highest slot index that is a refill, not growth. Fails when the fleet
# does not grow at all (AUTOSCALE off: capacity is fixed).
growth_floor() {
  [ "${AUTOSCALE:-false}" = true ] || return 1
  if pool_mode_enabled && [ "$1" != default ]; then pool_min "$1"; else autoscale_floor; fi
}

growth_runner_memory_bytes() {
  local memory="$BASE_RUNNER_MEMORY"
  if pool_mode_enabled && [ "$1" != default ]; then
    memory="$(pool_memory "$1")" || return 1
    [ "$memory" != inherit ] || memory="$BASE_RUNNER_MEMORY"
  fi
  [ -n "$memory" ] || { printf '0\n'; return 0; }
  growth_size_bytes "$memory"
}

growth_mib() { printf '%s' "$(( $1 / 1048576 ))"; }

# The CPU limit a new runner in <pool> gets, as configured (may be empty).
growth_runner_cpus() {
  local cpus="$BASE_RUNNER_CPUS"
  if pool_mode_enabled && [ "$1" != default ]; then
    cpus="$(pool_cpus "$1")" || return 1
    [ "$cpus" != inherit ] || cpus="$BASE_RUNNER_CPUS"
  fi
  printf '%s\n' "$cpus"
}

growth_cores() { printf '%d.%02d' "$(( $1 / 1000 ))" "$(( $1 % 1000 / 10 ))"; }

# Record a decision and log it when its state differs from the previous one.
growth_gate_record() {
  local key="$1" target="$2" detail="$3" file="$RUNDIR/growth-gate.state" previous=""
  if [ -f "$file" ]; then IFS='|' read -r previous _ < "$file" 2>/dev/null || true; fi
  ( umask 077; printf '%s|%s|%s\n' "$key" "$(date +%s)" "$detail" > "$file.tmp.$$" \
    && mv -f "$file.tmp.$$" "$file" ) 2>/dev/null || rm -f "$file.tmp.$$" 2>/dev/null
  [ "$previous" = "$key" ] || log "growth backpressure: ${key%%:*} $target: $detail"
}

# Return 0 when the farm may start slot <idx> of <pool> now. Starts that are
# not growth (gate off, AUTOSCALE off, or idx at or below the floor) always
# pass. <label> names the slot in the log.
growth_gate_admit() {
  local pool="$1" idx="$2" label="${3:-slot $2}" floor ceiling reserve runner need avail cpu metrics numbers
  local cpus choice block block_use measured
  growth_gate_enabled || return 0
  floor="$(growth_floor "$pool")" || return 0
  growth_uint "$floor" || floor=0
  [ "$idx" -le "$floor" ] && return 0
  # Pacing within one tick is not a state change and is not logged.
  [ "$GROWTH_ADMITTED" -lt "$GROWTH_STARTS_PER_TICK" ] || return 1
  ceiling="${GROWTH_CPU_CEILING:-}"
  if ! growth_uint "$ceiling" || [ "$ceiling" -lt 1 ] || [ "$ceiling" -gt 100 ] \
    || ! reserve="$(growth_size_bytes "${GROWTH_MEMORY_RESERVE:-}")" \
    || ! runner="$(growth_runner_memory_bytes "$pool")"; then
    growth_gate_record withheld:settings "$label" "the CPU ceiling, memory reserve, or runner memory limit is invalid"
    return 1
  fi
  if [ "$GROWTH_SAMPLED" != true ]; then
    GROWTH_SAMPLED=true
    if metrics="$(growth_host_metrics)"; then
      read -r GROWTH_CPU_PCT GROWTH_MEM_AVAIL <<< "$metrics"
    fi
    GROWTH_MEM_PSI_SOME="$(growth_psi_avg10 memory some 2>/dev/null)" || GROWTH_MEM_PSI_SOME=""
    GROWTH_MEM_PSI_FULL="$(growth_psi_avg10 memory full 2>/dev/null)" || GROWTH_MEM_PSI_FULL=""
  fi
  if ! growth_uint "$GROWTH_CPU_PCT" || ! growth_uint "$GROWTH_MEM_AVAIL"; then
    growth_gate_record withheld:metrics "$label" "host CPU or memory metrics are unreadable"
    return 1
  fi
  cpu="$GROWTH_CPU_PCT"
  avail=$(( GROWTH_MEM_AVAIL - GROWTH_DEDUCTED ))
  need=$(( runner + reserve ))
  numbers="cpu ${cpu}% (ceiling ${ceiling}%), MemAvailable $(growth_mib "$avail") MiB (need $(growth_mib "$runner") + reserve $(growth_mib "$reserve") MiB)"
  if [ "$cpu" -gt "$ceiling" ]; then
    growth_gate_record withheld:cpu "$label" "$numbers"
    return 1
  fi
  if [ "$avail" -lt "$need" ]; then
    growth_gate_record withheld:memory "$label" "$numbers"
    return 1
  fi
  if growth_uint "$GROWTH_MEM_PSI_SOME" || growth_uint "$GROWTH_MEM_PSI_FULL"; then
    numbers+=", memory pressure some $(growth_pct_or_dash "$GROWTH_MEM_PSI_SOME") full $(growth_pct_or_dash "$GROWTH_MEM_PSI_FULL") (limits $(growth_pct "$GROWTH_MEMORY_PRESSURE_SOME_LIMIT") / $(growth_pct "$GROWTH_MEMORY_PRESSURE_FULL_LIMIT"))"
    if { growth_uint "$GROWTH_MEM_PSI_FULL" && [ "$GROWTH_MEM_PSI_FULL" -gt "$GROWTH_MEMORY_PRESSURE_FULL_LIMIT" ]; } \
      || { growth_uint "$GROWTH_MEM_PSI_SOME" && [ "$GROWTH_MEM_PSI_SOME" -gt "$GROWTH_MEMORY_PRESSURE_SOME_LIMIT" ]; }; then
      growth_gate_record withheld:memory-pressure "$label" "$numbers"
      return 1
    fi
  fi
  # Under pinning, host CPU busy understates contention: a new runner shares
  # the block placement would give it. Check that block's measured load last,
  # because previewing placement is the most expensive check.
  if [ "${CPU_PINNING:-false}" = true ] && [ "${CI_PROVIDER:-github}" = github ] \
    && cpus="$(growth_runner_cpus "$pool")" && [[ "$cpus" =~ ^[1-9][0-9]{0,3}$ ]]; then
    # A start admitted on a measured block is not visible to the next preview
    # until its container exists, so admit one such start per tick. Later
    # starts in the tick wait quietly, like pacing.
    [ "$GROWTH_BLOCK_ADMITTED" != true ] || return 1
    # Starts within a tick only add load, so a busy verdict holds for the tick.
    case " $GROWTH_BLOCK_BUSY " in
      *" $cpus "*)
        growth_gate_record withheld:cpu-block "$label" "$numbers, CPU block busy (checked earlier in this tick)"
        return 1 ;;
    esac
    if choice="$(crf_cpu_pinning_choose "$cpus" "$label" 2>/dev/null)"; then
      read -r block block_use measured <<< "$choice"
      if [ "$measured" = 1 ] && growth_uint "$block_use"; then
        numbers+=", CPU block $block in use $(growth_cores "$block_use") cores (limit $(growth_cores "$GROWTH_BLOCK_CORES_LIMIT"))"
        if [ "$block_use" -ge "$GROWTH_BLOCK_CORES_LIMIT" ]; then
          GROWTH_BLOCK_BUSY+=" $cpus"
          growth_gate_record withheld:cpu-block "$label" "$numbers"
          return 1
        fi
        GROWTH_BLOCK_ADMITTED=true
      fi
    fi
  fi
  GROWTH_ADMITTED=$(( GROWTH_ADMITTED + 1 ))
  GROWTH_DEDUCTED=$(( GROWTH_DEDUCTED + runner ))
  growth_gate_record admitted "$label" "$numbers"
  return 0
}

# One-line gate state for status output.
growth_gate_status() {
  local key ts detail age
  growth_gate_enabled || { printf 'off\n'; return 0; }
  if [ -f "$RUNDIR/growth-gate.state" ] && IFS='|' read -r key ts detail < "$RUNDIR/growth-gate.state" \
    && growth_uint "$ts"; then
    age=$(( $(date +%s) - ts ))
    [ "$age" -ge 0 ] || age=0
    printf '%s %ss ago: %s\n' "${key%%:*}" "$age" "$detail"
  else
    printf 'on, no growth requested yet\n'
  fi
}
