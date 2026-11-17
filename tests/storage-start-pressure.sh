#!/usr/bin/env bash
# Actual GitHub admission boundaries, fail-closed storage observations and recovery.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/cache" "$tmp/docker-root"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'STORAGE START FAIL: %s\n' "$*" >&2; exit 1; }
CI_PROVIDER=github; CACHE_ROOT="$tmp/cache"; ARGS=(fixture-image)
STORAGE_START_GUARD=true; STORAGE_START_MIN_BYTES=1000; STORAGE_START_MIN_INODES=10
DB=2000; WB=2000; DI=20; WI=20; DF_MODE=valid; INFO_MODE=valid
calls="$tmp/calls"; effects="$tmp/effects"; : > "$calls"; : > "$effects"
crf_safe_cache_root() { printf '%s\n' "$CACHE_ROOT"; }
clear_dangling_endpoint() { return 0; }
timeout() { [ "$1" = 5 ] || fail 'observation lost finite timeout'; shift; "$@"; }
docker() {
  case "$1" in
    info)
      printf 'info\n' >> "$calls"
      [ "$INFO_MODE" != failed ] || return 1
      case "$INFO_MODE" in malformed) printf 'relative-path\n' ;; *) printf '%s\n' "$tmp/docker-root" ;; esac ;;
    run|start|pull) printf '%s\n' "$1" >> "$effects" ;;
    *) fail "unexpected Docker operation $*" ;;
  esac
}
df() {
  local path="${*: -1}" number header
  printf 'df %s\n' "$*" >> "$calls"
  [ "$DF_MODE" != failed ] || return 1
  case "$*" in
    *--output=avail*) header=Avail; number="$WB"; [ "$path" != "$tmp/docker-root" ] || number="$DB" ;;
    *--output=iavail*) header=IFree; number="$WI"; [ "$path" != "$tmp/docker-root" ] || number="$DI" ;;
    *) fail 'storage observation changed df contract' ;;
  esac
  case "$DF_MODE" in
    malformed) number=unknown ;; negative) number=-1 ;; overflow) number=9999999999999999999 ;;
  esac
  printf '%s\n %s\n' "$header" "$number"
  [ "$DF_MODE" != extra ] || printf 'unexpected third row\n'
}
# Baseline counterexample: even a minimum refill uses this actual creation path.
DB=999
if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail 'runner started below Docker byte floor'; fi
[ ! -s "$effects" ] || fail 'low Docker capacity reached a creation effect'
DB=2000
for metric in docker_bytes workspace_bytes docker_inodes workspace_inodes; do
  (
    case "$metric" in docker_bytes) DB=999 ;; workspace_bytes) WB=999 ;; docker_inodes) DI=9 ;; workspace_inodes) WI=9 ;; esac
    : > "$effects"
    if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail "creation admitted low $metric"; fi
    if start_owned_container fixture fixture-id > "$tmp/output" 2>&1; then fail "restart admitted low $metric"; fi
    [ ! -s "$effects" ] || fail 'pressure reached Docker mutation'
  )
done
for DF_MODE in failed malformed negative overflow extra; do
  if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail "unknown observation admitted: $DF_MODE"; fi
done
DF_MODE=valid
for INFO_MODE in failed malformed; do
  if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail 'unknown Docker root admitted'; fi
done
INFO_MODE=valid
# Strict bounds avoid signed-arithmetic wraparound and accidental opt-ins.
for invalid in 0 -1 01 1.5 9999999999999999999; do
  ( STORAGE_START_MIN_BYTES="$invalid"; if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail "invalid floor admitted: $invalid"; fi )
done
( STORAGE_START_GUARD=maybe; if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail 'malformed opt-in admitted'; fi )
( CI_PROVIDER=gitlab; if runner_starts_allowed > "$tmp/output" 2>&1; then fail 'unsupported GitLab opt-in admitted'; fi )
# Pressure must not block the general lifecycle/recovery precondition.
DB=0
runner_starts_allowed || fail 'storage pressure blocked cleanup precondition'
DB=1000; WB=1000; DI=10; WI=10
: > "$effects"; : > "$calls"
run_owned_github_container 1 || fail 'exact byte/inode floors rejected'
start_owned_container fixture fixture-id || fail 'healthy restart rejected'
[ "$(cat "$effects")" = "$(printf 'run\nstart\n')" ] || fail 'healthy operations changed'
grep -Fq "$tmp/docker-root" "$calls" || fail 'Docker root was not sampled'
grep -Fq "$CACHE_ROOT" "$calls" || fail 'workspace was not sampled'
# Native cold preparation is fenced before registry auth or pull; a cached digest is read-only.
image_digest_present() { [ "${DIGEST_PRESENT:-false}" = true ]; }
registry_login() { printf 'login\n' >> "$effects"; }
host_docker_pull() { docker pull "$1"; }
DB=0; : > "$effects"
if github_prepare_remote_image fixture-image > "$tmp/output" 2>&1; then fail 'cold pull admitted under pressure'; fi
[ ! -s "$effects" ] || fail 'cold pressure reached registry/pull'
DIGEST_PRESENT=true
github_prepare_remote_image fixture-image || fail 'cached digest read-only lookup rejected'
[ ! -s "$effects" ] || fail 'cached lookup caused an effect'
# The public start and validator must reject before preparing a slot.
prepare_log="$tmp/preparation"; : > "$prepare_log"
( github_build_args() { printf 'workspace\n' >> "$prepare_log"; return 0; }
  effective_image() { echo fixture-image; }
  if github_start_one 1 fixture > "$tmp/output" 2>&1; then fail 'public start admitted pressure'; fi
  [ ! -s "$prepare_log" ] || fail 'public pressure guard ran after workspace allocation'
)
( check_cache_root() { printf 'cache\n' >> "$prepare_log"; return 0; }
  if github_validate > "$tmp/output" 2>&1; then fail 'validator admitted pressure'; fi
  [ ! -s "$prepare_log" ] || fail 'validation pressure guard ran after preparation'
)
# Disabling preserves old paths without observing either filesystem.
STORAGE_START_GUARD=false; : > "$calls"; : > "$effects"
run_owned_github_container 1 || fail 'disabled default rejected ordinary creation'
[ ! -s "$calls" ] || fail 'disabled default performed new observations'
# A reload with omitted settings must not inherit a previous opt-in or its floors.
printf 'STORAGE_START_GUARD="true"\nSTORAGE_START_MIN_BYTES="1000"\nSTORAGE_START_MIN_INODES="10"\n' > "$CFG"
load_cfg
[ "$STORAGE_START_GUARD" = true ] && [ "$STORAGE_START_MIN_BYTES" = 1000 ] || fail 'policy did not round-trip'
printf '' > "$CFG"; load_cfg
[ "$STORAGE_START_GUARD" = false ] && [ "$STORAGE_START_MIN_BYTES" = 0 ] && [ "$STORAGE_START_MIN_INODES" = 0 ] || fail 'omitted policy stayed enabled'
printf 'storage start pressure: defaults, bounds, actual roots, byte/inode floors and owner boundaries passed.\n'
