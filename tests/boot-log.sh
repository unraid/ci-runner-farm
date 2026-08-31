#!/usr/bin/env bash
# Verify that the persistent boot log stays bounded and retains recent entries.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'boot-log: FAIL: %s\n' "$*" >&2; exit 1; }
LOG_HELPER="src/usr/local/emhttp/plugins/ci-runner-farm/include/boot-log.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
source "$LOG_HELPER"

log="$tmp/boot.log"
for i in $(seq 1 600); do
  printf 'line-%04d %0120d\n' "$i" "$i" >> "$log"
done
[ "$(wc -c < "$log" | tr -d '[:space:]')" -gt 65536 ] || fail "fixture is not larger than the rotation threshold"
crf_bound_boot_log "$log" || fail "rotation returned failure"
[ "$(wc -l < "$log" | tr -d '[:space:]')" = 200 ] || fail "rotation did not retain exactly 200 lines"
[ "$(wc -c < "$log" | tr -d '[:space:]')" -le 65536 ] || fail "rotated log is still above the size limit"
grep -q '^line-0600 ' "$log" || fail "rotation discarded the newest log entry"
if grep -q '^line-0001 ' "$log"; then fail "rotation retained the oldest log entry"; fi

small="$tmp/small.log"
printf 'small log\n' > "$small"
before="$(sha256sum "$small" | cut -d' ' -f1)"
crf_bound_boot_log "$small" || fail "small log check returned failure"
after="$(sha256sum "$small" | cut -d' ' -f1)"
[ "$before" = "$after" ] || fail "small log changed below the rotation threshold"

for event in src/usr/local/emhttp/plugins/ci-runner-farm/event/docker_started \
             src/usr/local/emhttp/plugins/ci-runner-farm/event/stopping_docker; do
  grep -qF '. "$PLGDIR/include/boot-log.sh"' "$event" \
    || fail "$event does not load the boot-log helper"
done
grep -qF 'crf_bound_boot_log "\$CFGDIR/boot.log"' build-plg.sh \
  || fail "generated install/remove actions do not bound boot.log"

echo "boot-log: PASS"
