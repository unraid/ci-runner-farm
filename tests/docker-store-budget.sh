#!/usr/bin/env bash
# Ephemeral and persistent DinD slots keep their inner Docker store under an
# opt-in budget between jobs: oldest unused images first, never an image in use.
set -euo pipefail
cd "$(dirname "$0")/.."
hook="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-job-cleanup.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
fail() { printf 'DOCKER STORE BUDGET FAIL: %s\n' "$*" >&2; exit 1; }
export PATH="$tmp/bin:$PATH" BUDGET_LOG="$tmp/calls" BUDGET_STATE="$tmp/state"
export GITHUB_ACTIONS=true GITHUB_RUN_ID=123456 GITHUB_RUN_ATTEMPT=1 CRF_JOB_CLEANUP_DIND=1 CRF_JOB_PRUNE=0
a=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
b=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
c=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
u=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
running=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
export IMG_A="$a" IMG_B="$b" IMG_C="$c" IMG_U="$u" RUNNING="$running"
# Store model: one file per image holding its size in GB; build cache in GB.
reset_store() {
  rm -rf "$BUDGET_STATE/images"; mkdir -p "$BUDGET_STATE/images"
  echo 10 > "$BUDGET_STATE/images/a"; echo 10 > "$BUDGET_STATE/images/b"
  echo 10 > "$BUDGET_STATE/images/c"; echo 10 > "$BUDGET_STATE/images/u"
  echo "${1:-5}" > "$BUDGET_STATE/cache"
}
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
[ "$1" = --host ] && [ "$2" = unix:///var/run/docker.sock ] || exit 1
shift 2
key() { case "$1" in "$IMG_A"|old:1) echo a ;; "$IMG_B"|mid:1|mid:2) echo b ;; "$IMG_C"|new:1) echo c ;; "$IMG_U"|used:1) echo u ;; *) echo '' ;; esac; }
case "$1 $2" in
 'info --format') echo /var/lib/docker ;;
 'version --format') echo 1.47 ;;
 'system df')
  [ "${BUDGET_MODE:-}" != df-error ] || exit 1
  total=0; for f in "$BUDGET_STATE"/images/*; do [ -e "$f" ] && total=$((total + $(cat "$f"))); done
  printf 'Images|%sGB\nContainers|1.5kB\nLocal Volumes|%sGB\nBuild Cache|%sGB\n' "$total" "${VOLUMES_GB:-0}" "$(cat "$BUDGET_STATE/cache")" ;;
 'ps -a') if [ "${3:-}" = -q ] || [ "${2:-}" = -aq ]; then echo "$RUNNING"; fi ;;
 'ps -aq') echo "$RUNNING" ;;
 'inspect --format') echo "$IMG_U" ;;
 'rm -v') echo "rm $3" >> "$BUDGET_LOG" ;;
 'volume prune'|'image prune') echo "$1 $2" >> "$BUDGET_LOG" ;;
 'builder prune')
  [ "${BUILDX_BUILDER:-}" = default ] || { echo 'builder prune reached the job builder' >&2; exit 1; }
  echo "$*" >> "$BUDGET_LOG"
  case "$*" in *until=168h*) echo $(( $(cat "$BUDGET_STATE/cache") / 2 )) > "$BUDGET_STATE/cache" ;; *-a*) echo 0 > "$BUDGET_STATE/cache" ;; esac ;;
 'image ls') for k in a b c u; do [ -e "$BUDGET_STATE/images/$k" ] && eval echo "\$IMG_$(echo $k | tr a-z A-Z)"; done; true ;;
 'image inspect')
  if [ "$3" = --format ]; then
    shift 4
    for id in "$@"; do
      case "$(key "$id")" in
        a) printf '%s|2026-01-01T00:00:00Z|2025-01-01T00:00:00Z|10000000000|old:1\n' "$IMG_A" ;;
        b) printf '%s|0001-01-01T00:00:00Z|2026-02-01T00:00:00Z|10000000000|mid:1 mid:2\n' "$IMG_B" ;;
        c) printf '%s|2026-03-01T00:00:00Z|2025-01-01T00:00:00Z|10000000000|new:1\n' "$IMG_C" ;;
        u) printf '%s|2025-06-01T00:00:00Z|2025-01-01T00:00:00Z|10000000000|used:1\n' "$IMG_U" ;;
      esac
    done
  else k="$(key "$3")"; [ -n "$k" ] && [ -e "$BUDGET_STATE/images/$k" ]; fi ;;
 'image rm')
  echo "image rm $3" >> "$BUDGET_LOG"
  k="$(key "$3")"
  [ "$k" != u ] || { echo 'conflict: image is being used by running container' >&2; exit 1; }
  case "$3" in mid:1) exit 0 ;; esac   # first of two tags only untags
  [ -n "$k" ] && rm -f "$BUDGET_STATE/images/$k" ;;
 *) echo "unexpected docker $*" >&2; exit 1 ;;
esac
MOCK
# The typed API query is the fast path. By default it fails, so the cases
# below exercise the docker system df fallback; FAST_API=1 serves it.
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
[ "${FAST_API:-}" = 1 ] || exit 7
[[ "$*" == *'--unix-socket /var/run/docker.sock'* && "$*" == *'/v1.44/system/df?type=image&type=build-cache'* ]] || exit 2
[ "${API_TIMEOUT:-}" != 1 ] || exit 124
echo "curl df" >> "$BUDGET_LOG"
total=0; for f in "$BUDGET_STATE"/images/*; do [ -e "$f" ] && total=$((total + $(cat "$f"))); done
printf '{"LayersSize":%s,"BuildCache":[{"Size":%s,"Shared":false},{"Size":7000000000,"Shared":true}]}\n' \
  "$((total * 1000000000))" "$(( $(cat "$BUDGET_STATE/cache") * 1000000000 ))"
MOCK
# Free space for the skip window's pressure check; DF_PRESSURE=1 is short.
cat > "$tmp/bin/df" <<'MOCK'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
if [ "${DF_PRESSURE:-}" = 1 ]; then echo 'cache 1000 950 50 95% /var/lib/docker'; else echo 'cache 1000 500 500 50% /var/lib/docker'; fi
MOCK
cat > "$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do shift; [ "${prev:-}" = -k ] || true; done
case "$1" in [0-9]*) shift ;; esac
case "$1" in [0-9]*) shift ;; esac
exec "$@"
MOCK
chmod +x "$tmp/bin/"*
# The hook writes its record into the slot log bind; point it at a fixture.
sed "s#/var/log/dind/store-budget#$tmp/record#" "$hook" > "$tmp/hook.sh"; chmod +x "$tmp/hook.sh"
mkdir "$tmp/record"
run() { : > "$BUDGET_LOG"; bash "$tmp/hook.sh" > "$tmp/output" 2>&1; }

# Under budget: only disposable state goes; no image or cache eviction. Warm
# builder volumes are not removable here, so they never count against it.
reset_store 5; export CRF_DOCKER_STORE_BUDGET_BYTES=$((60 * 1000 * 1000 * 1000)); VOLUMES_GB=90 run
! grep -q 'image rm\|builder prune' "$BUDGET_LOG" || fail 'under-budget store lost warm state'
grep -q '"over_budget":false' "$tmp/record/state.json" || fail 'under-budget record missing'

# Over budget: week-old cache first, then the oldest unused images by tag time
# (creation time when never tagged), never the image a container uses, and
# no image beyond what reaches the budget.
reset_store 8; rm -f "$tmp/record/state.json"; export CRF_DOCKER_STORE_BUDGET_BYTES=$((25 * 1000 * 1000 * 1000)); run
grep -q 'builder prune -f --filter until=168h' "$BUDGET_LOG" || fail 'old build cache was not pruned first'
[ "$(grep -o 'image rm [^ ]*' "$BUDGET_LOG" | tr '\n' ' ')" = "image rm old:1 image rm mid:1 image rm mid:2 " ] \
  || fail "eviction order wrong: $(tr '\n' ' ' < "$BUDGET_LOG")"
! grep -q "image rm used:1\|image rm $u" "$BUDGET_LOG" || fail 'an image in use was offered for removal'
[ -e "$BUDGET_STATE/images/u" ] && [ -e "$BUDGET_STATE/images/c" ] || fail 'in-use or newest image was removed'
record="$(cat "$tmp/record/state.json")"
[[ "$record" =~ ^\{\"schema\":1,\"at\":[0-9]+,\"budget_bytes\":25000000000,\"before_bytes\":48000000000,\"after_bytes\":24000000000,\"other_bytes\":1500,\"evicted_images\":2,\"evicted_images_total\":2,\"skipped_in_use\":0,\"build_cache_pruned\":true,\"over_budget\":false,\"complete\":true\}$ ]] \
  || fail "record shape or values wrong: $record"
grep -q 'removed 2 unused image' "$tmp/output" || fail 'eviction not reported in the job log'

# An image a container used recently is evicted after images unused for longer,
# even when its tag time is older: pulls do not update the tag time.
gone=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
reset_store 8; printf '%s 2026-11-17T00:00:00\n%s 2026-11-17T00:00:00\n' "$a" "$gone" > "$tmp/record/last-used"; run
! grep -q "^$gone " "$tmp/record/last-used" || fail 'an image no longer present stayed in the last-used file'
[ "$(grep -o 'image rm [^ ]*' "$BUDGET_LOG" | tr '\n' ' ')" = "image rm mid:1 image rm mid:2 image rm new:1 " ] \
  || fail "recent use did not delay eviction: $(tr '\n' ' ' < "$BUDGET_LOG")"
grep -q "^$u " "$tmp/record/last-used" || fail 'the image of an existing container was not noted as used'
! grep -q "^$b " "$tmp/record/last-used" || fail 'a removed image stayed in the last-used file'
rm -f "$tmp/record/last-used"

# Totals accumulate across ephemeral generations of the same slot.
reset_store 8; run
[[ "$(cat "$tmp/record/state.json")" == *'"evicted_images_total":6'* ]] || fail 'cumulative eviction count not kept'

# Still over after every unused image: all build cache goes and the record says so.
reset_store 8; rm -f "$tmp/record/state.json"; export CRF_DOCKER_STORE_BUDGET_BYTES=$((5 * 1000 * 1000 * 1000)); run || true
grep -q 'builder prune -a -f' "$BUDGET_LOG" || fail 'final build cache prune skipped'
[[ "$(cat "$tmp/record/state.json")" == *'"over_budget":true'* ]] || fail 'over-budget store reported as within budget'
grep -q 'budget pass incomplete' "$tmp/output" || fail 'over-budget result not visible in the job log'

# An unreadable size never escalates to eviction, and the record says the
# pass did not complete.
reset_store 8; rm -f "$tmp/record/state.json"; BUDGET_MODE=df-error run || true
! grep -q 'image rm\|builder prune' "$BUDGET_LOG" || fail 'eviction ran without a size reading'
[[ "$(cat "$tmp/record/state.json")" == *'"over_budget":false,"complete":false'* ]] || fail 'failed pass left no incomplete record, or claimed over budget'

# The typed API query measures images and build cache without docker system df
# (which walks volumes and container layers); shared cache is not counted.
reset_store 8; rm -f "$tmp/record/state.json"; export CRF_DOCKER_STORE_BUDGET_BYTES=$((25 * 1000 * 1000 * 1000)); FAST_API=1 run
grep -q '^curl df' "$BUDGET_LOG" || fail 'fast API path not used'
! grep -q 'system df' "$BUDGET_LOG" || fail 'docker system df ran although the API answered'
[[ "$(cat "$tmp/record/state.json")" == *'"after_bytes":24000000000,"other_bytes":0,'* ]] || fail "fast path measured wrongly: $(cat "$tmp/record/state.json")"
# A complete record from the last 15 minutes at no more than 75% of the budget
# skips measurement and keeps the record (the window cannot extend itself).
reset_store 2; rm -f "$tmp/record/state.json"; export CRF_DOCKER_STORE_BUDGET_BYTES=$((60 * 1000 * 1000 * 1000)); FAST_API=1 run
first="$(cat "$tmp/record/state.json")"
FAST_API=1 run
! grep -q 'curl df\|system df' "$BUDGET_LOG" || fail 'recent record well under budget was measured again'
[ "$(cat "$tmp/record/state.json")" = "$first" ] || fail 'skip rewrote the record'
grep -q '^image prune' "$BUDGET_LOG" || fail 'skip also skipped disposable job state'
# Under disk pressure the window never applies.
DF_PRESSURE=1 FAST_API=1 run
grep -q '^curl df' "$BUDGET_LOG" || fail 'skip window applied under disk pressure'
# A record for another budget, or an incomplete one, is measured again.
sed -i 's/"complete":true}/"complete":false}/' "$tmp/record/state.json"; FAST_API=1 run
grep -q '^curl df' "$BUDGET_LOG" || fail 'an incomplete record skipped measurement'
# The same record older than 15 minutes is measured again.
sed -i 's/"at":[0-9]*/"at":1/' "$tmp/record/state.json"; FAST_API=1 run
grep -q '^curl df' "$BUDGET_LOG" || fail 'stale record skipped measurement'
# Above 75% of the budget, every pass measures.
reset_store 8; rm -f "$tmp/record/state.json"; export CRF_DOCKER_STORE_BUDGET_BYTES=$((60 * 1000 * 1000 * 1000)); FAST_API=1 run
FAST_API=1 run
grep -q '^curl df' "$BUDGET_LOG" || fail 'a store near its budget skipped measurement'
# A timed-out API query does not fall back to the equally slow walk.
reset_store 8; rm -f "$tmp/record/state.json"; API_TIMEOUT=1 FAST_API=1 run || true
! grep -q 'system df' "$BUDGET_LOG" || fail 'timed-out API query fell back to docker system df'
# Without a budget the hook keeps its previous behavior.
reset_store 8; unset CRF_DOCKER_STORE_BUDGET_BYTES; run
! grep -q 'image rm\|builder prune\|system df' "$BUDGET_LOG" || fail 'budget pass ran without an opt-in'
printf 'docker store budget: oldest unused first, in-use kept, record and totals PASS\n'
