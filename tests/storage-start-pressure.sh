#!/usr/bin/env bash
# Actual GitHub admission boundaries, fail-closed storage observations and recovery.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/cache/work" "$tmp/docker-root"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'STORAGE START FAIL: %s\n' "$*" >&2; exit 1; }
CI_PROVIDER=github; WORK_TMPFS_SIZE=""; CACHE_ROOT="$tmp/cache"; ARGS=(fixture-image)
STORAGE_START_GUARD=true; STORAGE_START_MIN_BYTES=1000; STORAGE_START_MIN_INODES=10
DB=2000; WB=2000; DI=20; WI=20; DF_MODE=valid; INFO_MODE=valid
calls="$tmp/calls"; effects="$tmp/effects"; : > "$calls"; : > "$effects"
crf_safe_cache_root() { printf '%s\n' "$CACHE_ROOT"; }
clear_dangling_endpoint() { return 0; }
timeout() { [ "$1" = --kill-after=1 ] && [ "$2" = 5 ] || fail 'observation lost finite timeout'; shift 2; [ "${TIMEOUT_EXIT:-0}" = 0 ] || return "$TIMEOUT_EXIT"; "$@"; }
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
    *--output=avail*) header=Avail; number="$WB"; [ "$path" != "$CACHE_ROOT" ] || number=2000; [ "$path" != "$tmp/docker-root" ] || number="$DB" ;;
    *--output=iavail*) header=IFree; number="$WI"; [ "$path" != "$CACHE_ROOT" ] || number=20; [ "$path" != "$tmp/docker-root" ] || number="$DI" ;;
    *) fail 'storage observation changed df contract' ;;
  esac
  [ "$path" != "${LOW_PATH:-}" ] || number=0
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
# Existing child datasets can differ from both CACHE_ROOT and the work parent.
for child in slot workspace podman-root podman-runner; do
  (
    DIND=true; EPHEMERAL=true; PODMAN_POOL_STORAGE=true; CACHE_MOUNTS=''; USER_SHARE_MOUNTS=''
    slot="$CACHE_ROOT/work/$NAME_PREFIX-1"
    mkdir -p "$slot/workspace" "$slot/podman-root" "$slot/podman-runner"
    LOW_PATH="$slot"; [ "$child" = slot ] || LOW_PATH="$slot/$child"
    if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail "low child backing filesystem admitted: $child"; fi
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
for TIMEOUT_EXIT in 124 137; do
  if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail 'timed-out observation admitted'; fi
done
TIMEOUT_EXIT=0
# Strict bounds avoid signed-arithmetic wraparound and accidental opt-ins.
for invalid in 0 -1 01 1.5 9999999999999999999; do
  ( STORAGE_START_MIN_BYTES="$invalid"; if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail "invalid floor admitted: $invalid"; fi )
done
( STORAGE_START_GUARD=maybe; if run_owned_github_container 1 > "$tmp/output" 2>&1; then fail 'malformed opt-in admitted'; fi )
( WORK_TMPFS_SIZE=1g; if runner_starts_allowed > "$tmp/output" 2>&1; then fail 'unsupported RAM workspace admitted'; fi )
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
# Stopped-owner recovery is replacement, not an unconditional cleanup command.
(
  remove_runner() { printf 'removed-old-owner\n' >> "$effects"; }
  runner_pool() { echo default; }
  pool_activate() { return 0; }
  start_one() { printf 'replacement\n' >> "$effects"; }
  : > "$effects"
  if recreate_stopped_runner ci-runner-1 'old-id|github|runner|1|old-generation' > "$tmp/output" 2>&1; then
    fail 'stopped-owner recovery admitted pressure'
  fi
  [ ! -s "$effects" ] || fail 'stopped owner retired before pressure admission'
)
# Execute the production deadline against a command that ignores SIGTERM.
(
  mkdir "$tmp/hanging-bin"
  cat > "$tmp/hanging-bin/docker" <<'HANG'
#!/bin/sh
case "$1" in
  info) echo "$$" > "$PROBE_PID_FILE"; trap '' TERM; while :; do :; done ;;
  *) exit 0 ;;
esac
HANG
  chmod +x "$tmp/hanging-bin/docker"
  unset -f timeout docker
  export PATH="$tmp/hanging-bin:$PATH" PROBE_PID_FILE="$tmp/hanging-docker.pid"
  start=$SECONDS
  if crf_storage_start_admit > "$tmp/deadline-output" 2>&1; then fail 'real deadline admitted a hung Docker probe'; fi
  elapsed=$((SECONDS-start))
  [ "$elapsed" -ge 5 ] && [ "$elapsed" -lt 15 ] || fail 'real Docker observation exceeded deadline grace'
  pid="$(cat "$PROBE_PID_FILE")"
  ! kill -0 "$pid" 2>/dev/null || fail 'timed-out Docker probe remains alive'
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
