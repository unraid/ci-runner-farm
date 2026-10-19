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
curl() {
  local headers="" body="" inm="" url="" method=GET
  cat >/dev/null   # the PAT arrives on stdin, never in argv
  printf '%s\n' "$*" >> "$CURL_LOG"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -D) headers="$2"; shift ;;
      -o) body="$2"; shift ;;
      -X) method="$2"; shift ;;
      -H) case "$2" in If-None-Match:*) inm="${2#If-None-Match: }" ;; esac; shift ;;
      -m|-w|--config) shift ;;
      https://*) url="$1" ;;
    esac
    shift
  done
  {
    printf 'HTTP/2 %s\r\n' "${STATUS:-200}"
    printf 'x-ratelimit-remaining: %s\r\nx-ratelimit-reset: %s\r\nx-ratelimit-resource: core\r\n' "$REMAINING" "$NOW_RESET"
    [ -z "${NO_ETAG:-}" ] && printf 'etag: %s\r\n' "$ETAG"
  } > "$headers"
  if [ -n "${STATUS:-}" ]; then : > "$body"; printf '%s' "$STATUS"; return 0; fi
  if [ "$method" = GET ] && [ "$inm" = "$ETAG" ]; then : > "$body"; printf 304; return 0; fi
  printf '{"url":"%s","total_count":3}\n' "$url" > "$body"
  printf 200
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

echo "github rate budget: ok"
