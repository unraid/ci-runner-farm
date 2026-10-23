#!/usr/bin/env bash
# GitHub REST budget: GETs revalidate with ETags (a 304 is free), every response
# records the core rate limit, and background readers stop above the reserve.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'GITHUB RATE BUDGET FAIL: %s\n' "$*" >&2; exit 1; }

ACCESS_TOKEN='github_pat_long_lived_secret_1234567890'
GH_REPOS='example/one example/two'
NOW_RESET=$(( $(date +%s) + 3600 ))
CURL_LOG="$tmp/curl.log"; : > "$CURL_LOG"
REMAINING=4000
ETAG='W/"run-list-v1"'

# Minimal curl: honours -D/-o/-w, answers 304 to a matching If-None-Match.
# With REMAINING_FILE set, each request spends one from a shared counter.
curl() {
  local headers="" body="" inm="" url="" method=GET write_code=0
  cat >/dev/null   # the PAT arrives on stdin, never in argv
  printf '%s\n' "$*" >> "$CURL_LOG"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -D) headers="$2"; shift ;;
      -o) body="$2"; shift ;;
      -X) method="$2"; shift ;;
      -w) write_code=1; shift ;;
      -H) case "$2" in If-None-Match:*) inm="${2#If-None-Match: }" ;; esac; shift ;;
      -m|--config|--max-filesize) shift ;;
      https://*) url="$1" ;;
    esac
    shift
  done
  local remaining="$REMAINING"
  if [ -n "${REMAINING_FILE:-}" ]; then
    # Parallel requests share the counter; serialize read-decrement-write.
    until mkdir "$REMAINING_FILE.lock" 2>/dev/null; do sleep 0.01; done
    remaining=$(( $(cat "$REMAINING_FILE") - 1 )); echo "$remaining" > "$REMAINING_FILE"
    rmdir "$REMAINING_FILE.lock"
  fi
  [ -z "$headers" ] || {
    printf 'HTTP/2 %s\r\n' "${STATUS:-200}"
    printf 'x-ratelimit-remaining: %s\r\nx-ratelimit-reset: %s\r\nx-ratelimit-resource: core\r\n' "$remaining" "$NOW_RESET"
    [ -z "${NO_ETAG:-}" ] && printf 'etag: %s\r\n' "$ETAG"
  } > "$headers"
  : "${body:=/dev/stdout}"
  if [ -n "${STATUS:-}" ]; then : > "$body"; [ "$write_code" = 0 ] || printf '%s' "$STATUS"; return 0; fi
  if [ "$method" = GET ] && [ "$inm" = "$ETAG" ]; then : > "$body"; [ "$write_code" = 0 ] || printf 304; return 0; fi
  printf '{"url":"%s","total_count":3}\n' "$url" > "$body"
  [ "$write_code" = 0 ] || printf 200
}

path='/repos/example/one/actions/runs?status=queued&per_page=1'
first="$(gh_api GET "$path")" || fail "first GET failed"
case "$first" in *'"total_count":3'*) ;; *) fail "first GET body missing: $first" ;; esac
grep -q 'If-None-Match' "$CURL_LOG" && fail "first GET was conditional without a cache entry"

: > "$CURL_LOG"
second="$(gh_api GET "$path")" || fail "revalidated GET failed"
[ "$second" = "$first" ] || fail "304 did not replay the cached body"
grep -qF "If-None-Match: $ETAG" "$CURL_LOG" || fail "second GET did not send the cached ETag"
if grep -qF "$ACCESS_TOKEN" "$CURL_LOG"; then fail "PAT leaked into curl argv"; fi

# The path line guards a cache-key collision: a foreign entry is never revalidated.
cache="$(gh_etag_file "$path")"
{ printf '%s\n%s\n' '/repos/other/path' "$ETAG"; printf 'foreign body\n'; } > "$cache"
: > "$CURL_LOG"
third="$(gh_api GET "$path")" || fail "GET after a foreign entry failed"
grep -q 'If-None-Match' "$CURL_LOG" && fail "foreign cache entry was used for revalidation"
case "$third" in *'"total_count":3'*) ;; *) fail "foreign entry body was returned" ;; esac

# Errors produce no output and no cache entry; POSTs are never cached.
STATUS=404 gh_api GET '/repos/example/missing' >"$tmp/out" && fail "404 returned success"
[ ! -s "$tmp/out" ] || fail "404 produced output"
[ ! -e "$(gh_etag_file '/repos/example/missing')" ] || fail "404 was cached"
STATUS=201 gh_api POST '/orgs/example/actions/runners/registration-token' >/dev/null || fail "201 POST failed"
[ ! -e "$(gh_etag_file '/orgs/example/actions/runners/registration-token')" ] || fail "POST was cached"
NO_ETAG=1 gh_api GET '/repos/example/no-etag' >/dev/null || fail "GET without ETag failed"
[ ! -e "$(gh_etag_file '/repos/example/no-etag')" ] || fail "response without ETag was cached"

# Rate-limit observations gate background readers until the reset.
read -r seen_remaining seen_reset < "$CRF_RUNDIR/gh-ratelimit"
[ "$seen_remaining" = 4000 ] && [ "$seen_reset" = "$NOW_RESET" ] || fail "rate limit was not recorded"
gh_rate_allows_background || fail "background reader blocked with ample budget"
REMAINING=499 gh_api GET '/repos/example/two' >/dev/null || fail "low-budget GET failed"
gh_rate_allows_background && fail "background reader allowed below the reserve"
printf '10 %s\n' "$(( $(date +%s) - 1 ))" > "$CRF_RUNDIR/gh-ratelimit"
gh_rate_allows_background || fail "background reader still blocked after the reset"

# Below the reserve the Fleet counts keep their last snapshot and the poison
# scan spends nothing.
printf '10 %s\n' "$NOW_RESET" > "$CRF_RUNDIR/gh-ratelimit"
echo "github 1700000000 7" > "$CRF_RUNDIR/queued.cache"
: > "$CURL_LOG"
github_queued_refresh
github_stats_refresh
[ "$(cat "$CRF_RUNDIR/queued.cache")" = "github 1700000000 7" ] || fail "queued refresh overwrote its snapshot below the reserve"
DIND=true POISON_SCAN_INTERVAL=0 github_build_poison_scan || fail "gated poison scan failed"
[ ! -s "$CURL_LOG" ] || fail "background readers called GitHub below the reserve"

# Above the reserve the queued count is summed from (revalidated) responses.
rm -f "$CRF_RUNDIR/gh-ratelimit"
github_queued_refresh
read -r _ _ queued < "$CRF_RUNDIR/queued.cache"
[ "$queued" = 6 ] || fail "queued refresh summed $queued, want 6"

# Out-of-order responses: the lowest count in a reset window wins, and an
# older window never replaces a newer one.
record_remaining() {
  printf 'x-ratelimit-remaining: %s\r\nx-ratelimit-reset: %s\r\nx-ratelimit-resource: core\r\n' "$1" "$2" > "$tmp/h"
  gh_rate_record "$tmp/h"
}
rm -f "$CRF_RUNDIR/gh-ratelimit"
record_remaining 400 "$NOW_RESET"
record_remaining 450 "$NOW_RESET"
[ "$(cat "$CRF_RUNDIR/gh-ratelimit")" = "400 $NOW_RESET" ] || fail "late response restored a higher remaining count"
record_remaining 4900 "$((NOW_RESET + 3600))"
[ "$(cat "$CRF_RUNDIR/gh-ratelimit")" = "4900 $((NOW_RESET + 3600))" ] || fail "new reset window was not recorded"
record_remaining 10 "$NOW_RESET"
[ "$(cat "$CRF_RUNDIR/gh-ratelimit")" = "4900 $((NOW_RESET + 3600))" ] || fail "older reset window replaced a newer one"

# A background fetch stops launching batches once the reserve is reached and
# the caller keeps its previous snapshot instead of a partial count.
rm -f "$CRF_RUNDIR/gh-ratelimit"
echo "github 1700000000 7" > "$CRF_RUNDIR/queued.cache"
echo 503 > "$tmp/remaining"
: > "$CURL_LOG"
GH_REPOS='r/1 r/2 r/3 r/4 r/5 r/6 r/7 r/8 r/9 r/10'
REMAINING_FILE="$tmp/remaining" github_queued_refresh
calls=$(( $(wc -l < "$CURL_LOG") ))
# One batch of 8 drops the count from 503 to 495, below the 500 reserve, so
# the second batch never starts.
[ "$calls" = 8 ] || fail "background fetch made $calls requests, want one batch of 8"
[ "$(cat "$CRF_RUNDIR/queued.cache")" = "github 1700000000 7" ] || fail "blocked refresh published a partial count"
GH_REPOS='example/one example/two'

# Every poison-scan request is gated: the scan stops once a response records
# a count below the reserve, not only at its start.
rm -f "$CRF_RUNDIR/gh-ratelimit" "$CRF_RUNDIR/poison-scan.stamp"
echo 501 > "$tmp/remaining"
: > "$CURL_LOG"
GH_REPOS='p/1 p/2 p/3 p/4' REMAINING_FILE="$tmp/remaining" DIND=true POISON_SCAN_INTERVAL=0 github_build_poison_scan \
  || fail "gated poison scan failed"
calls=$(( $(wc -l < "$CURL_LOG") ))
[ "$calls" = 2 ] || fail "poison scan made $calls requests, want 2 (500 then 499 remaining)"

# Job-log downloads honour the reserve and record their rate-limit headers.
printf '10 %s\n' "$NOW_RESET" > "$CRF_RUNDIR/gh-ratelimit"
: > "$CURL_LOG"
status=0; GH_API_BACKGROUND=1 github_job_log_poisoned example/one 700001 || status=$?
[ "$status" = 2 ] || fail "job log below the reserve returned $status, want 2 (retry later)"
[ ! -s "$CURL_LOG" ] || fail "job log was downloaded below the reserve"
rm -f "$CRF_RUNDIR/gh-ratelimit"
status=0; REMAINING=3210 GH_API_BACKGROUND=1 github_job_log_poisoned example/one 700001 || status=$?
[ "$status" = 1 ] || fail "ordinary job log returned $status, want 1 (no signature)"
grep -q -- '-D' "$CURL_LOG" || fail "job log request did not capture headers"
[ "$(cut -d' ' -f1 "$CRF_RUNDIR/gh-ratelimit")" = 3210 ] || fail "job log rate limit was not recorded"

echo "github rate budget: ok"
