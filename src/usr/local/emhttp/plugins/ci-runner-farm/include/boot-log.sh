#!/bin/bash

# Keep the persistent boot log useful after repeated Docker lifecycle events
# without allowing it to consume unbounded space on the flash device.
crf_bound_boot_log() {
  local log="${1:-}" size tmp
  [ -n "$log" ] && [ -f "$log" ] || return 0
  size="$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')" || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -gt 65536 ] || return 0

  tmp="$(mktemp "${log}.XXXXXX" 2>/dev/null)" || return 0
  if tail -n 200 "$log" > "$tmp" && mv -f -- "$tmp" "$log"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 0
}
