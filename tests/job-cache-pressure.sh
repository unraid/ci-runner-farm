#!/usr/bin/env bash
# Opted-in reusable caches are reclaimable only after a job and under pressure.
set -euo pipefail
cd "$(dirname "$0")/.."
hook="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-job-cleanup.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export PATH="$tmp/bin:$PATH" CACHE_TEST_LOG="$tmp/calls" CACHE_TEST_ID="$tmp/identity" CACHE_TEST_DF="$tmp/df"
export GITHUB_ACTIONS=true GITHUB_RUN_ID=123456 GITHUB_RUN_ATTEMPT=1 CRF_JOB_CLEANUP_DIND=1
export CRF_DOCKER_CACHE_BUILDERS=warm,second CRF_DOCKER_CACHE_MIN_FREE_PERCENT=15
export DOCKER_HOST=tcp://foreign.example DOCKER_CONTEXT=foreign
cat > "$tmp/bin/df" <<'MOCK'
#!/usr/bin/env bash
[ "$CACHE_TEST_MODE" != df-error ] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
case "$CACHE_TEST_MODE" in
 freed)
  if [ -e "$CACHE_TEST_DF" ]; then echo 'cache 1000 700 300 70% /var/lib/docker'
  else touch "$CACHE_TEST_DF"; echo 'cache 1000 950 50 95% /var/lib/docker'; fi ;;
 healthy) echo 'cache 1000 700 300 70% /var/lib/docker' ;;
 malformed) echo 'cache unknown 950 50 95% /var/lib/docker' ;;
 *) echo 'cache 1000 950 50 95% /var/lib/docker' ;;
esac
MOCK
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
if env | grep -qE '^DOCKER_(HOST|CONTEXT)='; then exit 1; fi
[ "$1" = --host ] && [ "$2" = unix:///var/run/docker.sock ] || exit 1
shift 2
case "$1 $2" in
 'info --format')
  if [ "$3" = '{{.DockerRootDir}}' ]; then
   [ "$CACHE_TEST_MODE" != wrong-root ] && echo /var/lib/docker || echo /foreign
  else
   if [ "$CACHE_TEST_MODE" = changed-daemon ] && [ -e "$CACHE_TEST_ID" ]; then echo 22222222-2222-2222-2222-222222222222
   else touch "$CACHE_TEST_ID"; echo 11111111-1111-1111-1111-111111111111; fi
  fi ;;
 'volume ls') printf '%s\n' buildx_buildkit_warm0_state buildx_buildkit_second0_state database ;;
 'volume inspect')
  [ "$CACHE_TEST_MODE" != inspect-error ] || exit 1
  for name; do :; done
  driver=local; scope=local; options=null; labels=null
  case "$CACHE_TEST_MODE" in
   foreign) driver=nfs ;; labels) labels='{"owner":"other"}' ;; options) options='{"device":"/outside"}' ;; scope) scope=global ;;
  esac
  echo "$name|$driver|$scope|$options|$labels|/var/lib/docker/volumes/$name/_data" ;;
 'ps -aq')
  [ "$CACHE_TEST_MODE" != refs-error ] || exit 1
  [ "$CACHE_TEST_MODE" != referenced ] || echo exact-container ;;
 'volume rm') echo "$3" >> "$CACHE_TEST_LOG"; [ "$CACHE_TEST_MODE" != race ] ;;
 *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/"*
for CACHE_TEST_MODE in pressure healthy freed malformed df-error referenced foreign labels options scope wrong-root changed-daemon inspect-error refs-error race; do
 export CACHE_TEST_MODE
 : > "$CACHE_TEST_LOG"; rm -f "$CACHE_TEST_ID" "$CACHE_TEST_DF"
 bash "$hook" > "$tmp/output" 2>&1
 case "$CACHE_TEST_MODE" in
  pressure|race) [ "$(cat "$CACHE_TEST_LOG")" = buildx_buildkit_warm0_state ] ;;
  *) [ ! -s "$CACHE_TEST_LOG" ] ;;
 esac
done
export CACHE_TEST_MODE=pressure
for CRF_DOCKER_CACHE_BUILDERS in '' 'warm,,second' '-warm' 'warm;second'; do
 export CRF_DOCKER_CACHE_BUILDERS; : > "$CACHE_TEST_LOG"; rm -f "$CACHE_TEST_ID"
 bash "$hook" >/dev/null 2>&1; [ ! -s "$CACHE_TEST_LOG" ]
done
export CRF_DOCKER_CACHE_BUILDERS=warm,second
for CRF_DOCKER_CACHE_MIN_FREE_PERCENT in 0 101 bad; do
 export CRF_DOCKER_CACHE_MIN_FREE_PERCENT; : > "$CACHE_TEST_LOG"; rm -f "$CACHE_TEST_ID"
 bash "$hook" >/dev/null 2>&1; [ ! -s "$CACHE_TEST_LOG" ]
done
echo 'job cache pressure: opt-in, bounded eviction, live references and unknown evidence retained PASS'
