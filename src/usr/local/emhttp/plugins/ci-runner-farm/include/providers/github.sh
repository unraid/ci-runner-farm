#!/bin/bash
# GitHub Actions provider adapter for CI Runner Farm.
# Sourced by runner-farm.sh after configuration and common helpers are loaded.

github_token_ready() { [ -n "$ACCESS_TOKEN" ]; }
github_token_name()  { if [ "$GITHUB_APP_MODE" = true ]; then echo "GitHub App installation token"; else echo "GitHub token"; fi; }
github_builtin_image() { echo "$BUILTIN_IMAGE"; }
github_validate_settings() {
  github_validate_docker_cache_policy && crf_validate_user_share_mounts && crf_shared_cache_mount
}
github_validate_docker_cache_policy() {
  [ "$DIND" = true ] && [ "$EPHEMERAL" = false ] && [ -n "${DOCKER_CACHE_BUILDERS:-}" ] || return 0
  local -a pressure_builders
  [ "${#DOCKER_CACHE_BUILDERS}" -le 1024 ] && [[ "$DOCKER_CACHE_BUILDERS" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}(,[A-Za-z0-9][A-Za-z0-9_.-]{0,63})*$ ]] \
    || { err "invalid Docker cache builder allowlist"; return 1; }
  [[ "$DOCKER_CACHE_MIN_FREE_PERCENT" =~ ^(0|[1-9][0-9]?|100)$ ]] \
    || { err "invalid Docker cache free-space threshold"; return 1; }
  IFS=, read -r -a pressure_builders <<< "$DOCKER_CACHE_BUILDERS"
  [ "${#pressure_builders[@]}" -le 32 ] \
    || { err "too many Docker cache builder names"; return 1; }
}
github_strict_endpoint() { return 0; }
github_imageupdate_pull() { return 1; }
github_remote_image_host_pull_required() { return 0; }
github_prepare_remote_image() { registry_login && host_docker_pull "$1"; }
github_remote_image_update_allowed() { return 0; }
github_stop_cleanup() { return 0; }
github_docker_stopping_timeout() { echo 0; }
github_docker_stopping() { return 0; }

github_kvm_gid() {
  local mode
  [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] || return 1
  mode="$(stat -c '%a' /dev/kvm)" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0060) == 0060 )) || return 1
  stat -c '%g' /dev/kvm
}

# CPU pinning applies to a slot only when it is enabled and the slot has a
# whole-number CPU limit to size its cpuset from.
github_cpu_pinning_applies() {
  [ "${CPU_PINNING:-false}" = true ] && [[ "$RUNNER_CPUS" =~ ^[1-9][0-9]{0,3}$ ]]
}

github_confgen() {
  # Include the DinD runtime contract in the fingerprint. Changing Docker's
  # cgroup namespace for existing slots must drain and recreate them; otherwise
  # an old container can remain online with the broken hierarchy.
  local runtime_salt='' kvm_gid cache_spec
  [ "$DIND" = true ] && runtime_salt='github-dind-cgroupns-v1'
  if [ "$DIND" = true ] && [ "$EPHEMERAL" = false ]; then
    runtime_salt="${runtime_salt}-job-cache-cleanup-v3"
    [ -z "${DOCKER_CACHE_BUILDERS:-}" ] || runtime_salt="${runtime_salt}-cache-pressure-v1-${DOCKER_CACHE_MIN_FREE_PERCENT:-15}-${DOCKER_CACHE_BUILDERS}"
  fi
  # The explicit store contract must replace existing slots through the normal
  # drain lifecycle. Farms without a pnpm-store mount keep their fingerprint.
  for cache_spec in $CACHE_MOUNTS; do
    case "$cache_spec" in
      pnpm-store:*) runtime_salt="${runtime_salt}-pnpm-store-v1"; break ;;
    esac
  done
  [ -z "$SHARED_CACHE_ROOT" ] || runtime_salt="${runtime_salt}-shared-cache-v1-${SHARED_CACHE_ROOT}"
  # Enabling CPU pinning recreates slots that can be pinned through the normal
  # drain. The chosen cpuset is placement, not configuration, so it stays out;
  # farms without pinning keep their fingerprint.
  github_cpu_pinning_applies && runtime_salt="${runtime_salt}-cpu-pinning-v1"
  case ",$RUNNER_LABELS," in
    *,kvm,*)
      kvm_gid="$(github_kvm_gid 2>/dev/null || true)"
      runtime_salt="${runtime_salt}-kvm-routing-role-v1-${kvm_gid:-missing}"
      ;;
  esac
  printf '%s\0' "$runtime_salt" "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" "$RUNNER_GROUP" "$RUNNER_LABELS" \
    "$EPHEMERAL" "$RUNNER_CPUS" "$RUNNER_MEMORY" "$WORK_TMPFS_SIZE" "$CACHE_MOUNTS" \
    "$USER_SHARE_MOUNTS" \
    "$DIND" "$SHARE_DOCKER_SOCK" "$RUN_AS_ROOT" "$IMAGE_SOURCE" "$IMAGE" \
    "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" \
    "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" \
    | sha256sum | cut -c1-12
}

# Status sampling runs outside the fleet lock. Never spawn an exec that can
# race native freeze; observe the captured owner from the host instead. These
# display states do not authorize withdrawal or replace the provider's proof.
github_shared_runner_state() {
  local snapshot id provider role index gen state processes phase
  snapshot="$(managed_runner_snapshot "$1")" || { echo starting; return; }
  IFS='|' read -r id provider role index gen <<< "$snapshot"
  [ "$provider" = github ] && [ "$role" = runner ] || { echo starting; return; }
  state="$(timeout 10 docker inspect --format '{{.State.Status}}|{{.State.Paused}}' "$id" 2>/dev/null)" \
    || { echo starting; return; }
  case "$state" in
    running\|true) echo paused; return ;;
    running\|false) ;;
    *) echo starting; return ;;
  esac
  processes="$(timeout 10 docker top "$id" -eo pid,comm 2>/dev/null)" \
    || { echo starting; return; }
  phase="$(printf '%s\n' "$processes" | awk '
    NR==1 { if (NF!=2 || $1!="PID" || $2!="COMMAND") bad=1; next }
    NF!=2 || $1!~/^[0-9]+$/ || $1==0 { bad=1 }
    NF==2 && $1~/^[0-9]+$/ && $1>0 && $2=="Runner.Worker" { workers++ }
    $2=="Runner.Listener" { listeners++ }
    END {
      if (workers) print "busy";
      else if (!bad && listeners==1) print "idle";
      else print "starting";
    }')"
  printf '%s\n' "$phase"
}

github_runner_state() {
  if shared_capacity_enabled; then github_shared_runner_state "$1"; return; fi
  local c="$1" p
  p="$(docker exec "$c" sh -c 'pgrep -x Runner.Worker >/dev/null 2>&1 && echo busy || { pgrep -x Runner.Listener >/dev/null 2>&1 && echo idle; }' 2>/dev/null)"
  case "$p" in busy) echo busy; return;; idle) echo idle; return;; esac
  case "$(docker logs --tail 15 "$c" 2>&1 | grep -iE 'Running job|Listening for Jobs|Job .* completed|error' | tail -1)" in
    *"Running job"*)                      echo busy ;;
    *"Listening for Jobs"*|*"completed"*) echo idle ;;
    *[Ee]rror*)                           echo error ;;
    *)                                    echo starting ;;
  esac
}

# GitHub's runner cancellation signal stops the step process, but a process can
# have already created detached containers in the runner's private DinD daemon.
# Run cleanup only after the runner reports idle. The inner check repeats that
# guard before it mutates Docker, then verifies that no containers remain. It
# removes containers, not images or volumes, so the layer cache stays intact.
github_job_scope_clean() {
  local c="$1"
  timeout 120 docker exec "$c" sh -c '
    command -v pgrep >/dev/null 2>&1 && pgrep -x Runner.Worker >/dev/null 2>&1 && exit 20
    command -v docker >/dev/null 2>&1 || exit 0
    ids="$(docker ps --all --quiet 2>/dev/null)" || exit 21
    [ -z "$ids" ] && exit 0
    docker rm --force $ids >/dev/null 2>&1 || exit 22
    command -v pgrep >/dev/null 2>&1 && pgrep -x Runner.Worker >/dev/null 2>&1 && exit 20
    [ -z "$(docker ps --all --quiet 2>/dev/null)" ]
  ' >/dev/null 2>&1
}

# Check the outer runner cgroup after cleanup. This catches a detached process
# that did not come from a Docker container. Unknown cgroup data is not a
# failure because older custom images can omit the pids files.
github_runner_pid_pressure() {
  local c="$1" current limit
  current="$(timeout 10 docker exec "$c" sh -c 'cat /sys/fs/cgroup/pids.current' 2>/dev/null)" || return 2
  limit="$(docker inspect -f '{{.HostConfig.PidsLimit}}' "$c" 2>/dev/null)" || return 2
  case "$current" in ''|*[!0-9]*) return 2 ;; esac
  case "$limit" in ''|*[!0-9]*|0) return 2 ;; esac
  [ "$((current * 100))" -ge "$((limit * LIFECYCLE_PID_PRESSURE_PERCENT))" ]
}

# Only a positively exited Docker owner may be recycled by the legacy watchdog.
# A missing Worker or an old completion log cannot close GitHub job admission.
# Job-boundary hooks own cleanup while a runner is live. Shared pools use their
# fenced withdrawal protocol instead of this legacy watchdog.
github_runner_exited() {
  local state
  state="$(docker inspect -f '{{.State.Status}}|{{.State.Running}}|{{.State.Paused}}|{{.State.Restarting}}|{{.State.Pid}}' "$1" 2>/dev/null)" || return 1
  [ "$state" = 'exited|false|false|false|0' ]
}

github_lifecycle_candidate() {
  local names c snapshot id provider role index gen marker marked_id count
  names="$(managed_names)" || return 1
  for c in $names; do
    [ -n "$c" ] || continue
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    [ "$provider" = github ] && [ "$role" = runner ] || continue
    marker="$RUNDIR/github-lifecycle.$c"
    if ! github_runner_exited "$id"; then
      rm -f "$marker" 2>/dev/null || true
      continue
    fi
    marked_id=""; count=0
    [ -f "$marker" ] && read -r marked_id count < "$marker"
    [ "$marked_id" = "$id" ] || count=0
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    count=$((count + 1))
    printf '%s %s\n' "$id" "$count" > "$marker"
    if [ "$count" -ge "$LIFECYCLE_CONFIRMATIONS" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
}

# Docker can report a healthy listener after its GitHub control-plane session
# becomes stale. Keep a short host-side inventory cache so autoscale can detect
# that mismatch without placing the long-lived PAT in the runner container.
GITHUB_LIVENESS_CACHE="${RUNDIR}/github-runners.cache"
GITHUB_LIVENESS_TTL=300 # seconds between GitHub liveness refreshes
GITHUB_OFFLINE_CONFIRMATIONS=2

github_parse_runner_statuses() {
  tr ',' '\n' | awk '
    /"name"[[:space:]]*:/ {
      s=$0
      sub(/^[^:]*:[[:space:]]*"/, "", s)
      sub(/".*/, "", s)
      runner_name=s
    }
    /"status"[[:space:]]*:/ {
      s=$0
      sub(/^[^:]*:[[:space:]]*"/, "", s)
      sub(/".*/, "", s)
      if (runner_name != "") {
        print runner_name "|" s
        runner_name=""
      }
    }'
}

github_runner_liveness_refresh() {
  local now expected_key cached_at cached_key age tmp body valid=0 repo url
  now="$(date +%s)"
  expected_key="$(printf '%s\0' "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" | sha256sum | cut -c1-12)"
  if [ -f "$GITHUB_LIVENESS_CACHE" ]; then
    read -r cached_at cached_key < "$GITHUB_LIVENESS_CACHE"
    case "$cached_at" in ''|*[!0-9]*) ;; *)
      age=$((now - cached_at))
      [ "$age" -ge 0 ] && [ "$age" -le "$GITHUB_LIVENESS_TTL" ] \
        && [ "$cached_key" = "$expected_key" ] && return 0
      ;;
    esac
  fi
  tmp="$(mktemp "$RUNDIR/github-liveness.XXXXXX" 2>/dev/null)" || return 1
  if [ "$GH_SCOPE" = org ]; then
    url="/orgs/${GH_OWNER}/actions/runners?per_page=100"
    body="$(gh_api GET "$url")" || { rm -f "$tmp"; return 1; }
    case "$body" in *'"runners"'*) valid=1 ;; esac
    printf '%s' "$body" | github_parse_runner_statuses >> "$tmp"
  else
    for repo in $GH_REPOS; do
      [ -n "$repo" ] || continue
      url="/repos/${repo}/actions/runners?per_page=100"
      body="$(gh_api GET "$url")" || { rm -f "$tmp"; return 1; }
      case "$body" in *'"runners"'*) valid=1 ;; esac
      printf '%s' "$body" | github_parse_runner_statuses >> "$tmp"
    done
  fi
  [ "$valid" = 1 ] || { rm -f "$tmp"; return 1; }
  {
    printf '%s %s\n' "$now" "$expected_key"
    cat "$tmp"
  } > "${tmp}.cache" || { rm -f "$tmp" "${tmp}.cache"; return 1; }
  mv "${tmp}.cache" "$GITHUB_LIVENESS_CACHE" || { rm -f "$tmp" "${tmp}.cache"; return 1; }
  rm -f "$tmp"
}

github_runner_liveness_status() {
  local c="$1" wanted
  wanted="$(host)-${c}"
  awk -F'|' -v want="$wanted" '$1 == want { print $2; exit }' "$GITHUB_LIVENESS_CACHE" 2>/dev/null
}

github_runner_liveness_cache_timestamp() {
  awk 'NR == 1 { print $1; exit }' "$GITHUB_LIVENESS_CACHE" 2>/dev/null
}

github_offline_runner_confirmed() {
  local c="$1" status marker count=0 marker_at="" cache_at
  status="$(github_runner_liveness_status "$c")"
  marker="$RUNDIR/github-offline.${c}"
  case "$status" in
    online)
      rm -f "$marker"
      return 1
      ;;
    offline)
      if runner_busy "$c"; then
        rm -f "$marker"
        return 1
      fi
      cache_at="$(github_runner_liveness_cache_timestamp)"
      [ -n "$cache_at" ] || return 1
      [ -f "$marker" ] && read -r count marker_at < "$marker"
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      if [ "$marker_at" != "$cache_at" ]; then
        count=$((count + 1))
        printf '%s %s\n' "$count" "$cache_at" > "$marker"
      fi
      if [ "$count" -ge "$GITHUB_OFFLINE_CONFIRMATIONS" ]; then
        return 0
      fi
      log "autoscale: GitHub reports $c offline (confirmation $count/$GITHUB_OFFLINE_CONFIRMATIONS); retaining it"
      ;;
    *)
      rm -f "$marker"
      ;;
  esac
  return 1
}

github_scale_down_eligible() { ! runner_busy "$1"; }
github_autoscale_counts() {
  cur="$(current_count)" || return 1
  busy="$(busy_count)" || return 1
  idle=$((cur - busy))
}

github_repo_for_index() {
  local idx="$1"
  # shellcheck disable=SC2206  # GH_REPOS is deliberately space-separated.
  local arr=($GH_REPOS); local n=${#arr[@]}
  [ "$n" -eq 0 ] && { echo ""; return; }
  echo "${arr[$(( (idx-1) % n ))]}"
}

# GitHub REST budget. The farm PAT's hourly limit is shared by every host that
# holds it and by anything else the account runs, so two rules keep background
# polling from starving runner registration:
# - GETs are conditional. Each response is kept with its ETag under
#   $RUNDIR/gh-etag, and GitHub does not count a 304 against the limit, so an
#   unchanged run list or job list costs nothing to re-read.
# - Every response records the core x-ratelimit headers in $RUNDIR/gh-ratelimit.
#   Background readers (poison scan, Fleet queue and run counts) set
#   GH_API_BACKGROUND=1, which makes every one of their requests skip GitHub
#   (exit 3) while fewer than GH_API_RESERVE requests remain before the reset.
GH_API_RESERVE="${CRF_GH_API_RESERVE:-500}"
GH_ETAG_MAX_BYTES=262144

gh_header_value() {
  awk -v name="$2" 'tolower($1) == name ":" { sub(/^[^:]*:[[:space:]]*/, ""); value = $0 } END { print value }' "$1" 2>/dev/null \
    | tr -d '\r'
}

gh_rate_record() {
  local headers="$1" remaining reset resource tmpf
  resource="$(gh_header_value "$headers" x-ratelimit-resource)"
  [ -z "$resource" ] || [ "$resource" = core ] || return 0
  remaining="$(gh_header_value "$headers" x-ratelimit-remaining)"
  reset="$(gh_header_value "$headers" x-ratelimit-reset)"
  case "$remaining" in ''|*[!0-9]*) return 0 ;; esac
  case "$reset" in ''|*[!0-9]*) return 0 ;; esac
  # Parallel requests finish out of order. Keep the lowest count seen for a
  # reset window, and never let a response from an older window replace a
  # newer one, so a late reply cannot restore a higher remaining count.
  (
    command -v flock >/dev/null 2>&1 && flock -w 2 9
    local old_remaining old_reset
    if [ -f "$RUNDIR/gh-ratelimit" ] && read -r old_remaining old_reset < "$RUNDIR/gh-ratelimit"; then
      case "$old_remaining$old_reset" in *[!0-9]*) ;; *)
        [ "$old_reset" -gt "$reset" ] && exit 0
        [ "$old_reset" -eq "$reset" ] && [ "$old_remaining" -le "$remaining" ] && exit 0 ;;
      esac
    fi
    tmpf="$(mktemp "$RUNDIR/gh-ratelimit.XXXXXX" 2>/dev/null)" || exit 0
    if ! { printf '%s %s\n' "$remaining" "$reset" > "$tmpf" && mv -f "$tmpf" "$RUNDIR/gh-ratelimit"; }; then
      rm -f "$tmpf"
    fi
  ) 9>"$RUNDIR/gh-ratelimit.lock"
}

gh_rate_allows_background() {
  local remaining reset
  [ -f "$RUNDIR/gh-ratelimit" ] || return 0
  read -r remaining reset < "$RUNDIR/gh-ratelimit" 2>/dev/null || return 0
  case "$remaining" in ''|*[!0-9]*) return 0 ;; esac
  case "$reset" in ''|*[!0-9]*) return 0 ;; esac
  [ "$(date +%s)" -ge "$reset" ] && return 0
  [ "$remaining" -ge "$GH_API_RESERVE" ]
}

# Cache entry: line 1 the request path (guards against key collisions), line 2
# the ETag, then the body.
gh_etag_file() {
  printf '%s/gh-etag/%s\n' "$RUNDIR" "$(printf '%s' "$1" | cksum | awk '{ print $1 "-" $2 }')"
}

gh_etag_store() {
  local cache="$1" path="$2" headers="$3" body="$4" etag tmpf
  etag="$(gh_header_value "$headers" etag)"
  if [ -z "$etag" ] || [ "$(wc -c < "$body")" -gt "$GH_ETAG_MAX_BYTES" ]; then
    rm -f "$cache"; return 0
  fi
  mkdir -p "${cache%/*}" 2>/dev/null || return 0
  tmpf="$(mktemp "$cache.XXXXXX" 2>/dev/null)" || return 0
  if ! { { printf '%s\n%s\n' "$path" "$etag"; cat "$body"; } > "$tmpf" && mv -f "$tmpf" "$cache"; }; then
    rm -f "$tmpf"
  fi
}

gh_etag_prune() {
  find "$RUNDIR/gh-etag" -type f -mmin +1440 -delete 2>/dev/null || true
}

# Long-lived PATs remain host-side; curl reads credentials from stdin so they do
# not appear in /proc/<pid>/cmdline.
gh_api() {
  github_app_refresh
  [ -n "$ACCESS_TOKEN" ] || return 1
  if [ "${GH_API_BACKGROUND:-0}" = 1 ] && ! gh_rate_allows_background; then return 3; fi
  local method="$1" path="$2" work cache="" etag="" code rc=0
  local conditional=()
  work="$(mktemp -d "${TMPDIR:-/tmp}/crf-gh.XXXXXX" 2>/dev/null)" || return 1
  if [ "$method" = GET ]; then
    cache="$(gh_etag_file "$path")"
    # Snapshot the entry so a concurrent refresh cannot pair this ETag with
    # another body.
    if cp "$cache" "$work/cached" 2>/dev/null && [ "$(head -1 "$work/cached")" = "$path" ]; then
      etag="$(sed -n 2p "$work/cached")"
      [ -z "$etag" ] || conditional=(-H "If-None-Match: $etag")
    fi
  fi
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
    | curl -sSL -m "${GH_API_TIMEOUT:-10}" -X "$method" --config - \
      -H "Accept: application/vnd.github+json" "${conditional[@]}" \
      -D "$work/headers" -o "$work/body" -w '%{http_code}' \
      "https://api.github.com$path" 2>/dev/null)" || code=000
  gh_rate_record "$work/headers"
  case "$code" in
    304)
      if [ -n "$etag" ]; then tail -n +3 "$work/cached"; touch "$cache" 2>/dev/null || true; else rc=1; fi ;;
    2??)
      cat "$work/body" 2>/dev/null
      [ -z "$cache" ] || [ "$code" != 200 ] || gh_etag_store "$cache" "$path" "$work/headers" "$work/body" ;;
    *) rc=1 ;;
  esac
  rm -rf "$work"
  return "$rc"
}

github_registration_token() {
  local target="$1" path
  case "$target" in
    org:*)  path="/orgs/${target#org:}/actions/runners/registration-token" ;;
    repo:*) path="/repos/${target#repo:}/actions/runners/registration-token" ;;
    *) echo ""; return 1 ;;
  esac
  gh_api POST "$path" \
    | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

# Prove that the long-lived PAT can mint a token for the replacement target
# without retaining that short-lived token in Docker argv. A recycle can spend
# many hours draining an old GitLab manager, so the real registration token is
# minted only after removal; this probe keeps the pre-removal failure guard.
github_replacement_preflight() {
  local idx="$1" target repo probe
  if [ "$GH_SCOPE" = org ]; then
    target="org:$GH_OWNER"
  else
    repo="$(github_repo_for_index "$idx")"
    [ -n "$repo" ] || { err "no GitHub repository configured for slot $idx"; return 1; }
    target="repo:$repo"
  fi
  probe="$(github_registration_token "$target")"
  [ -n "$probe" ] \
    || { err "could not verify GitHub runner-registration permission for ${target#*:}"; return 1; }
}

github_deregister_runner_api() {
  local c="$1" rname idx repo base id
  [ -n "$ACCESS_TOKEN" ] && [ -n "$c" ] || return 0
  rname="$(host)-${c}"
  if [ "$GH_SCOPE" = "org" ]; then
    base="/orgs/${GH_OWNER}"
  else
    idx="${c##*-}"; repo="$(github_repo_for_index "$idx")"
    [ -n "$repo" ] || return 0
    base="/repos/${repo}"
  fi
  id="$(gh_api GET "${base}/actions/runners?per_page=100" | awk -v want="$rname" '
      /"id"[[:space:]]*:/   { if (match($0, /[0-9]+/)) cur = substr($0, RSTART, RLENGTH) }
      /"name"[[:space:]]*:/ { s=$0; sub(/^[^:]*:[[:space:]]*"/, "", s); sub(/".*/, "", s); nm=s }
      /"os"[[:space:]]*:/   { if (nm == want) { print cur; exit } }
    ')"
  [ -n "$id" ] || return 0
  if gh_api DELETE "${base}/actions/runners/${id}" >/dev/null 2>&1; then
    log "deregistered $rname from GitHub (id $id)"
  else
    log "warning: could not deregister $rname (id $id) from GitHub — a stale offline runner may linger"
  fi
}

# With GH_API_BACKGROUND=1, stop launching batches once the reserve is reached
# and return 3 so the caller keeps its previous snapshot instead of publishing
# a partial count.
github_fetch_all() {
  local suffix="$1" outdir="$2" maxpar="${3:-8}" timeout="${4:-10}"
  local n=0 r blocked=0
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    if [ "${GH_API_BACKGROUND:-0}" = 1 ] && [ $((n % maxpar)) -eq 0 ] && ! gh_rate_allows_background; then
      blocked=1; break
    fi
    n=$((n+1))
    GH_API_TIMEOUT="$timeout" gh_api GET "/repos/${r}${suffix}" > "$outdir/$n" 2>/dev/null &
    [ $((n % maxpar)) -eq 0 ] && wait
  done
  wait
  [ "${GH_API_BACKGROUND:-0}" = 1 ] && ! gh_rate_allows_background && blocked=1
  [ "$blocked" = 0 ] || return 3
}

github_public_repo_problem() {
  [ "$GH_SCOPE" = "repo" ] || { echo ""; return; }
  { [ "$DIND" = "true" ] || [ "$SHARE_DOCKER_SOCK" = "true" ]; } || { echo ""; return; }
  [ -n "$ACCESS_TOKEN" ] || { echo ""; return; }
  local cached; cached="$(security_cache_get)" && { printf '%s' "$cached"; return; }
  local pub="" repo vis tmpd n=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo ""; return; }
  github_fetch_all "" "$tmpd" 8 5
  for repo in $GH_REPOS; do
    [ -n "$repo" ] || continue
    n=$((n+1))
    vis="$(grep -o '"visibility"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmpd/$n" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [ "$vis" = "public" ] && pub="$pub ${repo}"
  done
  rm -rf "$tmpd"
  local msg=""
  [ -n "$pub" ] && msg="PUBLIC repo(s) targeted while runners are privileged (DinD / host docker.sock):${pub}. Fork-PR code on a public repo would run as root on this server. Use trusted/private repos only, or an org runner-group restricted to private repos. See the Security section of the plugin README."
  security_cache_put "$msg"
  printf '%s' "$msg"
}

# ── Build-poison detection ───────────────────────────────────────────────────
# A crashed nested dockerd can leave a slot's persistent buildkit store with
# dangling lease references or missing snapshot parents; every later build on
# that slot then fails with either
#   ERROR: failed to solve: lease "...": not found
# or
#   failed to stat parent: stat /var/lib/buildkit/runc-overlayfs/snapshots/snapshots/<n>/fs: no such file or directory
# while the runner stays healthy and keeps accepting jobs. Nothing host-side
# ever sees that error: the nested daemon does not log solve failures and job
# step output exists only in the uploaded GitHub job log. So detection reads
# what the jobs themselves saw — recent failed workflow runs, their jobs that
# ran on THIS host's slots, and each such job's log — looking for the lease
# signatures. Rate-bounded and cached: an idle fleet revalidates one runs
# listing per repo per POISON_SCAN_INTERVAL (a free 304 while nothing new has
# failed), job lists revalidate the same way, log downloads happen at most once
# per failed job ever (the seen cache), and the whole scan pauses while the
# credential is below GH_API_RESERVE.
GITHUB_POISON_SIGNATURE='failed to solve: lease "[^"]*": not found|failed to stat parent: stat /var/lib/buildkit/runc-overlayfs/snapshots/snapshots/[0-9]+/fs: no such file or directory'

# IDs of recent failed workflow runs for one repo, newest first. The pretty
# GitHub JSON puts every field on its own line; a run object's own "id" is the
# only anchored "id" key that is later followed by "head_branch", which nested
# objects (repository, check suite) never carry.
github_recent_failed_runs() {
  local repo="$1" cutoff="$2" url body
  url="/repos/${repo}/actions/runs?status=failure&per_page=5"
  [ -n "$cutoff" ] && url="${url}&created=%3E${cutoff}"
  body="$(gh_api GET "$url")" || return 1
  printf '%s\n' "$body" | awk '
    /^[[:space:]]*"id":/ { if (match($0, /[0-9]+/)) last = substr($0, RSTART, RLENGTH) }
    /^[[:space:]]*"head_branch":/ { if (last != "") { print last; last = "" } }'
}

# "jobid|slot" for each failed job of one run (latest attempt) that executed on
# one of this host's managed slots. Per job object the fields arrive as: "id",
# then the job-level "conclusion" (before the steps array, whose steps carry
# their own "conclusion" but never an anchored "id"), then "runner_name".
github_failed_local_jobs() {
  local repo="$1" run_id="$2" body
  body="$(gh_api GET "/repos/${repo}/actions/runs/${run_id}/jobs?per_page=50")" || return 1
  printf '%s\n' "$body" | awk -v host="$(host)-" -v prefix="${NAME_PREFIX}-" '
    /^[[:space:]]*"id":/ { if (match($0, /[0-9]+/)) { jid = substr($0, RSTART, RLENGTH); conc = "" } }
    /^[[:space:]]*"conclusion":/ {
      if (conc == "") { s = $0; sub(/^[^:]*:[[:space:]]*"?/, "", s); sub(/"?,?[[:space:]]*$/, "", s); conc = s }
    }
    /^[[:space:]]*"runner_name":/ {
      s = $0; sub(/^[^:]*:[[:space:]]*"/, "", s); sub(/".*/, "", s)
      if (jid != "" && conc == "failure" && index(s, host) == 1) {
        slot = substr(s, length(host) + 1)
        if (slot ~ ("^" prefix "[0-9]+$")) print jid "|" slot
      }
      jid = ""; conc = ""
    }'
}

# Does one failed job's log carry a supported build-poison signature? The logs
# endpoint redirects to short-lived blob storage; the PAT enters curl through
# config stdin (never argv), like gh_api. Size/time caps keep a runaway log
# from stalling the tick — a poisoned build dies in its first minute, so the
# logs that matter are small. grep without -q reads to EOF, so pipefail cannot
# turn an early-match SIGPIPE into a false negative.
github_job_log_poisoned() {
  local repo="$1" job_id="$2" status headers
  github_app_refresh
  [ -n "$ACCESS_TOKEN" ] || return 2
  # A job-log request spends the core limit too: honour the reserve (an
  # uncertain result, so the job is retried later) and record the headers.
  if [ "${GH_API_BACKGROUND:-0}" = 1 ] && ! gh_rate_allows_background; then return 2; fi
  headers="$(mktemp "${TMPDIR:-/tmp}/crf-gh-log.XXXXXX" 2>/dev/null)" || return 2
  # Capture every pipe status, including transport failure. Only a complete
  # download can become a durable seen job; uncertain downloads retry later.
  local outcomes=()
  {
    printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
      | curl -fsSL -m 30 --max-filesize 8000000 --config - \
        -H "Accept: application/vnd.github+json" -D "$headers" \
        "https://api.github.com/repos/${repo}/actions/jobs/${job_id}/logs" 2>/dev/null \
      | grep -E "$GITHUB_POISON_SIGNATURE" >/dev/null 2>&1
    outcomes=("${PIPESTATUS[@]}")
  } || true
  gh_rate_record "$headers"
  rm -f "$headers"
  [ "${outcomes[0]}" -eq 0 ] && [ "${outcomes[1]}" -eq 0 ] || return 2
  status="${outcomes[2]}"
  [ "$status" -le 1 ] || return 2
  return "$status"
}

github_build_poison_scan() {
  [ "$DIND" = "true" ] || return 0     # no nested daemon, no buildkit store to poison
  [ -n "$ACCESS_TOKEN" ] || return 0
  local stampf="$RUNDIR/poison-scan.stamp" seenf="$RUNDIR/poison-scan.seen"
  # Dynamic scope: every gh_api and job-log request below checks the reserve.
  local GH_API_BACKGROUND=1
  local now last=0 cutoff repo run_id line jid slot snapshot id provider role index gen log_status
  now="$(date +%s)"
  [ -f "$stampf" ] && read -r last < "$stampf"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt "$POISON_SCAN_INTERVAL" ] && return 0
  gh_rate_allows_background || return 0
  echo "$now" > "$stampf"
  gh_etag_prune
  # GNU date on Unraid; an environment without epoch -d support just drops the
  # created filter and lets the seen cache bound the rework instead. The cutoff
  # is rounded down to the hour so each repo's run-list URL stays the same for
  # an hour and revalidates with a free 304. The lookback is therefore 30-90
  # minutes; the seen cache keeps the longer window from repeating work.
  cutoff="$(date -u -d "@$(( (now - POISON_SCAN_LOOKBACK) / 3600 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  [ -f "$seenf" ] || : > "$seenf"
  for repo in $GH_REPOS; do
    [ -n "$repo" ] || continue
    for run_id in $(github_recent_failed_runs "$repo" "$cutoff"); do
      for line in $(github_failed_local_jobs "$repo" "$run_id"); do
        jid="${line%%|*}"; slot="${line##*|}"
        grep -qx "$jid" "$seenf" 2>/dev/null && continue
        log_status=0
        github_job_log_poisoned "$repo" "$jid" || log_status=$?
        [ "$log_status" -le 1 ] || continue
        if [ "$log_status" -eq 1 ]; then echo "$jid" >> "$seenf"; continue; fi
        # Flag the slot with its current immutable container ID so the healer
        # can discard the flag if the slot is replaced before repair runs.
        snapshot="$(managed_runner_snapshot "$slot" 2>/dev/null)" || continue
        IFS='|' read -r id provider role index gen <<< "$snapshot"
        log "selfheal: job $jid on $slot failed with corrupt buildkit metadata -> flagging for repair"
        echo "$id" > "$RUNDIR/poison-pending.$slot" || continue
        echo "$jid" >> "$seenf"
      done
    done
  done
  tail -500 "$seenf" > "$seenf.tmp" 2>/dev/null && mv "$seenf.tmp" "$seenf"
  return 0
}

github_registry_credentials() {
  if [ -z "$pass" ]; then
    case "$REGISTRY_SERVER" in
      ghcr.io|*.ghcr.io) pass="$ACCESS_TOKEN"; [ -z "$user" ] && user="$GH_OWNER" ;;
    esac
  fi
}

github_build_args() {
  local idx="$1"
  local name="${2:-${NAME_PREFIX}-${idx}}" role="${CRF_CONTAINER_ROLE:-runner}" host_service_ip image kvm_gid=''
  crf_user_share_mount_config_problem || return 1
  crf_shared_cache_mount || return 1
  local pnpm_store_dest='' cache_spec cache_dest
  for cache_spec in $CACHE_MOUNTS; do
    case "$cache_spec" in
      pnpm-store|pnpm-store:*)
        cache_dest="${cache_spec#*:}"
        [ -z "$pnpm_store_dest" ] \
          || { err "pnpm-store must have exactly one cache destination"; return 1; }
        printf '%s' "$cache_dest" | grep -qE '^/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$' \
          || { err "pnpm-store requires an absolute writable cache destination"; return 1; }
        case "$cache_dest" in *//*|*/../*|*/./*|*/..|*/.|/_work)
          err "pnpm-store destination must be canonical and distinct from the workspace mount"; return 1 ;;
        esac
        pnpm_store_dest="$cache_dest"
        ;;
    esac
  done
  image="$(effective_image)" || return 1
  host_service_ip="$(runner_host_service_ipv4)" \
    || { err "could not resolve this farm host's local service address"; return 1; }
  case ",$RUNNER_LABELS," in
    *,kvm,*)
      kvm_gid="$(github_kvm_gid 2>/dev/null)" \
        || { err "runner label kvm requires group-writable /dev/kvm"; return 1; }
      ;;
  esac
  local registration_labels="$RUNNER_LABELS"
  if shared_capacity_enabled; then
    registration_labels=crf-shared-awaiting-identity
  fi
  ARGS_TMPDIR=""
  ARGS=(
    -d --restart=no
    --name "$name" --hostname "$name"
    --pids-limit=4096
    --label "${MANAGED_LABEL%=*}=true"
    --label "net.unraid.ci-runner-farm.provider=github"
    --label "net.unraid.ci-runner-farm.role=${role}"
    --label "net.unraid.ci-runner-farm.index=${idx}"
    --label "net.unraid.ci-runner-farm.pool=${CRF_POOL_ID:-default}"
    --label "net.unraid.ci-runner-farm.confgen=$(crf_confgen)"
    --add-host "host.docker.internal:host-gateway"
    --add-host "runner-farm.host:${host_service_ip}"
    -e RUNNER_NAME="$(host)-${name}"
    -e LABELS="$registration_labels"
    -e DISABLE_AUTO_UPDATE="true"
    -e DISABLE_AUTOMATIC_DEREGISTRATION="true"
    -e RUN_AS_ROOT="$RUN_AS_ROOT"
    -e RUNNER_ALLOW_RUNASROOT="1"
    -e RUNNER_WORKDIR="/_work"
    -e npm_config_cache="/home/runner/.npm"
  )
  if shared_capacity_enabled; then
    ARGS+=( -e NO_DEFAULT_LABELS=true
      -e "UNRAID_RUNNER_ROUTING_LABELS=$RUNNER_LABELS"
      --label "net.unraid.ci-runner-farm.routing-labels=$RUNNER_LABELS" )
  fi
  [ -z "$kvm_gid" ] || ARGS+=( --device /dev/kvm --group-add "$kvm_gid" -e "KVM_GID=$kvm_gid" )
  [ "$EPHEMERAL" = "true" ] && ARGS+=( -e EPHEMERAL="true" )
  local m hostdir
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] || continue
    hostdir="$(crf_safe_mount_subdir "${m%%:*}")" || { err "skipping unsafe cache mount '${m%%:*}'"; continue; }
    ARGS+=( -v "$hostdir:${m#*:}" )
    if [ "${m%%:*}" = pnpm-store ]; then
      # pnpm otherwise chooses a store on the project's filesystem, which is
      # workspace RAM when WORK_TMPFS_SIZE is set. Configure the admitted bind
      # before any job or setup-node cache restore; support pnpm 11 and 10.
      ARGS+=( -e "PNPM_CONFIG_STORE_DIR=$pnpm_store_dest" -e "npm_config_store_dir=$pnpm_store_dest" )
    fi
  done
  local share_spec share_source share_rest share_dest share_mode share_mount
  local -a share_specs=()
  read -r -a share_specs <<< "$USER_SHARE_MOUNTS"
  for share_spec in "${share_specs[@]}"; do
    share_source="${share_spec%%:*}"; share_rest="${share_spec#*:}"
    share_dest="${share_rest%:*}"; share_mode="${share_rest##*:}"
    share_source="$(crf_user_share_mount_source "$share_source")" || return 1
    share_mount="type=bind,src=${share_source},dst=${share_dest}"
    [ "$share_mode" = ro ] && share_mount+=",readonly"
    ARGS+=( --mount "$share_mount" )
  done
  if [ -n "$SHARED_CACHE_ROOT" ]; then
    ARGS+=( --mount "type=bind,src=${SHARED_CACHE_ROOT},dst=/mnt/ci-cache"
      -e CI_SHARED_CACHE=/mnt/ci-cache
      --label net.unraid.ci-runner-farm.shared-cache=ci-shared-cache-v1 )
  fi
  [ -n "$RUNNER_CPUS" ]   && ARGS+=( --cpus="$RUNNER_CPUS" )
  if [ "${CPU_PINNING:-false}" = true ]; then
    # Keep --cpus: capacity accounting reads each runner's CPU cost from it.
    # Placement failure is never fatal; the runner then starts unpinned.
    local cpuset
    if cpuset="$(crf_cpu_pinning_cpuset "$RUNNER_CPUS" "$name")" && [ -n "$cpuset" ]; then
      ARGS+=( --cpuset-cpus="$cpuset" --label "net.unraid.ci-runner-farm.cpuset=${cpuset}" )
    fi
  fi
  [ -n "$RUNNER_MEMORY" ] && ARGS+=( --memory="$RUNNER_MEMORY" )
  [ "$NETWORK_ISOLATION" != "off" ] && ARGS+=( --network "$RUNNER_NETWORK" )
  if [ "$DIND" = "true" ]; then
    # The runner image bootstraps cgroup v2 before the base entrypoint starts
    # dockerd. Make the namespace boundary explicit so that bootstrap can never
    # write the host hierarchy, even if the engine default changes.
    ARGS+=( --privileged --cgroupns=private -e START_DOCKER_SERVICE=true )
    mkdir -p "$CACHE_ROOT/docker/$name" "$CACHE_ROOT/dind-logs/$name"
    ARGS+=( -v "$CACHE_ROOT/docker/$name:/var/lib/docker" )
    ARGS+=( -v "$CACHE_ROOT/dind-daemon.json:/etc/docker/daemon.json:ro" )
    ARGS+=( -v "$CACHE_ROOT/dind-logs/$name:/var/log/dind" )
    if [ "$EPHEMERAL" = false ]; then
      local cleanup_script="$PROVIDER_DIR/../runner-job-cleanup.sh" cleanup_destination=/opt/ci-runner-farm/job-completed.sh
      [ -r "$cleanup_script" ] && [ -x "$cleanup_script" ] \
        || { err "persistent DinD job cleanup hook is missing or not executable"; return 1; }
      for cache_spec in $CACHE_MOUNTS; do
        if crf_mount_destinations_overlap "$cleanup_destination" "${cache_spec#*:}"; then
          err "cache mount overlaps the job cleanup hook"; return 1
        fi
      done
      local image_hook
      image_hook="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")" \
        || { err "could not inspect the image job completion hook"; return 1; }
      image_hook="$(printf '%s\n' "$image_hook" | sed -n '/^ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/p')"
      if [ -n "$image_hook" ]; then
        image_hook="${image_hook#ACTIONS_RUNNER_HOOK_JOB_COMPLETED=}"
        case "$image_hook" in
          *$'\n'*|"$cleanup_destination") err "invalid or recursive image job completion hook"; return 1 ;;
          /*.sh|/*.ps1) ;;
          '') ;;
          *) err "image job completion hook must be an absolute .sh or .ps1 path"; return 1 ;;
        esac
      fi
      ARGS+=( -e "CRF_IMAGE_JOB_COMPLETED_HOOK=$image_hook" )
      ARGS+=( -v "$cleanup_script:$cleanup_destination:ro"
        -e "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$cleanup_destination" -e CRF_JOB_CLEANUP_DIND=1 )
      if [ -n "${DOCKER_CACHE_BUILDERS:-}" ]; then
        github_validate_docker_cache_policy || return 1
        ARGS+=( -e "CRF_DOCKER_CACHE_BUILDERS=$DOCKER_CACHE_BUILDERS"
          -e "CRF_DOCKER_CACHE_MIN_FREE_PERCENT=$DOCKER_CACHE_MIN_FREE_PERCENT" )
      fi
    fi
  elif [ "$SHARE_DOCKER_SOCK" = "true" ]; then
    ARGS+=( -v /var/run/docker.sock:/var/run/docker.sock )
  fi
  if [ -n "$WORK_TMPFS_SIZE" ]; then
    ARGS+=( --tmpfs "/_work:rw,exec,size=${WORK_TMPFS_SIZE}" )
  else
    mkdir -p "$CACHE_ROOT/work/$name"
    ARGS+=( -v "$CACHE_ROOT/work/$name:/_work" )
  fi
  local scope_target="" repo reg envdir envf
  if [ "$GH_SCOPE" = "org" ]; then
    ARGS+=( -e RUNNER_SCOPE="org" -e ORG_NAME="$GH_OWNER" )
    [ -n "$RUNNER_GROUP" ] && ARGS+=( -e RUNNER_GROUP="$RUNNER_GROUP" )
    scope_target="org:$GH_OWNER"
  else
    repo="$(github_repo_for_index "$idx")"
    ARGS+=( -e RUNNER_SCOPE="repo" -e REPO_URL="https://github.com/${repo}" )
    scope_target="repo:$repo"
  fi
  if [ -n "$ACCESS_TOKEN" ] && [ "${NO_REGISTER:-0}" != "1" ]; then
    reg="$(github_registration_token "$scope_target")"
    [ -z "$reg" ] && { err "could not mint a runner registration token for ${scope_target#*:} (check the PAT's scope/permissions)"; return 1; }
    # The image only accepts this token as RUNNER_TOKEN in its environment, so it
    # still lands in Config.Env — but a restricted --env-file keeps it out of
    # docker's argv, where /proc/<pid>/cmdline exposes it to every local user for
    # the lifetime of the run. The engine retires ARGS_TMPDIR once the run this
    # argv was built for has been dispatched.
    envdir="$(mktemp -d "$RUNDIR/github-runner-token.XXXXXX" 2>/dev/null)" \
      || { err "could not create a protected registration-token file for $name"; return 1; }
    envf="$envdir/runner.env"
    chmod 700 "$envdir" 2>/dev/null \
      || { rm -rf "$envdir"; err "could not protect the registration-token directory for $name"; return 1; }
    ( umask 077; printf 'RUNNER_TOKEN=%s\n' "$reg" > "$envf" ) \
      || { rm -rf "$envdir"; err "could not write the registration-token file for $name"; return 1; }
    chmod 600 "$envf" 2>/dev/null \
      || { rm -rf "$envdir"; err "could not protect the registration-token file for $name"; return 1; }
    ARGS+=( --env-file "$envf" )
    if shared_capacity_enabled; then
      ARGS+=( --label "net.unraid.ci-runner-farm.registration-issued=$(date +%s)" )
    fi
    ARGS_TMPDIR="$envdir"
  fi
  ARGS+=( "$image" )
}

github_start_one() {
  local idx="$1" name="$2" rc image
  image="$(effective_image)" || return 1
  # Queued native starts can bypass the full Start preflight. Prepare cold
  # private images with host authentication before minting runner credentials.
  if [ "$IMAGE_SOURCE" = remote ] && ! docker image inspect "$image" >/dev/null 2>&1; then
    github_prepare_remote_image "$image" >/dev/null \
      || { err "runner $name not started (remote image preparation failed)"; return 1; }
  fi
  github_build_args "$idx" "$name" || { err "runner $name not started (registration-token error)"; return 1; }
  log "starting $name (pool=${CRF_POOL_ID:-default} cpus=$RUNNER_CPUS mem=$RUNNER_MEMORY scope=$GH_SCOPE image=$(effective_image))"
  run_owned_github_container "$idx" >/dev/null
  rc=$?
  clear_args_tmpdir
  return "$rc"
}

github_remove_runner() {
  local c="$1" purge="${2:-true}" root failed=0
  # GitHub rejects DELETE for an online/busy runner. Stop/remove first so its
  # listener is offline, then delete the now-offline registration host-side.
  # A failed stop/remove can leave the listener accepting or executing work.
  # Never deregister it remotely or delete its Docker root underneath it.
  provider_stop_remove_container "$c" || return 1
  github_deregister_runner_api "$c" || failed=1
  if [ "$purge" = true ]; then
    root="$(crf_safe_cache_root)" || { err "refusing GitHub runner cleanup under unsafe CACHE_ROOT '$CACHE_ROOT'"; return 1; }
    rm -rf "$root/docker/$c" 2>/dev/null || failed=1
  fi
  return "$failed"
}

github_queued_refresh() {
  [ -z "$ACCESS_TOKEN" ] && [ "$GITHUB_APP_MODE" != true ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  [ -n "$ACCESS_TOKEN" ] || { echo "github $(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  # Keep the last count (its age is visible) rather than spend the reserve.
  gh_rate_allows_background || return 0
  local total=0 got=0 r n body tmpd i=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "github $(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  GH_API_BACKGROUND=1 github_fetch_all "/actions/runs?status=queued&per_page=1" "$tmpd" \
    || { rm -rf "$tmpd"; return 0; }
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    i=$((i+1)); body="$(cat "$tmpd/$i" 2>/dev/null)"
    case "$body" in *'"total_count"'*) got=1 ;; esac
    n="$(printf '%s' "$body" | grep -m1 -oE '"total_count":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
    total=$(( total + ${n:-0} ))
  done
  rm -rf "$tmpd"
  [ "$got" = "1" ] || total=-1
  echo "github $(date +%s) $total" > "$RUNDIR/queued.cache"
}

github_stats_refresh() {
  [ -z "$ACCESS_TOKEN" ] && [ "$GITHUB_APP_MODE" != true ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  [ -n "$ACCESS_TOKEN" ] || { echo "github $(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0; }
  gh_rate_allows_background || return 0
  local ok=0 fail=0 cancel=0 other=0 total got=0 r body c tmpd i=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "github $(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0; }
  GH_API_BACKGROUND=1 github_fetch_all "/actions/runs?per_page=50" "$tmpd" \
    || { rm -rf "$tmpd"; return 0; }
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    i=$((i+1)); body="$(cat "$tmpd/$i" 2>/dev/null)"
    case "$body" in *'"workflow_runs"'*) got=1 ;; esac
    while IFS= read -r c; do
      case "$c" in
        *'"success"'*) ok=$((ok+1)) ;;
        *'"failure"'*|*'"timed_out"'*|*'"startup_failure"'*) fail=$((fail+1)) ;;
        *'"cancelled"'*) cancel=$((cancel+1)) ;;
        *null*) : ;;
        ?*) other=$((other+1)) ;;
      esac
    done <<< "$(echo "$body" | grep -oE '"conclusion": ?(null|"[a-z_]+")')"
  done
  rm -rf "$tmpd"
  if [ "$got" = "1" ]; then total=$((ok+fail+cancel+other)); else total=-1; fi
  echo "github $(date +%s) $ok $fail $cancel $other $total" > "$RUNDIR/stats.cache"
}

github_usage_stat_target() { printf '%s\n' "$1"; }
github_status_resources() { return 0; }

# Populate cmd_usage_refresh's dynamically scoped provider-neutral output fields.
github_usage_context() {
  local c="$1" jline jenv jref shared=false snapshot provider role index gen
  if shared_capacity_enabled; then
    shared=true
    snapshot="$(managed_runner_snapshot "$c")" || return 0
    IFS='|' read -r c provider role index gen <<< "$snapshot"
    [ "$provider" = github ] && [ "$role" = runner ] || return 0
  fi
  jline="$(docker logs --timestamps --tail 60 "$c" 2>&1 | grep 'Running job: ' | tail -1 | tr -d '\r')"
  job="${jline##*Running job: }"
  jstarted="$(echo "$jline" | awk '{print $1}' | grep -oE '^[0-9T:.Z-]+' | head -1)"; jstarted="${jstarted:-_}"
  # The worker can finish after the busy sample, allowing native pause before
  # this optional metadata read. Keep log-derived fields; unavailable repo/run
  # links are preferable to spawning an exec into a freezeable shared owner.
  [ "$shared" = false ] || return 0
  jenv="$(docker exec "$c" sh -c 'for p in /proc/[0-9]*/environ; do if tr "\0" "\n" < $p 2>/dev/null | grep -q "^GITHUB_REPOSITORY="; then tr "\0" "\n" < $p | grep -E "^GITHUB_(REPOSITORY|RUN_ID|REF_NAME)="; break; fi; done' 2>/dev/null)"
  if [ -n "$jenv" ]; then
    jrepo="$(echo "$jenv" | grep '^GITHUB_REPOSITORY=' | head -1 | cut -d= -f2)"
    jrun="$(echo "$jenv" | grep '^GITHUB_RUN_ID=' | head -1 | cut -d= -f2 | grep -oE '^[0-9]+' | head -1)"; jrun="${jrun:-_}"
    jref="$(echo "$jenv" | grep '^GITHUB_REF_NAME=' | head -1 | cut -d= -f2-)"
    if echo "$jref" | grep -qE '^[0-9]+/merge$'; then jpr="${jref%%/merge*}"; else jbranch="$jref"; fi
    project="$jrepo"; job_id="$jrun"
    [ "$jrun" != _ ] && job_url="https://github.com/$jrepo/actions/runs/$jrun"
    if [ "$jpr" != _ ]; then
      ref="PR #$jpr"; ref_url="https://github.com/$jrepo/pull/$jpr"
    else
      ref="$jbranch"; [ -n "$jbranch" ] && ref_url="https://github.com/$jrepo/tree/$(urlencode "$jbranch")"
    fi
  fi
}

github_validate() {
  shared_capacity_require_starts_open || return 1
  if shared_capacity_enabled; then
    err "inert validation containers are disabled while shared host admission is active"
    return 1
  fi
  check_cache_root || return 1
  ensure_dirs || return 1
  registry_login || return 1
  local suffix name snapshot validation_id="" root share_access_ok=1 share_user='0:0' share_spec share_rest share_dest share_mode
  local -a share_specs=()
  suffix="$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  printf '%s' "$suffix" | grep -qE '^[0-9a-f]{12}$' \
    || { err "validate: could not create a random validation-container name"; return 1; }
  name="${NAME_PREFIX}-validate-${suffix}"
  # Dynamic scope lets github_build_args stamp a validation-specific ownership
  # role without changing the ordinary runner contract.
  local NO_REGISTER=1 CRF_CONTAINER_ROLE=validate
  github_build_args 99 "$name" || return 1
  local injected=() a eimg; eimg="$(effective_image)" || return 1
  for a in "${ARGS[@]}"; do
    [ "$a" = "$eimg" ] && injected+=( --entrypoint /bin/sh "$eimg" -c "sleep 30" ) || injected+=( "$a" )
  done
  log "validate: launching inert container to verify mounts/limits..."
  local errf; errf="$(mktemp "$RUNDIR/crf-validate.XXXXXX" 2>/dev/null)" \
    || { err "validate: could not create a temp file for docker run output"; return 1; }
  if ! docker run "${injected[@]}" >/dev/null 2>"$errf"; then
    # docker run can leave a Created container on some failures. Remove it only
    # when the complete labels resolve to an immutable ID owned by this attempt.
    snapshot="$(owned_container_snapshot "$name" 99 github-validate 2>/dev/null || true)"
    validation_id="${snapshot%%|*}"
    [ -z "$validation_id" ] || docker rm -f "$validation_id" >/dev/null 2>&1 || true
    err "docker run failed:"; cat "$errf" >&2; rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  snapshot="$(owned_container_snapshot "$name" 99 github-validate)" \
    || { err "validate: created container failed its ownership check; leaving it untouched"; return 1; }
  validation_id="${snapshot%%|*}"
  echo "--- resource limits ---"
  docker inspect -f 'cpus={{.HostConfig.NanoCpus}} mem={{.HostConfig.Memory}} pids={{.HostConfig.PidsLimit}}' "$validation_id"
  echo "--- mounts ---"
  docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' "$validation_id"
  if [ -n "$USER_SHARE_MOUNTS" ]; then
    read -r -a share_specs <<< "$USER_SHARE_MOUNTS"
    [ "$RUN_AS_ROOT" = true ] || share_user="$RUNNER_UID:$RUNNER_GID"
    for share_spec in "${share_specs[@]}"; do
      share_rest="${share_spec#*:}"; share_dest="${share_rest%:*}"; share_mode="${share_rest##*:}"
      if ! docker exec --user "$share_user" "$validation_id" sh -c \
        'if [ "$2" = rw ]; then probe="$1/.ci-runner-farm-write-test-$$"; umask 077; : > "$probe" && rm -f "$probe"; else [ -r "$1" ] && [ -x "$1" ]; fi' \
        sh "$share_dest" "$share_mode"; then
        share_access_ok=0
        break
      fi
    done
  fi
  echo "--- tmpfs ---"
  docker inspect -f '{{json .HostConfig.Tmpfs}}' "$validation_id"
  echo "--- docker.sock reachable inside container ---"
  docker exec "$validation_id" sh -c '[ -S /var/run/docker.sock ] && echo "yes: docker.sock present" || echo "no socket"' 2>/dev/null
  docker rm -f "$validation_id" >/dev/null 2>&1 \
    || { err "validate: could not remove owned validation container $name"; return 1; }
  root="$(crf_safe_cache_root)" || { err "validate: refusing cleanup under unsafe CACHE_ROOT"; return 1; }
  rm -rf "$root/docker/$name" 2>/dev/null || true
  if [ "$share_access_ok" -ne 1 ]; then
    err "validate: user-share mount is not accessible with configured mode by runner UID:GID $share_user"
    return 1
  fi
  log "validate: OK (container removed). Provisioning mechanics verified on this host."
}
