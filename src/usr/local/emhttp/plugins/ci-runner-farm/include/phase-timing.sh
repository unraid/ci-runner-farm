#!/bin/bash
# Phase timing: where fleet operations spend their time.
#
# Each timed operation (a recycle, a runner start, an autoscale or lifecycle
# tick, an exit-event batch, a fleet.lock hold) appends one line to
# $RUNDIR/timing.log:
#   ts=<epoch.ms> op=<operation> subject=<slot or caller> rc=<exit> total_ms=<n> <phase>_ms=<n> ...
# A phase is the time since the previous mark, so the phases of one line add
# up to at most its total (an early return or an unmarked tail is not a
# phase). A phase key can repeat, for example once per replacement; sum the
# repeats. The file is kept under CRF_TIMING_MAX_BYTES by dropping its older
# half, and it is never written to flash. It is observation only: a failure
# to time or to write never changes the operation.
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

# Set CRF_MS to milliseconds from <from> to now (CRF_NOW_US), without a fork.
crf_timing_since() {
  CRF_MS=""
  [ -n "$1" ] && [ -n "$CRF_NOW_US" ] || return 0
  CRF_MS="$(( (CRF_NOW_US - $1) / 1000 ))"
}

crf_timing_begin() {
  crf_timing_now
  _tm_start="$CRF_NOW_US"; _tm_last="$CRF_NOW_US"; _tm_parts=""
}

crf_timing_mark() {
  [ -n "${_tm_start:-}" ] || return 0
  crf_timing_now
  [ -n "$CRF_NOW_US" ] && [ -n "${_tm_last:-}" ] || return 0
  crf_timing_since "$_tm_last"
  _tm_parts+=" ${1}_ms=$CRF_MS"
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
  local file="${RUNDIR:-}/timing.log" size ts="-"
  [ -n "${RUNDIR:-}" ] || return 0
  # RUNDIR falls back to the flash config folder when RAM is unavailable.
  case "$RUNDIR/" in /boot/*|"${CFGDIR:-/boot}"/*) return 0 ;; esac
  crf_timing_now
  [ -z "$CRF_NOW_US" ] || ts="${CRF_NOW_US:0:-6}.${CRF_NOW_US: -6:3}"
  { printf 'ts=%s %s\n' "$ts" "$1" >> "$file"; } 2>/dev/null || return 0
  size="$(stat -c %s "$file" 2>/dev/null)" || return 0
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$CRF_TIMING_MAX_BYTES" ]; then
    { tail -c "$(( CRF_TIMING_MAX_BYTES / 2 ))" "$file" | tail -n +2 > "$file.tmp.$$" \
      && mv -f "$file.tmp.$$" "$file"; } 2>/dev/null || rm -f "$file.tmp.$$" 2>/dev/null
  fi
  return 0
}

# A command that holds fleet.lock can release it for a while (a yield between
# replacements, an image-update drain). Callers mark those windows, and the
# "op=lock" line reports them as released_ms and leaves them out of hold_ms.
crf_lock_release_begin() { crf_timing_now; CRF_LOCK_RELEASE_AT="$CRF_NOW_US"; }
crf_lock_release_end() {
  crf_timing_now
  [ -n "${CRF_LOCK_RELEASE_AT:-}" ] && [ -n "$CRF_NOW_US" ] || return 0
  CRF_LOCK_RELEASED_US=$(( ${CRF_LOCK_RELEASED_US:-0} + CRF_NOW_US - CRF_LOCK_RELEASE_AT ))
  CRF_LOCK_RELEASE_AT=""
}
