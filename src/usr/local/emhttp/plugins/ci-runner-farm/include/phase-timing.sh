#!/bin/bash
# Phase timing: where fleet operations spend their time.
#
# Each timed operation (a recycle, a runner start, an autoscale or lifecycle
# tick, an exit-event batch, a fleet.lock hold) appends one line to
# $RUNDIR/timing.log:
#   ts=<epoch.ms> op=<operation> subject=<slot or caller> rc=<exit> total_ms=<n> <phase>_ms=<n> ...
# A phase is the time since the previous mark, so the phases of one line add
# up to its total. The file is kept under CRF_TIMING_MAX_BYTES by dropping its
# older half. It is observation only: a failure to time or to write never
# changes the operation.
#
# Use: a function declares `local _tm_start _tm_last _tm_parts`, calls
# crf_timing_begin, calls crf_timing_mark <phase> after each step, and ends
# with crf_timing_end <op> <subject> <rc>. Marks reach the nearest caller that
# declared these locals (Bash dynamic scope), so a helper such as
# github_build_args adds its phases to whichever operation called it. A mark
# with no timed caller does nothing.

CRF_TIMING_MAX_BYTES="${CRF_TIMING_MAX_BYTES:-4194304}"

# Set CRF_NOW_US to the current time in microseconds, without a fork when
# Bash provides EPOCHREALTIME.
crf_timing_now() {
  local t="${EPOCHREALTIME:-}"
  if [ -n "$t" ]; then
    CRF_NOW_US="${t/[.,]/}"
  else
    CRF_NOW_US="$(date +%s%6N 2>/dev/null)" || CRF_NOW_US=""
  fi
  [[ "$CRF_NOW_US" =~ ^[0-9]{10,20}$ ]] || CRF_NOW_US=""
}

# Milliseconds from microsecond time <from> to <to>, or nothing.
crf_timing_ms() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  printf '%s' "$(( ($2 - $1) / 1000 ))"
}

crf_timing_begin() {
  crf_timing_now
  _tm_start="$CRF_NOW_US"; _tm_last="$CRF_NOW_US"; _tm_parts=""
}

crf_timing_mark() {
  [ -n "${_tm_start:-}" ] || return 0
  crf_timing_now
  [ -n "$CRF_NOW_US" ] && [ -n "${_tm_last:-}" ] || return 0
  _tm_parts+=" ${1}_ms=$(crf_timing_ms "$_tm_last" "$CRF_NOW_US")"
  _tm_last="$CRF_NOW_US"
}

crf_timing_end() {
  [ -n "${_tm_start:-}" ] || return 0
  crf_timing_now
  [ -n "$CRF_NOW_US" ] || return 0
  crf_timing_write "op=$1 subject=${2:--} rc=${3:-0} total_ms=$(crf_timing_ms "$_tm_start" "$CRF_NOW_US")${_tm_parts}"
}

# Append one line, stamped now. Never fails the caller.
crf_timing_write() {
  local file="${RUNDIR:-}/timing.log" size ts
  [ -n "${RUNDIR:-}" ] || return 0
  crf_timing_now
  ts="${CRF_NOW_US:0:-6}.${CRF_NOW_US: -6:3}"
  [ -n "$CRF_NOW_US" ] || ts="-"
  { printf 'ts=%s %s\n' "$ts" "$1" >> "$file"; } 2>/dev/null || return 0
  size="$(stat -c %s "$file" 2>/dev/null)" || return 0
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$CRF_TIMING_MAX_BYTES" ]; then
    { tail -c "$(( CRF_TIMING_MAX_BYTES / 2 ))" "$file" | tail -n +2 > "$file.tmp.$$" \
      && mv -f "$file.tmp.$$" "$file"; } 2>/dev/null || rm -f "$file.tmp.$$" 2>/dev/null
  fi
  return 0
}
