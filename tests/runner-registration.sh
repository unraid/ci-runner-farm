#!/usr/bin/env bash
# GitHub runner registrations: every start registers under its own name so a
# quickly recreated ephemeral runner cannot collide with the previous runner's
# session; liveness, deregistration and job->slot mapping follow the exact
# name; and stale offline registrations are deleted in every fleet layout,
# never a busy, online, owned, or foreign one.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/cache"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'RUNNER REGISTRATION FAIL: %s\n' "$*" >&2; exit 1; }
host() { printf 'mockhost\n'; }
suffix_re='r[0-9a-f]{6}'

# ── Per-start names ──────────────────────────────────────────────────────────
n1="$(github_runner_instance_name ci-runner-build-12)"
n2="$(github_runner_instance_name ci-runner-build-12)"
printf '%s\n' "$n1" | grep -qxE "mockhost-ci-runner-build-12-$suffix_re" || fail "bad per-start name: $n1"
[ "$n1" != "$n2" ] || fail "two starts produced the same name"
od() { return 1; }    # no /dev/urandom reader: the fallback still yields a valid name
n3="$(github_runner_instance_name ci-runner-build-12)"
unset -f od
printf '%s\n' "$n3" | grep -qxE "mockhost-ci-runner-build-12-$suffix_re" || fail "fallback name invalid: $n3"
github_registration_of_slot ci-runner-build-12 "$n1" || fail "own per-start name not recognized"
github_registration_of_slot ci-runner-build-12 mockhost-ci-runner-build-12 || fail "legacy name not recognized"
for other in mockhost-ci-runner-build-1-rabcdef mockhost-ci-runner-build-12-rABCDEF \
             mockhost-ci-runner-build-12-r12345 otherhost-ci-runner-build-12-rabcdef \
             mockhost-ci-runner-build-12-rabcdef0 mockhost-ci-runner-build-120; do
  github_registration_of_slot ci-runner-build-12 "$other" && fail "foreign name $other treated as the slot's"
done

# The argv carries the name in both the environment and a label, and the name
# stays out of the config generation (it must not make every runner stale).
build='v3|build|ci-build|linux,x64|2|0|2|0|2|8g|builtin'
RUNNER_MODE=pools RUNNER_POOLS="$build" GH_SCOPE=org CI_PROVIDER=github
RUNNER_CPUS='' RUNNER_MEMORY=16g IMAGE_SOURCE=builtin IMAGE=''
CACHE_ROOT="$tmp/cache" CACHE_MOUNTS='' WORK_TMPFS_SIZE=1g
ACCESS_TOKEN='' NO_REGISTER=1 DIND=false SHARE_DOCKER_SOCK=false NETWORK_ISOLATION=off
pool_base_refresh
validate_runner_mode || fail "$POOL_CONFIG_ERROR"
pool_activate build || fail 'pool activation failed'
gen1="$(crf_confgen)"
github_build_args 12 ci-runner-build-12 || fail 'argv failed'
args1="$(printf '%s\n' "${ARGS[@]}")"
github_build_args 12 ci-runner-build-12 || fail 'second argv failed'
args2="$(printf '%s\n' "${ARGS[@]}")"
[ "$(crf_confgen)" = "$gen1" ] || fail 'per-start name changed the config generation'
env1="$(printf '%s\n' "$args1" | sed -n 's/^RUNNER_NAME=//p')"
label1="$(printf '%s\n' "$args1" | sed -n "s/^${GITHUB_RUNNER_NAME_LABEL}=//p")"
env2="$(printf '%s\n' "$args2" | sed -n 's/^RUNNER_NAME=//p')"
printf '%s\n' "$env1" | grep -qxE "mockhost-ci-runner-build-12-$suffix_re" || fail "argv runner name: $env1"
[ "$env1" = "$label1" ] || fail 'runner name label does not match the registered name'
[ "$env1" != "$env2" ] || fail 'recreated runner reused the previous registration name'

# ── Registration name of an existing container ───────────────────────────────
label_value=""
docker() {
  case "$1 $2" in
    'inspect -f') printf '%s\n' "$label_value" ;;
    *) return 1 ;;
  esac
}
label_value="mockhost-ci-runner-build-12-r0a1b2c"
[ "$(github_runner_registration_name ci-runner-build-12)" = mockhost-ci-runner-build-12-r0a1b2c ] \
  || fail 'labeled name not used'
for label_value in "" "<no value>" mockhost-ci-runner-build-1-r0a1b2c "evil|name" mockhost-ci-runner-build-12; do
  [ "$(github_runner_registration_name ci-runner-build-12)" = mockhost-ci-runner-build-12 ] \
    || fail "label '$label_value' not replaced by the legacy name"
done

# ── Inventory parsing ────────────────────────────────────────────────────────
inventory='{"total_count":3,"runners":[
{"id":11,"name":"mockhost-ci-runner-build-12-r0a1b2c","os":"Linux","status":"online","busy":true,"labels":[{"id":901,"name":"self-hosted","type":"read-only"},{"id":902,"name":"build","type":"custom"}]},
{"id":12,"name":"mockhost-ci-runner-build-12","os":"Linux","status":"offline","busy":false,"labels":[{"id":903,"name":"linux","type":"read-only"}]},
{"id":13,"name":"otherhost-ci-runner-build-12","os":"Linux","status":"offline","busy":false,"labels":[]}]}'
parsed="$(printf '%s' "$inventory" | github_parse_runner_statuses /orgs/example)"
[ "$parsed" = "mockhost-ci-runner-build-12-r0a1b2c|online|11|true|/orgs/example
mockhost-ci-runner-build-12|offline|12|false|/orgs/example
otherhost-ci-runner-build-12|offline|13|false|/orgs/example" ] || fail "inventory parsed wrongly: $parsed"

# ── Liveness follows the exact registration ──────────────────────────────────
ACCESS_TOKEN=test-token GH_OWNER=example GH_REPOS=''
printf '%s %s\n%s\n' "$(date +%s)" key "$parsed" > "$GITHUB_LIVENESS_CACHE"
label_value="mockhost-ci-runner-build-12-r0a1b2c"
[ "$(github_runner_liveness_status ci-runner-build-12)" = online ] \
  || fail 'liveness read the legacy registration instead of the current one'
label_value=""
[ "$(github_runner_liveness_status ci-runner-build-12)" = offline ] || fail 'legacy container liveness lost'

# ── Deregistration on removal ────────────────────────────────────────────────
api_log="$tmp/api.log"
slot_inventory='{"runners":[
{"id":21,"name":"mockhost-ci-runner-build-12-r0a1b2c","os":"Linux","status":"online","busy":false,"labels":[]},
{"id":22,"name":"mockhost-ci-runner-build-12-r111111","os":"Linux","status":"offline","busy":false,"labels":[]},
{"id":23,"name":"mockhost-ci-runner-build-12-r222222","os":"Linux","status":"offline","busy":true,"labels":[]},
{"id":24,"name":"mockhost-ci-runner-build-12-r333333","os":"Linux","status":"online","busy":false,"labels":[]},
{"id":25,"name":"mockhost-ci-runner-build-12","os":"Linux","status":"offline","busy":false,"labels":[]},
{"id":26,"name":"mockhost-ci-runner-build-1-r444444","os":"Linux","status":"offline","busy":false,"labels":[]},
{"id":27,"name":"otherhost-ci-runner-build-12-r555555","os":"Linux","status":"offline","busy":false,"labels":[]}]}'
gh_api() {
  printf '%s %s\n' "$1" "$2" >> "$api_log"
  case "$1 $2" in
    'GET /orgs/example/actions/runners?per_page=100') printf '%s\n' "$current_inventory" ;;
    DELETE*) [ "${delete_fails:-false}" = false ] ;;
    *) return 1 ;;
  esac
}
current_inventory="$slot_inventory"; : > "$api_log"
github_deregister_runner_api ci-runner-build-12 mockhost-ci-runner-build-12-r0a1b2c >/dev/null
deleted="$(sed -n 's|^DELETE /orgs/example/actions/runners/||p' "$api_log" | sort | tr '\n' ' ')"
[ "$deleted" = "21 22 25 " ] || fail "removal deleted the wrong registrations: $deleted"

# Removal reads the label before the container is gone.
label_value="mockhost-ci-runner-build-12-r0a1b2c"
removed=false
provider_stop_remove_container() { removed=true; label_value=""; }
github_deregister_runner_api() { printf '%s\n' "$2" > "$tmp/deregistered"; }
github_remove_runner ci-runner-build-12 false || fail 'remove failed'
[ "$removed" = true ] && [ "$(cat "$tmp/deregistered")" = mockhost-ci-runner-build-12-r0a1b2c ] \
  || fail 'removal deregistered without the per-start name'
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/providers/github.sh
host() { printf 'mockhost\n'; }
org_api() {
  printf '%s %s\n' "$1" "$2" >> "$api_log"
  case "$1 $2" in
    'GET /orgs/example/actions/runners?per_page=100') printf '%s\n' "$current_inventory" ;;
    DELETE*) [ "${delete_fails:-false}" = false ] ;;
    *) return 1 ;;
  esac
}
gh_api() { org_api "$@"; }

# ── Stale registrations in every layout ──────────────────────────────────────
owned_label="mockhost-ci-runner-build-12-r0a1b2c"
docker() {
  case "$1 $2" in
    'inspect -f')
      case "${*: -1}" in ci-runner-build-12) printf '%s\n' "$owned_label" ;; *) printf '\n' ;; esac ;;
    *) return 1 ;;
  esac
}
managed_names() { [ "${names_fail:-false}" = false ] || return 1; printf 'ci-runner-build-12\nci-runner-build-3\n'; }
rate_ok=true
gh_rate_allows_background() { [ "$rate_ok" = true ]; }
stale_inventory='{"runners":[
{"id":31,"name":"mockhost-ci-runner-build-12-r0a1b2c","os":"Linux","status":"offline","busy":false,"labels":[]},
{"id":32,"name":"mockhost-ci-runner-build-12","os":"Linux","status":"offline","busy":false,"labels":[]},
{"id":33,"name":"mockhost-ci-runner-build-3","os":"Linux","status":"offline","busy":false,"labels":[]},
{"id":34,"name":"mockhost-ci-runner-build-9-r999999","os":"Linux","status":"offline","busy":false,"labels":[]},
{"id":35,"name":"mockhost-ci-runner-build-8-r888888","os":"Linux","status":"offline","busy":true,"labels":[]},
{"id":36,"name":"mockhost-ci-runner-build-7-r777777","os":"Linux","status":"online","busy":false,"labels":[]},
{"id":37,"name":"otherhost-ci-runner-build-9-r999999","os":"Linux","status":"offline","busy":false,"labels":[]},
{"id":38,"name":"mockhost-unrelated-runner","os":"Linux","status":"offline","busy":false,"labels":[]}]}'
expire_cache() { local at; read -r at _ < "$GITHUB_LIVENESS_CACHE"; printf '%s %s\n' "$((at - GITHUB_LIVENESS_TTL - 1))" stale > "$GITHUB_LIVENESS_CACHE"; }
refresh_generation() { rm -f "$GITHUB_LIVENESS_CACHE"; sleep 1; }
deletes() { sed -n 's|^DELETE /orgs/example/actions/runners/||p' "$api_log" | sort -n | tr '\n' ' '; }

current_inventory="$stale_inventory"; : > "$api_log"; rm -f "$GITHUB_LIVENESS_CACHE" "$CRF_RUNDIR"/github-stale-registration.*
github_reap_stale_registrations >/dev/null || fail 'first stale pass failed'
[ -z "$(deletes)" ] || fail "deleted after a single offline reading: $(deletes)"
github_reap_stale_registrations >/dev/null || fail 'cached stale pass failed'
[ -z "$(deletes)" ] || fail 'the same inventory generation counted twice'
refresh_generation
github_reap_stale_registrations >/dev/null || fail 'second stale pass failed'
# 32: legacy name of a slot whose container now has a per-start name. 34: no container.
[ "$(deletes)" = "32 34 " ] || fail "stale pass deleted the wrong registrations: $(deletes)"

# Repository scope deletes through the repository that owns the registration.
GH_SCOPE=repo GH_REPOS='example/one'
gh_api() {
  printf '%s %s\n' "$1" "$2" >> "$api_log"
  case "$1 $2" in
    'GET /repos/example/one/actions/runners?per_page=100') printf '%s\n' '{"runners":[{"id":41,"name":"mockhost-ci-runner-build-9-r999999","os":"Linux","status":"offline","busy":false,"labels":[]}]}' ;;
    DELETE*) return 0 ;;
    *) return 1 ;;
  esac
}
: > "$api_log"; rm -f "$GITHUB_LIVENESS_CACHE" "$CRF_RUNDIR"/github-stale-registration.*
github_reap_stale_registrations >/dev/null; refresh_generation; github_reap_stale_registrations >/dev/null
grep -qx 'DELETE /repos/example/one/actions/runners/41' "$api_log" || fail "repo-scope delete used the wrong base: $(cat "$api_log")"
GH_SCOPE=org GH_REPOS=''
gh_api() { org_api "$@"; }

# Bounded: at most one batch per pass.
many='{"runners":['
for i in $(seq 1 12); do many="$many{\"id\":$((100 + i)),\"name\":\"mockhost-ci-runner-build-50-r$(printf '%06x' "$i")\",\"os\":\"Linux\",\"status\":\"offline\",\"busy\":false,\"labels\":[]},"; done
many="${many%,}]}"
current_inventory="$many"; : > "$api_log"; rm -f "$GITHUB_LIVENESS_CACHE" "$CRF_RUNDIR"/github-stale-registration.*
github_reap_stale_registrations >/dev/null; refresh_generation; github_reap_stale_registrations >/dev/null
[ "$(grep -c '^DELETE' "$api_log")" -eq "$GITHUB_STALE_REGISTRATION_BATCH" ] || fail "batch bound not applied: $(grep -c '^DELETE' "$api_log")"
# Persistently failing deletes count toward the bound, and the least recently
# attempted registrations go first, so none is starved however many fail.
many='{"runners":['
for i in $(seq 1 25); do many="$many{\"id\":$((200 + i)),\"name\":\"mockhost-ci-runner-build-51-r$(printf '%06x' "$i")\",\"os\":\"Linux\",\"status\":\"offline\",\"busy\":false,\"labels\":[]},"; done
many="${many%,}]}"
current_inventory="$many"; : > "$api_log"; rm -f "$GITHUB_LIVENESS_CACHE" "$CRF_RUNDIR"/github-stale-registration.*
delete_fails=true
github_reap_stale_registrations >/dev/null 2>&1 || true
for pass in 1 2 3; do
  : > "$api_log"; refresh_generation; github_reap_stale_registrations >/dev/null 2>&1 || true
  [ "$(grep -c '^DELETE' "$api_log")" -eq "$GITHUB_STALE_REGISTRATION_BATCH" ] \
    || fail "pass $pass: failed deletes not bounded: $(grep -c '^DELETE' "$api_log")"
  cat "$api_log" >> "$tmp/all-attempts"
done
attempted="$(sed -n 's|^DELETE /orgs/example/actions/runners/||p' "$tmp/all-attempts" | sort -un | wc -l | tr -d ' ')"
[ "$attempted" -eq 25 ] || fail "persistently failing deletes starved later registrations: $attempted of 25 attempted in 3 passes"
delete_fails=false

# A registration that comes back online is forgotten, not deleted later.
current_inventory="$stale_inventory"; : > "$api_log"; rm -f "$GITHUB_LIVENESS_CACHE" "$CRF_RUNDIR"/github-stale-registration.*
github_reap_stale_registrations >/dev/null
[ -f "$CRF_RUNDIR/github-stale-registration.34" ] || fail 'first offline reading not recorded'
current_inventory="${stale_inventory//\"id\":34,\"name\":\"mockhost-ci-runner-build-9-r999999\",\"os\":\"Linux\",\"status\":\"offline\"/\"id\":34,\"name\":\"mockhost-ci-runner-build-9-r999999\",\"os\":\"Linux\",\"status\":\"online\"}"
refresh_generation; github_reap_stale_registrations >/dev/null
[ ! -f "$CRF_RUNDIR/github-stale-registration.34" ] || fail 'online registration kept its offline count'
grep -q 'runners/34$' "$api_log" && fail 'deleted a registration that came back online'

# Failures never delete blindly.
current_inventory="$stale_inventory"; : > "$api_log"; rm -f "$GITHUB_LIVENESS_CACHE" "$CRF_RUNDIR"/github-stale-registration.*
names_fail=true
if github_reap_stale_registrations >/dev/null 2>&1; then fail 'container enumeration failure reported success'; fi
[ ! -s "$api_log" ] || fail 'stale pass called GitHub without knowing the owned registrations'
names_fail=false; rate_ok=false
github_reap_stale_registrations >/dev/null || fail 'rate reserve treated as failure'
[ ! -s "$api_log" ] || fail 'stale pass spent the rate reserve'
rate_ok=true; delete_fails=true
github_reap_stale_registrations >/dev/null; refresh_generation
if github_reap_stale_registrations >/dev/null 2>&1; then fail 'failed delete reported success'; fi
[ -f "$CRF_RUNDIR/github-stale-registration.34" ] || fail 'failed delete forgot the registration'
delete_fails=false
CI_PROVIDER=gitlab; : > "$api_log"
github_reap_stale_registrations >/dev/null && [ ! -s "$api_log" ] || fail 'ran for a non-GitHub farm'
CI_PROVIDER=github

# ── Job -> slot mapping strips only the per-start suffix ─────────────────────
NAME_PREFIX=ci-runner-build
gh_api() {
  cat <<'JSON'
{
  "jobs": [
    {
      "id": 501,
      "conclusion": "failure",
      "runner_name": "mockhost-ci-runner-build-12-r0a1b2c"
    },
    {
      "id": 502,
      "conclusion": "failure",
      "runner_name": "mockhost-ci-runner-build-4"
    },
    {
      "id": 503,
      "conclusion": "failure",
      "runner_name": "mockhost-ci-runner-build-5-rzzzzzz"
    },
    {
      "id": 504,
      "conclusion": "failure",
      "runner_name": "otherhost-ci-runner-build-6-r0a1b2c"
    }
  ]
}
JSON
}
mapped="$(github_failed_local_jobs example/one 1 | tr '\n' ' ')"
[ "$mapped" = "501|ci-runner-build-12 502|ci-runner-build-4 " ] || fail "job to slot mapping wrong: $mapped"

grep -q 'github_reap_stale_registrations' <(declare -f lifecycle_tick) || fail 'lifecycle tick does not clean stale registrations'
echo "runner-registration: ok"
