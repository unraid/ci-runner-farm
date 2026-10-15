#!/usr/bin/env bash
# Persistent DinD stores are pruned between jobs; unused images only under pressure.
set -euo pipefail
cd "$(dirname "$0")/.."
hook="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-job-cleanup.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export PATH="$tmp/bin:$PATH" PRUNE_TEST_LOG="$tmp/calls"
export GITHUB_ACTIONS=true GITHUB_RUN_ID=123456 GITHUB_RUN_ATTEMPT=1 CRF_JOB_CLEANUP_DIND=1
export DOCKER_HOST=tcp://foreign.example DOCKER_CONTEXT=foreign
exited=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
builder=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export PRUNE_EXITED="$exited" PRUNE_BUILDER="$builder"
cat > "$tmp/bin/df" <<'MOCK'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
case "$PRUNE_TEST_MODE" in
 pressure) echo 'cache 1000 950 50 95% /var/lib/docker' ;;
 malformed) echo 'cache unknown 950 50 95% /var/lib/docker' ;;
 *) echo 'cache 1000 700 300 70% /var/lib/docker' ;;
esac
MOCK
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
[ -z "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}" ] || exit 1
[ "$1" = --host ] && [ "$2" = unix:///var/run/docker.sock ] || exit 1
shift 2
case "$1 $2" in
 'info --format') [ "$PRUNE_TEST_MODE" != wrong-root ] && echo /var/lib/docker || echo /foreign ;;
 'version --format') [ "$PRUNE_TEST_MODE" = old-api ] && echo 1.41 || echo 1.56 ;;
 'ps -a') printf '%s %s\n' "$PRUNE_EXITED" job-leftover "$PRUNE_BUILDER" buildx_buildkit_warm0 not-an-id odd ;;
 'rm -v') echo "rm $3" >> "$PRUNE_TEST_LOG"; [ "$PRUNE_TEST_MODE" != rm-error ] ;;
 'volume ls') ;;
 'volume prune'|'image prune'|'builder prune')
  echo "$*" >> "$PRUNE_TEST_LOG"; [ "$PRUNE_TEST_MODE" != prune-error ] ;;
 *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/"*

run() { export PRUNE_TEST_MODE="$1"; : > "$PRUNE_TEST_LOG"; bash "$hook" > "$tmp/output" 2>&1; }

base="rm $exited
volume prune -f
image prune -f
builder prune -f"
run healthy; [ "$(cat "$PRUNE_TEST_LOG")" = "$base" ]
run pressure; [ "$(cat "$PRUNE_TEST_LOG")" = "$base
image prune -a -f" ]
# Unknown free space never escalates to removing tagged images.
run malformed; [ "$(cat "$PRUNE_TEST_LOG")" = "$base" ]
grep -q 'prune incomplete' "$tmp/output"
# Before API 1.42 volume prune also removes named volumes; skip it.
run old-api; [ "$(cat "$PRUNE_TEST_LOG")" = "rm $exited
image prune -f
builder prune -f" ]
# A container removal failure still prunes the rest but is reported.
run rm-error; [ "$(cat "$PRUNE_TEST_LOG")" = "$base" ]; grep -q 'prune incomplete' "$tmp/output"
run wrong-root; [ ! -s "$PRUNE_TEST_LOG" ]
# Prune failure is reported but never fails the completed job.
run prune-error; grep -q 'prune incomplete' "$tmp/output"
CRF_JOB_CLEANUP_DIND=0 run pressure; [ ! -s "$PRUNE_TEST_LOG" ]
echo 'job Docker prune: between-job reclaim, builders kept, unused images only under pressure PASS'
