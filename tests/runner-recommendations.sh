#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

HELPER="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-recommendations.sh"

# Minimal pool contract for the pure helper tests. Production supplies these
# functions from runner-pools.sh and runner-farm.sh.
RUNNER_MODE=single
pool_mode_enabled() { [ "$RUNNER_MODE" = pools ]; }
pool_records() {
  printf '%s\n' \
    'v3|small|small|linux,x64|2|0|2|0|1|2g|builtin' \
    'v3|standard|standard|linux,x64|3|0|3|0|2|8g|builtin' \
    'v3|large|size-large|linux,x64|2|0|2|0|4|16g|builtin'
}
pool_effective_labels() {
  case "$1" in
    small) printf 'small,linux,x64\n' ;;
    standard) printf 'standard,linux,x64\n' ;;
    large) printf 'size-large,linux,x64\n' ;;
    *) return 1 ;;
  esac
}

# shellcheck source=/dev/null
. "$HELPER"

fail=0
check() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || { printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2; fail=1; }
}

IFS='|' read -r class score reason < <(crf_recommendation_weight 'JS lint' 20 300 60)
check light "$class" 'lint class'
check 1 "$score" 'lint score'

IFS='|' read -r class score reason < <(crf_recommendation_weight 'Build Fedora Core artifact' 180 8192 0)
check heavy "$class" 'Fedora class'
check 5 "$score" 'Fedora score cap'

IFS='|' read -r class score reason < <(crf_recommendation_weight 'ExUnit partition' 40 1200 2100)
check heavy "$class" 'long-running test class'

check default "$(crf_recommendation_target_pool heavy)" 'single-fleet target'

RUNNER_MODE=pools
check large "$(crf_recommendation_target_pool heavy)" 'large-pool target'
check small "$(crf_recommendation_target_pool light)" 'small-pool target'
check standard "$(crf_recommendation_target_pool standard)" 'standard-pool target'

[ "$fail" -eq 0 ] || exit 1
echo "runner-recommendations: OK"
