#!/usr/bin/env bash
# An image update must roll the fleet even when this tick's own pull was a no-op
# because the new image was already in the local store (an operator primed it by
# hand, the shared mirror fetched it, another farm action pulled it). The ref
# string is unchanged in that case, so neither imageupdate_pull's before/after
# comparison nor the confgen fingerprint notices; only what the runners are
# actually running does.
set -euo pipefail
# The sourced engine consumes these values through Bash dynamic scope.
# shellcheck disable=SC2034
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source "$ENGINE"

IMAGE_AUTOUPDATE=true
IMAGE_SOURCE=remote
IMAGE="ghcr.io/unraid/ci-runner-image:latest"
rollover_log="$tmp/rollovers"
: > "$rollover_log"

# Stand in for the fleet: two runners whose running image IDs come from
# RUNNER_IMAGE_IDS, and a configuration that resolves to WANT_IMAGE_ID.
managed_names() { printf '%s\n' ci-runner-1 ci-runner-2; }
expected_runner_image_id() { printf '%s\n' "$WANT_IMAGE_ID"; }
imageupdate_pull() { return "${PULL_CHANGED:-1}"; }
imageupdate_rollover() { printf '%s\n' "${1:-false}" >> "$rollover_log"; }
log() { :; }
docker() {
  # only `docker inspect -f '{{.Image}}' <name>` is used here
  [ "${1:-}" = inspect ] || return 1
  local name="${*: -1}"
  case "$name" in
    ci-runner-1) printf '%s\n' "${RUNNER_1_IMAGE_ID}" ;;
    ci-runner-2) printf '%s\n' "${RUNNER_2_IMAGE_ID}" ;;
    *) return 1 ;;
  esac
}

assert_rollovers() {
  local label="$1" expected="$2"
  : > "$rollover_log"
  imageupdate_tick
  [ "$(cat "$rollover_log")" = "$expected" ] \
    || { printf 'imageupdate-drift: %s expected [%s], got [%s]\n' \
         "$label" "$expected" "$(cat "$rollover_log")" >&2; exit 1; }
}

WANT_IMAGE_ID=sha256:new
PULL_CHANGED=1                     # the pull itself reports "nothing moved"
rm -f "$IMAGEUPDATE_PENDING"

# The regression: runners left behind on the superseded image must still roll.
RUNNER_1_IMAGE_ID=sha256:old
RUNNER_2_IMAGE_ID=sha256:old
assert_rollovers "superseded image rolls despite a no-op pull" false

# One straggler is enough.
RUNNER_1_IMAGE_ID=sha256:new
RUNNER_2_IMAGE_ID=sha256:old
assert_rollovers "a single drifted runner rolls the fleet" false

# A fleet already on the configured image must stay put — no churn every tick.
RUNNER_1_IMAGE_ID=sha256:new
RUNNER_2_IMAGE_ID=sha256:new
assert_rollovers "an up-to-date fleet does not roll" ""

# Unresolvable state fails closed rather than rolling the fleet.
RUNNER_1_IMAGE_ID=""
RUNNER_2_IMAGE_ID=sha256:new
assert_rollovers "an unreadable runner image does not roll" ""

WANT_IMAGE_ID=""
RUNNER_1_IMAGE_ID=sha256:old
RUNNER_2_IMAGE_ID=sha256:old
assert_rollovers "an unresolvable expected image does not roll" ""

# Pending slots keep their targeted retry instead of a full re-roll.
WANT_IMAGE_ID=sha256:new
RUNNER_1_IMAGE_ID=sha256:old
RUNNER_2_IMAGE_ID=sha256:old
printf '%s\n' ci-runner-2 > "$IMAGEUPDATE_PENDING"
assert_rollovers "pending slots retry instead of re-rolling" true
rm -f "$IMAGEUPDATE_PENDING"

# The autoupdate flag still gates everything.
IMAGE_AUTOUPDATE=false
RUNNER_1_IMAGE_ID=sha256:old
RUNNER_2_IMAGE_ID=sha256:old
assert_rollovers "autoupdate disabled rolls nothing" ""

echo "Image-update drift checks passed"
