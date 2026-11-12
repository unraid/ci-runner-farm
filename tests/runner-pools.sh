#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

HELPER="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh"
# shellcheck disable=SC1090
. "$HELPER"

pass=0
fail=0
ok() { pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=$((fail+1)); }
accept() {
  if pool_config_validate "$1" "$2" "$3" "${4:-github}"; then ok; else bad "expected valid: $POOL_CONFIG_ERROR"; fi
}
reject() {
  if pool_config_validate "$1" "$2" "$3" "${4:-github}"; then bad "expected rejection: $2"; else ok; fi
}

build='v3|build|ci-build|linux,x64|3|2|5|1|2|8g|ghcr.io/unraid/ci-runner-image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
qa='v3|qa-vm|qa-vm-client|linux,x64|2|1|3|1|1.5|4g|ghcr.io/unraid/qa-vm-client@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
valid="$build;$qa"

accept single '' repo
accept pools "$valid" org
[ "$POOL_RECORDS" = "$valid" ] && ok || bad 'valid records were not normalized'
accept pools "$valid" repo gitlab
accept pools 'v3|minimal|ci-minimal||1|0|1|0|inherit|inherit|builtin' org

RUNNER_MODE=pools RUNNER_POOLS="$valid" GH_SCOPE=org AUTOSCALE=true
[ "$(pool_routing_label qa-vm)" = qa-vm-client ] && ok || bad 'routing label mismatch'
[ "$(pool_effective_labels qa-vm)" = 'qa-vm-client,linux,x64' ] && ok || bad 'effective labels mismatch'
[ "$(pool_image qa-vm)" = 'ghcr.io/unraid/qa-vm-client@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ] && ok || bad 'pool image mismatch'
[ "$(pool_configured_target build)" = 2 ] && ok || bad 'autoscale target mismatch'
AUTOSCALE=false
[ "$(pool_configured_target build)" = 3 ] && ok || bad 'fixed target mismatch'

RUNNER_MODE=single RUNNER_COUNT=4 RUNNER_LABELS='self-hosted,unraid,build'
AUTOSCALE_MIN=2 AUTOSCALE_MAX=16 AUTOSCALE_MIN_IDLE=2 GH_SCOPE=repo IMAGE='ghcr.io/unraid/default:latest'
[ "$(pool_image default)" = 'ghcr.io/unraid/default:latest' ] && ok || bad 'single image compatibility mismatch'
[ "$(pool_effective_labels default)" = "$RUNNER_LABELS" ] && ok || bad 'single labels compatibility mismatch'

reject broken "$valid" org
reject pools '' org
reject pools "$valid" repo
reject pools "${build};${build}" org
reject pools "${build};v3|qa-vm|ci-build|linux|1|1|1|1|1|1g|builtin" org
reject pools 'v3|qa-vm|qa-vm-client|linux|1|1|1|1|1|1g|' org
reject pools 'v3|qa-vm|qa-vm-client|linux|1|1|1|1|1|1g|-bad' org
reject pools 'v3|qa-vm|qa-vm-client|linux|1|1|1|1|1|1g|image;bad' org
reject pools 'v3|qa-vm|qa-vm-client|linux,linux|1|1|1|1|1|1g|builtin' org
reject pools 'v3|qa-vm|qa-vm-client|qa-vm-client|1|1|1|1|1|1g|builtin' org
reject pools 'v3|qa-vm|qa-vm-client|linux|1|2|1|1|1|1g|builtin' org
reject pools 'v3|qa-vm|qa-vm-client|linux|1|0|1|2|1|1g|builtin' org
reject pools 'v3|qa-vm|qa-vm-client|linux|1|0|1|0|0|1g|builtin' org
reject pools 'v3|qa-vm|qa-vm-client|linux|1|0|1|0|1|zero|builtin' org
reject pools $'v3|qa-vm|qa-vm-client|linux|1|0|1|0|1|1g|builtin\n' org

# The validated records are cached per process, keyed by their exact inputs.
# Field lookups after the first validate nothing; any input change validates
# again; a failed validation is not kept.
eval "real_$(declare -f pool_config_validate)"
count_file="$(mktemp)"
trap 'rm -f "$count_file"' EXIT
pool_config_validate() { echo x >> "$count_file"; real_pool_config_validate "$@"; }
validations() { grep -c . "$count_file" || true; }
RUNNER_MODE=pools RUNNER_POOLS="$valid" GH_SCOPE=org CI_PROVIDER=github
POOL_RECORDS_CACHE_KEY=""
pool_records_prime
[ "$(validations)" -eq 1 ] && ok || bad "priming validated $(validations) times"
for _ in 1 2 3; do
  [ "$(pool_min build)" = 2 ] && [ "$(pool_max qa-vm)" = 3 ] && [ "$(pool_image qa-vm)" = "${qa##*|}" ] && ok || bad 'cached field lookup changed'
done
[ "$(pool_records)" = "$(printf '%s\n%s' "$build" "$qa")" ] && ok || bad 'cached records changed'
[ "$(validations)" -eq 1 ] && ok || bad "cached lookups validated $(validations) times"
RUNNER_POOLS="$build"
pool_records_prime
[ "$(pool_records)" = "$build" ] && ok || bad 'changed pools reused the old cache'
pool_record qa-vm >/dev/null && bad 'a removed pool was still found' || ok
GH_SCOPE=repo
pool_records >/dev/null 2>&1 && bad 'a scope change reused the cached records' || ok
pool_records >/dev/null 2>&1 && bad 'a failed validation was cached' || ok
[ "$(validations)" -eq 4 ] && ok || bad "expected 4 validations, got $(validations)"
GH_SCOPE=org
[ "$(pool_records)" = "$build" ] && ok || bad 'records after a failure were wrong'
RUNNER_MODE=single
[ "$(pool_records | cut -d'|' -f1-2)" = 'single|default' ] && ok || bad 'single mode used the pools cache'

printf 'runner-pools: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
