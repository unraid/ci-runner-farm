#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
hook="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-job-cleanup.sh"
test -f "$hook" || { echo 'persistent runners have no job cache cleanup hook' >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export CACHE_TEST_LOG="$tmp/calls" CACHE_TEST_MODE=normal
export PATH="$tmp/bin:$PATH" GITHUB_ACTIONS=true GITHUB_RUN_ID=123456 GITHUB_RUN_ATTEMPT=2 CRF_JOB_CLEANUP_DIND=1
export DOCKER_HOST=tcp://foreign.example DOCKER_CONTEXT=foreign
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
[ -z "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}" ] || exit 1
[ "$1" = --host ] && [ "$2" = unix:///var/run/docker.sock ] || exit 1
shift 2
case "$1 $2" in
 'info --format') [ "$CACHE_TEST_MODE" != daemon ] || exit 1; echo /var/lib/docker ;;
 'volume ls')
  [ "$CACHE_TEST_MODE" != list ] || exit 1
  printf '%s\n' buildx_buildkit_demo-123456-20_state buildx_buildkit_linked-123456-20_state buildx_buildkit_labeled-123456-20_state buildx_buildkit_remote-123456-20_state buildx_buildkit_keep0_state buildx_buildkit_demo-123456-10_state buildx_buildkit_demo-999999-20_state database
  ;;
 'volume inspect')
  name="${@: -1}"; label=null; driver=local
  [ "$CACHE_TEST_MODE" != inspect ] || exit 1
  case "$name" in *labeled*) label='{"owner":"database"}' ;; *remote*) driver=nfs ;; esac
  echo "$name|$driver|local|null|$label|/var/lib/docker/volumes/$name/_data"
  ;;
 'ps -aq')
  [ "$CACHE_TEST_MODE" != references ] || exit 1
  case "${@: -1}" in *linked*) echo abcdef ;; esac
  ;;
 'volume rm')
  echo "$3" >> "$CACHE_TEST_LOG"
  [ "$CACHE_TEST_MODE" != race ] || exit 1
  ;;
 *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/docker"
for CACHE_TEST_MODE in normal daemon list inspect references race; do
 export CACHE_TEST_MODE
 : > "$CACHE_TEST_LOG"
 bash "$hook" > "$tmp/output" 2>&1
 case "$CACHE_TEST_MODE" in
  normal|race) [ "$(cat "$CACHE_TEST_LOG")" = buildx_buildkit_demo-123456-20_state ] ;;
  *) [ ! -s "$CACHE_TEST_LOG" ] ;;
 esac
done
for GITHUB_RUN_ID in '' 0 0123456 bad; do
 export GITHUB_RUN_ID; : > "$CACHE_TEST_LOG"; bash "$hook" >/dev/null 2>&1; [ ! -s "$CACHE_TEST_LOG" ]
done
GITHUB_RUN_ID=123456; CRF_JOB_CLEANUP_DIND=0
export GITHUB_RUN_ID CRF_JOB_CLEANUP_DIND
: > "$CACHE_TEST_LOG"; bash "$hook" >/dev/null 2>&1; [ ! -s "$CACHE_TEST_LOG" ]
echo 'job Docker cache: exact job scope, preserved references/custom volumes, local daemon and nonfatal failures PASS'

# Exercise the actual provider argv: a host socket must never receive this hook.
(
 export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
 mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
 # shellcheck source=/dev/null
 source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
 CACHE_ROOT="$tmp/cache"; CACHE_MOUNTS=''; NO_REGISTER=1
 docker() { [ "${IMAGE_HOOK_INSPECT_FAIL:-0}" != 1 ] || return 1; printf '%s\n' 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/original.sh'; }
 GH_SCOPE=org; GH_OWNER=example; NETWORK_ISOLATION=off
 for mode in persistent ephemeral host-socket; do
  DIND=true; EPHEMERAL=false; SHARE_DOCKER_SOCK=false
  case "$mode" in ephemeral) EPHEMERAL=true ;; host-socket) DIND=false; SHARE_DOCKER_SOCK=true ;; esac
  github_build_args 1 test-runner
  args="$(printf '%s\n' "${ARGS[@]}")"
  if [ "$mode" = persistent ]; then
   grep -qx 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/ci-runner-farm/job-completed.sh' <<< "$args"
   grep -qx 'CRF_IMAGE_JOB_COMPLETED_HOOK=/usr/local/bin/original.sh' <<< "$args"
   grep -qx 'CRF_JOB_CLEANUP_DIND=1' <<< "$args"
   grep -q ':\/opt\/ci-runner-farm\/job-completed.sh:ro$' <<< "$args"
  else
   if grep -q ACTIONS_RUNNER_HOOK_JOB_COMPLETED <<< "$args"; then exit 1; fi
  fi
 done
 DIND=true; EPHEMERAL=false; SHARE_DOCKER_SOCK=false
 IMAGE_HOOK_INSPECT_FAIL=1
 if github_build_args 1 test-runner >/dev/null 2>&1; then exit 1; fi
 IMAGE_HOOK_INSPECT_FAIL=0
 DOCKER_CACHE_BUILDERS=warm,second; DOCKER_CACHE_MIN_FREE_PERCENT=15
 github_build_args 1 test-runner
 args="$(printf '%s\n' "${ARGS[@]}")"
 grep -qx 'CRF_DOCKER_CACHE_BUILDERS=warm,second' <<< "$args"
 grep -qx 'CRF_DOCKER_CACHE_MIN_FREE_PERCENT=15' <<< "$args"
 first_generation="$(github_confgen)"
 DOCKER_CACHE_MIN_FREE_PERCENT=20
 [ "$(github_confgen)" != "$first_generation" ]
 DOCKER_CACHE_BUILDERS=second,warm
 [ "$(github_confgen)" != "$first_generation" ]
 crf_validate_user_share_mounts() { return 0; }
 crf_shared_cache_mount() { return 0; }
 github_validate_settings
 DOCKER_CACHE_BUILDERS='warm,,second'
 if github_validate_settings >/dev/null 2>&1; then exit 1; fi
 if github_build_args 1 test-runner >/dev/null 2>&1; then exit 1; fi
 DOCKER_CACHE_BUILDERS="$(printf 'warm,%.0s' {1..32})second"
 if github_build_args 1 test-runner >/dev/null 2>&1; then exit 1; fi
 DOCKER_CACHE_BUILDERS=''
 CACHE_MOUNTS='shadow:/opt' 
 if github_build_args 1 test-runner >/dev/null 2>&1; then exit 1; fi
)
echo 'job Docker cache: persistent DinD only, read-only hook bind and shadow rejection PASS'

# The prior image hook runs first and retains its failure semantics.
cat > "$tmp/original.sh" <<'ORIGINAL'
printf 'original\n' >> "$CACHE_TEST_LOG"
exit "${ORIGINAL_STATUS:-0}"
ORIGINAL
export CRF_IMAGE_JOB_COMPLETED_HOOK="$tmp/original.sh" ORIGINAL_STATUS=0
export CRF_JOB_CLEANUP_DIND=1 CACHE_TEST_MODE=normal
: > "$CACHE_TEST_LOG"
bash "$hook" >/dev/null
[ "$(head -n 1 "$CACHE_TEST_LOG")" = original ]
[ "$(tail -n 1 "$CACHE_TEST_LOG")" = buildx_buildkit_demo-123456-20_state ]
ORIGINAL_STATUS=17; export ORIGINAL_STATUS
if bash "$hook" >/dev/null; then exit 1; else [ "$?" = 17 ]; fi
echo 'job Docker cache: original image hook ordered first and failure preserved PASS'
