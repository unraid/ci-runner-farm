#!/bin/bash
# GitHub Actions provider adapter for CI Runner Farm.
# Sourced by runner-farm.sh after configuration and common helpers are loaded.

github_token_ready() { [ -n "$ACCESS_TOKEN" ]; }
github_token_name()  { echo "GitHub token"; }
github_builtin_image() { echo "$BUILTIN_IMAGE"; }
github_validate_settings() { return 0; }
github_strict_endpoint() { return 0; }
github_imageupdate_pull() { return 1; }
github_remote_image_host_pull_required() { return 0; }
github_prepare_remote_image() { registry_login && host_docker_pull "$1"; }
github_remote_image_update_allowed() { return 0; }
github_stop_cleanup() { return 0; }
github_docker_stopping_timeout() { echo 0; }
github_docker_stopping() { return 0; }

github_confgen() {
  # Byte-for-byte the pre-provider fingerprint input/order. Existing GitHub
  # containers must not become stale merely because provider support was added.
  printf '%s\0' "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" "$RUNNER_GROUP" "$RUNNER_LABELS" \
    "$EPHEMERAL" "$RUNNER_CPUS" "$RUNNER_MEMORY" "$WORK_TMPFS_SIZE" "$CACHE_MOUNTS" \
    "$DIND" "$SHARE_DOCKER_SOCK" "$RUN_AS_ROOT" "$IMAGE_SOURCE" "$IMAGE" \
    "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" \
    "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" \
    | sha256sum | cut -c1-12
}

github_runner_state() {
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

# Long-lived PATs remain host-side; curl reads credentials from stdin so they do
# not appear in /proc/<pid>/cmdline.
gh_api() {
  [ -n "$ACCESS_TOKEN" ] || return 1
  printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
    | curl -fsSL -m 10 -X "$1" --config - \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com$2" 2>/dev/null
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

github_fetch_all() {
  local suffix="$1" outdir="$2" maxpar="${3:-8}" timeout="${4:-10}"
  local n=0 r
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    n=$((n+1))
    printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
      | curl -s --max-time "$timeout" --config - \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${r}${suffix}" > "$outdir/$n" 2>/dev/null &
    [ $((n % maxpar)) -eq 0 ] && wait
  done
  wait
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

github_registry_credentials() {
  if [ -z "$pass" ]; then
    case "$REGISTRY_SERVER" in
      ghcr.io|*.ghcr.io) pass="$ACCESS_TOKEN"; [ -z "$user" ] && user="$GH_OWNER" ;;
    esac
  fi
}

github_build_args() {
  local idx="$1" name="${2:-${NAME_PREFIX}-${idx}}" role="${CRF_CONTAINER_ROLE:-runner}"
  ARGS=(
    -d --restart=no
    --name "$name" --hostname "$name"
    --pids-limit=4096
    --label "${MANAGED_LABEL%=*}=true"
    --label "net.unraid.ci-runner-farm.provider=github"
    --label "net.unraid.ci-runner-farm.role=${role}"
    --label "net.unraid.ci-runner-farm.index=${idx}"
    --label "net.unraid.ci-runner-farm.confgen=$(crf_confgen)"
    -e RUNNER_NAME="$(host)-${name}"
    -e LABELS="$RUNNER_LABELS"
    -e DISABLE_AUTO_UPDATE="true"
    -e DISABLE_AUTOMATIC_DEREGISTRATION="true"
    -e RUN_AS_ROOT="$RUN_AS_ROOT"
    -e RUNNER_ALLOW_RUNASROOT="1"
    -e RUNNER_WORKDIR="/_work"
    -e npm_config_cache="/home/runner/.npm"
  )
  [ "$EPHEMERAL" = "true" ] && ARGS+=( -e EPHEMERAL="true" )
  local m hostdir
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] || continue
    hostdir="$(crf_safe_mount_subdir "${m%%:*}")" || { err "skipping unsafe cache mount '${m%%:*}'"; continue; }
    ARGS+=( -v "$hostdir:${m#*:}" )
  done
  [ -n "$RUNNER_CPUS" ]   && ARGS+=( --cpus="$RUNNER_CPUS" )
  [ -n "$RUNNER_MEMORY" ] && ARGS+=( --memory="$RUNNER_MEMORY" )
  [ "$NETWORK_ISOLATION" != "off" ] && ARGS+=( --network "$RUNNER_NETWORK" )
  if [ "$DIND" = "true" ]; then
    ARGS+=( --privileged -e START_DOCKER_SERVICE=true )
    mkdir -p "$CACHE_ROOT/docker/$name" "$CACHE_ROOT/dind-logs/$name"
    ARGS+=( -v "$CACHE_ROOT/docker/$name:/var/lib/docker" )
    ARGS+=( -v "$CACHE_ROOT/dind-daemon.json:/etc/docker/daemon.json:ro" )
    ARGS+=( -v "$CACHE_ROOT/dind-logs/$name:/var/log/dind" )
    [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$NETWORK_ISOLATION" = "off" ] && ARGS+=( --add-host "host.docker.internal:host-gateway" )
  elif [ "$SHARE_DOCKER_SOCK" = "true" ]; then
    ARGS+=( -v /var/run/docker.sock:/var/run/docker.sock )
  fi
  if [ -n "$WORK_TMPFS_SIZE" ]; then
    ARGS+=( --tmpfs "/_work:rw,exec,size=${WORK_TMPFS_SIZE}" )
  else
    mkdir -p "$CACHE_ROOT/work/$name"
    ARGS+=( -v "$CACHE_ROOT/work/$name:/_work" )
  fi
  local scope_target="" repo reg
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
    ARGS+=( -e RUNNER_TOKEN="$reg" )
  fi
  ARGS+=( "$(effective_image)" )
}

github_start_one() {
  local idx="$1" name="$2"
  github_build_args "$idx" "$name" || { err "runner $name not started (registration-token error)"; return 1; }
  log "starting $name (cpus=$RUNNER_CPUS mem=$RUNNER_MEMORY scope=$GH_SCOPE)"
  docker run "${ARGS[@]}" >/dev/null
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
  [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  [ -n "$ACCESS_TOKEN" ] || { echo "github $(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  local total=0 got=0 r n body tmpd i=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "github $(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  github_fetch_all "/actions/runs?status=queued&per_page=1" "$tmpd"
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
  [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  [ -n "$ACCESS_TOKEN" ] || { echo "github $(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0; }
  local ok=0 fail=0 cancel=0 other=0 total got=0 r body c tmpd i=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "github $(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0; }
  github_fetch_all "/actions/runs?per_page=50" "$tmpd"
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
  local c="$1" jline jenv jref
  jline="$(docker logs --timestamps --tail 60 "$c" 2>&1 | grep 'Running job: ' | tail -1 | tr -d '\r')"
  job="${jline##*Running job: }"
  jstarted="$(echo "$jline" | awk '{print $1}' | grep -oE '^[0-9T:.Z-]+' | head -1)"; jstarted="${jstarted:-_}"
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
  check_cache_root || return 1
  ensure_dirs
  registry_login
  local suffix name snapshot validation_id="" root
  suffix="$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  printf '%s' "$suffix" | grep -qE '^[0-9a-f]{12}$' \
    || { err "validate: could not create a random validation-container name"; return 1; }
  name="${NAME_PREFIX}-validate-${suffix}"
  # Dynamic scope lets github_build_args stamp a validation-specific ownership
  # role without changing the ordinary runner contract.
  local NO_REGISTER=1 CRF_CONTAINER_ROLE=validate
  github_build_args 99 "$name" || return 1
  local injected=() a eimg; eimg="$(effective_image)"
  for a in "${ARGS[@]}"; do
    [ "$a" = "$eimg" ] && injected+=( --entrypoint /bin/sh "$eimg" -c "sleep 30" ) || injected+=( "$a" )
  done
  log "validate: launching inert container to verify mounts/limits..."
  local errf; errf="$(mktemp /tmp/crf-validate.XXXXXX)"
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
  echo "--- tmpfs ---"
  docker inspect -f '{{json .HostConfig.Tmpfs}}' "$validation_id"
  echo "--- docker.sock reachable inside container ---"
  docker exec "$validation_id" sh -c '[ -S /var/run/docker.sock ] && echo "yes: docker.sock present" || echo "no socket"' 2>/dev/null
  docker rm -f "$validation_id" >/dev/null 2>&1 \
    || { err "validate: could not remove owned validation container $name"; return 1; }
  root="$(crf_safe_cache_root)" || { err "validate: refusing cleanup under unsafe CACHE_ROOT"; return 1; }
  rm -rf "$root/docker/$name" 2>/dev/null || true
  log "validate: OK (container removed). Provisioning mechanics verified on this host."
}
