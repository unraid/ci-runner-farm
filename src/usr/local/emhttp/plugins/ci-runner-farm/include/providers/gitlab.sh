#!/bin/bash
# GitLab CI/CD provider adapter for CI Runner Farm.
# Uses persistent official Runner managers plus Docker-executor job containers.

gitlab_token_ready() {
  printf '%s' "$GITLAB_RUNNER_TOKEN" \
    | grep -qE '^glrt-[A-Za-z0-9_.-]{10,507}$'
}
gitlab_token_name() { echo "GitLab runner authentication token"; }
gitlab_builtin_image() { echo "$GITLAB_BUILTIN_IMAGE"; }

# Runner 16.0 introduced manager-only unregister with system_id. Older clients
# can route the shared glrt- token through DELETE /runners and delete the runner
# entity used by every slot, so every mode requires a verified >=16 image.
# Host-socket cleanup additionally relies on exact service container_labels,
# fixed in 18.5.0. Cache successful image/requirement probes per CLI process.
GITLAB_MANAGER_VERSION_VALIDATED_KEY="${GITLAB_MANAGER_VERSION_VALIDATED_KEY:-}"
gitlab_validate_manager_version() {
  local image="${1:-$GITLAB_RUNNER_IMAGE}" purpose="${2:-runtime}"
  local output version major minor patch key
  key="$image:$purpose:${DIND:-true}"
  [ "$GITLAB_MANAGER_VERSION_VALIDATED_KEY" != "$key" ] || return 0

  output="$(docker run --rm "$image" --version 2>&1)" \
    || { err "could not execute GitLab Runner manager image $image --version"; return 1; }
  version="$(printf '%s\n' "$output" \
    | sed -nE 's/^[[:space:]]*Version:[[:space:]]*v?([0-9]{1,4})\.([0-9]{1,4})\.([0-9]{1,4})[[:space:]]*$/\1.\2.\3/p' \
    | head -1)"
  [ -n "$version" ] \
    || { err "GitLab requires an official Runner image with a parseable stable version (minimum 16.0.0)"; return 1; }
  IFS=. read -r major minor patch <<< "$version"
  if (( 10#$major < 16 )); then
    err "GitLab shared-manager lifecycle requires GitLab Runner 16.0.0 or newer for manager-only unregister; $image reports $version"
    return 1
  fi
  if [ "$purpose" = runtime ] && [ "$DIND" != true ] \
     && (( 10#$major < 18 || (10#$major == 18 && 10#$minor < 5) )); then
    err "GitLab host-socket mode requires GitLab Runner 18.5.0 or newer; $image reports $version"
    return 1
  fi
  GITLAB_MANAGER_VERSION_VALIDATED_KEY="$key"
}

gitlab_validate_host_socket_manager_version() {
  gitlab_validate_manager_version "${1:-$GITLAB_RUNNER_IMAGE}" runtime
}

gitlab_shutdown_timeout() {
  local timeout="${GITLAB_SHUTDOWN_TIMEOUT:-7200}"
  case "$timeout" in ''|*[!0-9]*) timeout=7200 ;; esac
  [ "$timeout" -ge 30 ] 2>/dev/null && [ "$timeout" -le 86400 ] 2>/dev/null || timeout=7200
  printf '%s\n' "$timeout"
}
gitlab_docker_stopping_timeout() { gitlab_shutdown_timeout; }
gitlab_docker_stopping() { provider_stop_container "$1"; }

gitlab_confgen() {
  # Hash the exact token values loaded after fleet.lock was acquired. Reading the
  # files again here can pair a stale in-memory token with a freshly rotated file
  # hash, incorrectly stamping a replacement as current.
  # Keep a runtime-schema salt in the fingerprint so security-sensitive argv
  # changes also retire sidecars created by an older plugin build.
  printf '%s\0' gitlab-dind-unix-only-v2 "$GITLAB_URL" "$GITLAB_RUNNER_IMAGE" "$GITLAB_DIND_IMAGE" \
    "$GITLAB_RUNNER_TOKEN" "$GITLAB_CA_FINGERPRINT" "$REGISTRY_TOKEN" \
    "$RUNNER_CPUS" "$RUNNER_MEMORY" "$CACHE_MOUNTS" "$GITLAB_SHUTDOWN_TIMEOUT" \
    "$GITLAB_ALLOWED_IMAGES" "$GITLAB_ALLOWED_SERVICES" "$GITLAB_PULL_POLICY" "$GITLAB_SHM_SIZE" \
    "$DIND" "$SHARE_DOCKER_SOCK" "$IMAGE_SOURCE" "$IMAGE" \
    "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" \
    "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" \
    | sha256sum | cut -c1-12
}

gitlab_url() {
  local u="$GITLAB_URL"
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  printf '%s\n' "$u"
}

gitlab_validate_url() {
  local url authority host port
  url="$(gitlab_url)"
  case "$url" in https://*) ;; *) err "GITLAB_URL must begin with https:// so reusable runner/API tokens are never sent in cleartext"; return 1 ;; esac
  case "$url" in *[[:space:]\"\'\\]*|*@*|*\?*|*\#*) err "GITLAB_URL contains unsupported characters, credentials, a query, or a fragment"; return 1 ;; esac
  authority="${url#https://}"; authority="${authority%%/*}"
  [ -n "$authority" ] || { err "GITLAB_URL must include a host"; return 1; }
  case "$authority" in *:*:*) err "GITLAB_URL authority must be a hostname or IPv4 address with an optional port"; return 1 ;; esac
  host="$authority"; port=""
  case "$authority" in *:*) host="${authority%:*}"; port="${authority##*:}" ;; esac
  printf '%s' "$host" | grep -qE '^[A-Za-z0-9][A-Za-z0-9.-]*$' \
    || { err "GITLAB_URL contains an invalid host"; return 1; }
  if [ -n "$port" ]; then
    case "$port" in *[!0-9]*) err "GITLAB_URL port must be numeric"; return 1 ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "GITLAB_URL port is out of range"; return 1; }
  fi
}

gitlab_validate_image_patterns() {
  local label="$1" raw="$2" item
  local -a items=()
  [ -z "$raw" ] && return 0
  case "$raw" in *$'\n'*|*$'\r'*|*$'\t'*) err "$label must be a space-separated, single-line pattern list"; return 1 ;; esac
  read -r -a items <<< "$raw"
  [ "${#items[@]}" -gt 0 ] || { err "$label does not contain an image pattern"; return 1; }
  for item in "${items[@]}"; do
    printf '%s' "$item" | grep -qE '^[!A-Za-z0-9_./:@*?+-]+$' \
      || { err "$label contains an unsupported image-pattern character"; return 1; }
  done
}

gitlab_validate_cache_mounts() {
  local m source dest rest seen=$'\n'
  case "$CACHE_MOUNTS" in *$'\n'*|*$'\r'*|*$'\t'*) err "CACHE_MOUNTS must be a space-separated, single-line list"; return 1 ;; esac
  for m in $CACHE_MOUNTS; do
    case "$m" in *:*) ;; *) err "GitLab cache mount '$m' must use host-subdir:/absolute/container/path"; return 1 ;; esac
    source="${m%%:*}"; rest="${m#*:}"; dest="$(gitlab_job_cache_destination "$rest")"
    case "$rest" in *:*) err "GitLab cache mount '$m' contains an unsupported extra colon"; return 1 ;; esac
    printf '%s' "$source" | grep -qE '^[A-Za-z0-9._+@/-]+$' \
      || { err "GitLab cache mount '$m' has an unsafe host subdirectory"; return 1; }
    case "/$source/" in *'/../'*|*'/./'*|*'//'*) err "GitLab cache mount '$m' has an unsafe host subdirectory"; return 1 ;; esac
    printf '%s' "$dest" | grep -qE '^/[A-Za-z0-9._+@/-]+$' \
      || { err "GitLab cache destination '$dest' must be a safe absolute Linux path"; return 1; }
    case "$dest" in */../*|*/./*|*//*|*/) err "GitLab cache destination '$dest' must be lexically canonical"; return 1 ;; esac
    case "$dest" in
      /|/cache|/cache/*|/var/run/docker.sock|/var/run/docker.sock/*|/etc/gitlab-runner/certs/ca.crt|/etc/gitlab-runner/certs/ca.crt/*)
        err "GitLab cache destination '$dest' conflicts with a Runner-managed mount"
        return 1 ;;
    esac
    case "$seen" in *$'\n'"$dest"$'\n'*) err "duplicate GitLab cache destination: $dest"; return 1 ;; esac
    seen="${seen}${dest}"$'\n'
  done
}

gitlab_effective_pull_policy() {
  case "$GITLAB_PULL_POLICY" in
    auto) [ "$IMAGE_SOURCE" = "remote" ] && echo always || echo if-not-present ;;
    *) printf '%s\n' "$GITLAB_PULL_POLICY" ;;
  esac
}

gitlab_validate_settings() {
  gitlab_validate_url || return 1
  printf '%s' "$GITLAB_RUNNER_IMAGE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_./:@-]*$' \
    || { err "GITLAB_RUNNER_IMAGE is not a safe Docker image reference"; return 1; }
  case "$GITLAB_SHUTDOWN_TIMEOUT" in
    ''|*[!0-9]*|0[0-9]*) err "GITLAB_SHUTDOWN_TIMEOUT must be a base-10 integer from 30 to 86400 seconds without leading zeros"; return 1 ;;
  esac
  [ "$GITLAB_SHUTDOWN_TIMEOUT" -ge 30 ] && [ "$GITLAB_SHUTDOWN_TIMEOUT" -le 86400 ] \
    || { err "GITLAB_SHUTDOWN_TIMEOUT must be between 30 and 86400 seconds"; return 1; }
  gitlab_validate_image_patterns GITLAB_ALLOWED_IMAGES "$GITLAB_ALLOWED_IMAGES" || return 1
  gitlab_validate_image_patterns GITLAB_ALLOWED_SERVICES "$GITLAB_ALLOWED_SERVICES" || return 1
  gitlab_validate_cache_mounts || return 1
  case "$GITLAB_PULL_POLICY" in
    auto|always|if-not-present) ;;
    *) err "GITLAB_PULL_POLICY must be auto, always, or if-not-present"; return 1 ;;
  esac
  if [ "$GITLAB_PULL_POLICY" = always ] && [ "$IMAGE_SOURCE" != remote ]; then
    err "GITLAB_PULL_POLICY=always requires a remote default job image; a locally built tag cannot be pulled for real jobs"
    return 1
  fi
  case "$GITLAB_SHM_SIZE" in
    ''|*[!0-9]*|0[0-9]*) err "GITLAB_SHM_SIZE must be a non-negative integer number of bytes"; return 1 ;;
  esac
  if [ "${#GITLAB_SHM_SIZE}" -gt 19 ] \
     || { [ "${#GITLAB_SHM_SIZE}" -eq 19 ] && [[ "$GITLAB_SHM_SIZE" > 9223372036854775807 ]]; }; then
    err "GITLAB_SHM_SIZE exceeds GitLab Runner's signed 64-bit byte limit"
    return 1
  fi
  if [ "$DIND" != "true" ] && [ "$SHARE_DOCKER_SOCK" != "true" ]; then
    err "GitLab's Docker executor needs DIND=true or an explicitly shared host docker.sock"
    return 1
  fi
  if [ "$DIND" != "true" ] && [ "$NETWORK_ISOLATION" != "off" ]; then
    err "GitLab host-socket mode cannot place Docker-executor job/helper/service networks on the manager's isolated bridge; use DIND=true or NETWORK_ISOLATION=off"
    return 1
  fi
  if [ -n "$REGISTRY_SERVER" ] && ! gitlab_registry_authority >/dev/null 2>&1; then
    err "REGISTRY_SERVER must be a hostname with an optional port (an https:// prefix is accepted; insecure HTTP is refused)"
    return 1
  fi
  return 0
}

gitlab_strict_endpoint() { gitlab_url; }
gitlab_registry_credentials() { return 0; }
# The host daemon launches Docker-executor jobs only in explicit host-socket
# mode. DinD job images must be authenticated, trusted, and pulled by the
# private per-slot daemon instead (not prematurely by Unraid's Docker daemon).
gitlab_remote_image_host_pull_required() { [ "$DIND" != "true" ]; }
gitlab_prepare_remote_image() {
  local image="$1" policy
  [ "$DIND" != true ] || return 0
  policy="$(gitlab_effective_pull_policy)"
  case "$policy" in
    always)
      registry_login && host_docker_pull "$image" ;;
    if-not-present)
      docker image inspect "$image" >/dev/null 2>&1 \
        || { registry_login && host_docker_pull "$image"; } ;;
    *)
      err "unsupported effective GitLab pull policy: $policy"; return 1 ;;
  esac
}
gitlab_remote_image_update_allowed() {
  [ "$DIND" != true ] && [ "$(gitlab_effective_pull_policy)" = always ]
}

gitlab_socket_path() {
  local p
  p="$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.socket" }}' "$1" 2>/dev/null)"
  [ -n "$p" ] && printf '%s\n' "$p" || printf '%s\n' "$CACHE_ROOT/gitlab-sockets/$1/docker.sock"
}

gitlab_job_container() {
  local c="$1" sock
  sock="$(gitlab_socket_path "$c")"
  if [ "$sock" = "/var/run/docker.sock" ]; then
    docker ps -q \
      --filter 'label=com.gitlab.gitlab-runner.managed=true' \
      --filter 'label=com.gitlab.gitlab-runner.type=build' \
      --filter "label=net.unraid.ci-runner-farm.slot=$c" 2>/dev/null | head -1
    return
  fi
  docker --host "unix://$sock" ps -q \
    --filter 'label=com.gitlab.gitlab-runner.managed=true' \
    --filter 'label=com.gitlab.gitlab-runner.type=build' 2>/dev/null | head -1
}

# Enumerate every running build/helper/service owned by one slot. This is the
# destructive-lifecycle guard, so inability to query the selected Docker daemon
# is different from a positively empty result and must propagate non-zero.
gitlab_running_executor_containers() {
  local c="$1" sock
  sock="$(gitlab_socket_path "$c")"
  if [ "$sock" = "/var/run/docker.sock" ]; then
    docker ps -q \
      --filter 'label=com.gitlab.gitlab-runner.managed=true' \
      --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
      --filter "label=net.unraid.ci-runner-farm.slot=$c" 2>/dev/null
    return
  fi
  docker --host "unix://$sock" ps -q \
    --filter 'label=com.gitlab.gitlab-runner.managed=true' 2>/dev/null
}

gitlab_remove_host_jobs() {
  local slot="${1:-}" jobs
  if [ -n "$slot" ]; then
    jobs="$(docker ps -aq \
      --filter 'label=com.gitlab.gitlab-runner.managed=true' \
      --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
      --filter "label=net.unraid.ci-runner-farm.slot=$slot" 2>/dev/null)" \
      || { err "could not enumerate host-socket GitLab jobs for $slot"; return 1; }
  else
    jobs="$(docker ps -aq \
      --filter 'label=com.gitlab.gitlab-runner.managed=true' \
      --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
      --filter 'label=net.unraid.ci-runner-farm.slot' 2>/dev/null)" \
      || { err "could not enumerate host-socket GitLab jobs"; return 1; }
  fi
  [ -z "$jobs" ] || docker rm -f $jobs >/dev/null 2>&1
}

gitlab_runner_state() {
  local c="$1" st metrics job last
  # The manager can be stopped while a host-socket or restarted DinD executor
  # container is still alive (for example across a Docker-service interruption).
  # Treat that as positively busy before consulting manager state so reconcile,
  # autoscale, and ordinary Stop never destroy the surviving workload merely
  # because its control process is currently exited.
  if ! job="$(gitlab_job_container "$c")"; then
    echo error
    return
  fi
  [ -n "$job" ] && { echo busy; return; }
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
  [ "$st" = "running" ] || { case "$st" in created|restarting) echo starting ;; *) echo error ;; esac; return; }
  metrics="$(docker exec "$c" sh -c 'wget -qO- http://127.0.0.1:9252/metrics 2>/dev/null || true' 2>/dev/null)"
  printf '%s\n' "$metrics" | grep -Eq '^gitlab_runner_jobs(\{[^}]*\})?[[:space:]]+[1-9]' && { echo busy; return; }
  last="$(docker logs --tail 30 "$c" 2>&1 | grep -iE 'Checking for jobs|Starting multi-runner|received job|job (succeeded|failed)|ERROR|FATAL' | tail -1 \
    | tr '[:upper:]' '[:lower:]')"
  case "$last" in
    *"checking for jobs"*"received"*|*"received job"*) echo busy ;;
    *error*|*fatal*) echo error ;;
    *"checking for jobs"*|*"starting multi-runner"*|*"job succeeded"*|*"job failed"*) echo idle ;;
    *) echo starting ;;
  esac
}

gitlab_scale_down_eligible() { [ "$(runner_state "$1")" = idle ]; }
gitlab_autoscale_counts() {
  local c phase names
  cur=0; busy=0; idle=0
  names="$(owned_managed_names)" || return 1
  for c in $names; do
    [ -n "$c" ] || continue; cur=$((cur+1)); phase="$(runner_state "$c")" || return 1
    case "$phase" in busy) busy=$((busy+1)) ;; idle) idle=$((idle+1)) ;; esac
  done
}

gitlab_api_token_ready() {
  [ "${#GITLAB_API_TOKEN}" -ge 8 ] && [ "${#GITLAB_API_TOKEN}" -le 512 ] \
    && printf '%s' "$GITLAB_API_TOKEN" | grep -qE '^[A-Za-z0-9_.@:+/=~-]+$'
}

# Deliberately no --location. curl strips only Authorization on a cross-host
# redirect, so a followed 3xx would resend PRIVATE-TOKEN to whatever host the
# instance names. These are plain /api/v4 requests against the configured base
# URL and have no legitimate reason to leave it. `-q` must be curl's first
# argument so an operator's ~/.curlrc cannot turn redirects back on.
gitlab_api_request() {
  local method="$1" path="$2" body="$3" headers="$4" status ca=()
  gitlab_validate_url >/dev/null 2>&1 || return 1
  gitlab_api_token_ready || return 1
  [ -f "$GITLAB_CA_FILE" ] && ca=( --cacert "$GITLAB_CA_FILE" )
  : > "$body" && : > "$headers" || return 1
  status="$(
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$GITLAB_API_TOKEN" \
      | curl -q -fsS -g -m 12 -X "$method" --config - \
        -H 'Accept: application/json' ${ca[@]+"${ca[@]}"} \
        -D "$headers" -o "$body" -w '%{http_code}' \
        "$(gitlab_url)/api/v4${path}" 2>/dev/null
  )" || return 1
  case "$status" in 2[0-9][0-9]) return 0 ;; *) return 1 ;; esac
}

gitlab_api() {
  local method="$1" path="$2" tmpdir body headers rc=1
  tmpdir="$(mktemp -d "$RUNDIR/gitlab-api.XXXXXX" 2>/dev/null)" || return 1
  body="$tmpdir/body"; headers="$tmpdir/headers"
  if gitlab_api_request "$method" "$path" "$body" "$headers"; then
    cat "$body"; rc=$?
  fi
  rm -rf -- "$tmpdir"
  return "$rc"
}

gitlab_api_capture() {
  gitlab_api_request GET "$1" "$2" "$3"
}

# Split the operator-entered monitored-project list without pathname expansion:
# an entry such as group/* is a literal telemetry path, never a filesystem glob,
# and `for p in $GITLAB_PROJECTS` would expand it against the process CWD. Only
# well-formed namespace/project paths are emitted; anything else is advisory
# input that cannot address a real project, so it is skipped rather than
# blocking the fleet on a telemetry-only field.
gitlab_project_path_valid() {
  local path="$1" segment
  local -a segments=()
  case "$path" in ''|/*|*/|*'//'*) return 1 ;; esac
  IFS='/' read -r -a segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] || return 1
  for segment in "${segments[@]}"; do
    case "$segment" in ''|.|..|-*) return 1 ;; esac
    printf '%s' "$segment" \
      | grep -qE '^[A-Za-z0-9_.][A-Za-z0-9._-]*$' || return 1
  done
}

gitlab_projects_list() {
  local -a items=()
  local item normalized
  # `read -a` consumes only one physical line. Normalize newlines to another
  # default-IFS character first so the complete setting retains the historical
  # space/tab/newline word-list behavior without ever enabling pathname globbing.
  normalized="${GITLAB_PROJECTS//$'\n'/ }"
  read -r -a items <<< "$normalized"
  [ "${#items[@]}" -gt 0 ] || return 0
  for item in "${items[@]}"; do
    gitlab_project_path_valid "$item" || continue
    printf '%s\n' "$item"
  done
}

gitlab_public_repo_problem() {
  { [ "$DIND" = "true" ] || [ "$SHARE_DOCKER_SOCK" = "true" ]; } || { echo ""; return; }
  local cached; cached="$(security_cache_get)" && { printf '%s' "$cached"; return; }
  local msg="" pub="" project body vis encoded
  [ "$DIND" = true ] \
    && msg="GitLab jobs control their privileged per-slot DinD daemon and can inspect or remove that slot's job, helper, and service containers. The slot limits ordinary Docker access but privileged DinD is not a security boundary against the Unraid host. Route only trusted projects/refs here and enforce tags/protected-runner policy in GitLab; monitored projects are telemetry only and do not define runner scope."
  [ "$DIND" != "true" ] && [ "$SHARE_DOCKER_SOCK" = "true" ] \
    && msg="GitLab host-socket mode gives every accepted job root-equivalent control of this Unraid host. Restrict the runner in GitLab to trusted, protected projects and refs; isolated DinD is the safer default."
  if gitlab_api_token_ready && [ -n "$GITLAB_PROJECTS" ]; then
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      encoded="$(urlencode "$project")"
      body="$(gitlab_api GET "/projects/$encoded" 2>/dev/null)"
      vis="$(printf '%s' "$body" | grep -o '"visibility"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
      [ "$vis" = public ] && pub="$pub $project"
    done <<< "$(gitlab_projects_list)"
    [ -n "$pub" ] && msg="PUBLIC GitLab project(s) monitored while jobs can control a Docker daemon:${pub}. Untrusted merge-request code can control that slot's job, helper, and service containers; the privileged DinD sidecar is not a host security boundary. Use protected/trusted projects and runner policies. Host-socket mode directly exposes the Unraid Docker daemon. Monitored projects are advisory and do not define the runner's scope."
  fi
  security_cache_put "$msg"
  printf '%s' "$msg"
}

gitlab_toml_string() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/}"; s="${s//$'\r'/}"
  printf '"%s"' "$s"
}

gitlab_toml_array() {
  local raw="$1" item first=1
  local -a items=()
  read -r -a items <<< "$raw"
  printf '['
  for item in "${items[@]}"; do
    [ "$first" -eq 1 ] || printf ', '
    printf '%s' "$(gitlab_toml_string "$item")"
    first=0
  done
  printf ']'
}

gitlab_slot_config_dir() { printf '%s/gitlab-runners/%s\n' "$CFGDIR" "$1"; }
gitlab_socket_dir()      { printf '%s/gitlab-sockets/%s\n' "$CACHE_ROOT" "$1"; }
gitlab_sidecar_name()    { printf '%s-dind\n' "$1"; }
gitlab_job_cache_destination() { printf '%s\n' "$1"; }
gitlab_slot_ca_file() { printf '%s/certs/gitlab-ca.crt\n' "$(gitlab_slot_config_dir "$1")"; }
gitlab_unregister_marker() { printf '%s/.remote-unregister-complete\n' "$(gitlab_slot_config_dir "$1")"; }

# Bind a successful remote manager deletion to the exact persisted config and
# system ID that produced it. The marker lets a later local Docker-rm retry skip
# a second, non-idempotent API call without ever applying to a rewritten manager.
gitlab_unregister_identity() {
  local dir="$1"
  [ -s "$dir/config.toml" ] && [ -s "$dir/.runner_system_id" ] || return 1
  { cat "$dir/config.toml"; printf '\0'; cat "$dir/.runner_system_id"; } \
    | sha256sum | cut -d' ' -f1
}

gitlab_unregister_is_complete() {
  local dir="$1" identity="$2" marker="$1/.remote-unregister-complete"
  [ -s "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$identity" ]
}

gitlab_mark_unregister_complete() {
  local dir="$1" identity="$2" marker="$1/.remote-unregister-complete" tmp
  tmp="$marker.tmp"
  ( umask 077; printf '%s\n' "$identity" > "$tmp" ) || return 1
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$marker"
}

gitlab_clear_unregister_complete() {
  local dir="$1"
  rm -f "$dir/.remote-unregister-complete" "$dir/.remote-unregister-complete.tmp"
}

# Each manager keeps the CA that was active when its URL/token config was
# generated. Retirement must use that same trust snapshot even if Settings has
# already replaced or removed the farm-wide CA while a stale manager drains.
gitlab_snapshot_ca() {
  local dir="$1" dest="$1/certs/gitlab-ca.crt" tmp="$1/certs/gitlab-ca.crt.tmp"
  mkdir -p "$dir/certs" || return 1
  chmod 700 "$dir/certs" 2>/dev/null || true
  if [ "$GITLAB_CA_PRESENT" = true ]; then
    [ "$GITLAB_CA_FINGERPRINT" != "!" ] || return 1
    ( umask 077; printf '%s\n' "$GITLAB_CA_CONTENT" > "$tmp" ) || return 1
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$dest" "$tmp" || return 1
  fi
}

gitlab_ensure_system_id() {
  local dir="$1" file="$1/.runner_system_id" tmp id
  # GitLab Runner accepts exactly an s_/r_ prefix plus 12 alphanumeric
  # characters. An arbitrary longer identifier is treated as missing and Runner
  # silently generates a different one, defeating persistence across restarts.
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ ! -L "$file" ] && [ -f "$file" ] && [ -s "$file" ] \
      && grep -qE '^[sr]_[0-9A-Za-z]{12}$' "$file" 2>/dev/null \
      || { err "refusing to replace an invalid persisted GitLab runner system ID in $dir"; return 1; }
    chmod 600 "$file" 2>/dev/null \
      || { err "could not protect persisted GitLab runner system ID in $dir"; return 1; }
    return 0
  fi
  # Six random bytes produce the same 12-hex-character payload length used by
  # Runner's stable system-ID contract, while remaining unique per farm slot.
  id="r_$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  printf '%s' "$id" | grep -qE '^r_[a-f0-9]{12}$' \
    || { err "could not generate a unique GitLab runner system ID"; return 1; }
  tmp="$file.tmp"
  ( umask 077; printf '%s\n' "$id" > "$tmp" ) || return 1
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# POST /runners/verify with a glrt- token is not read-only: GitLab ensures a
# manager row for the supplied system ID. Use a dedicated persistent probe
# identity and immediately unregister that exact manager through the official
# >=16 client. If the process or network fails between those operations, keep
# the protected probe config so the next attempt can re-verify (idempotently)
# and finish manager-only cleanup before any fleet slot is retired.
gitlab_probe_dir() { printf '%s/gitlab-token-probe\n' "$CFGDIR"; }
gitlab_probe_name() { printf '%s\n' 'ci-runner-farm-token-probe'; }
gitlab_probe_target() {
  printf '%s\0' "$(gitlab_url)" "$GITLAB_RUNNER_TOKEN" "$GITLAB_CA_FINGERPRINT" \
    | sha256sum | cut -d' ' -f1
}

gitlab_probe_scrub() {
  local dir="$1"
  rm -f "$dir/config.toml" "$dir/config.toml.tmp" \
    "$dir/.target" "$dir/.target.tmp" \
    "$dir/certs/gitlab-ca.crt" "$dir/certs/gitlab-ca.crt.tmp" || return 1
  rmdir "$dir/certs" 2>/dev/null || true
}

gitlab_probe_write() {
  local dir="$1" tmp="$1/config.toml.tmp" target_tmp="$1/.target.tmp"
  local slot_ca="$1/certs/gitlab-ca.crt"
  mkdir -p "$dir" "$dir/certs" || return 1
  chmod 700 "$dir" "$dir/certs" 2>/dev/null || return 1
  gitlab_ensure_system_id "$dir" || return 1
  gitlab_snapshot_ca "$dir" || return 1
  ( umask 077
    {
      echo 'concurrent = 1'
      echo '[[runners]]'
      printf '  name = %s\n' "$(gitlab_toml_string "$(gitlab_probe_name)")"
      printf '  url = %s\n' "$(gitlab_toml_string "$(gitlab_url)")"
      printf '  token = %s\n' "$(gitlab_toml_string "$GITLAB_RUNNER_TOKEN")"
      echo '  executor = "docker"'
      [ -f "$slot_ca" ] && echo '  tls-ca-file = "/etc/gitlab-runner/certs/gitlab-ca.crt"'
    } > "$tmp"
    printf '%s\n' "$(gitlab_probe_target)" > "$target_tmp"
  ) || { rm -f "$tmp" "$target_tmp"; return 1; }
  chmod 600 "$tmp" "$target_tmp" 2>/dev/null \
    || { rm -f "$tmp" "$target_tmp"; return 1; }
  mv "$tmp" "$dir/config.toml" && mv "$target_tmp" "$dir/.target"
}

# Echo only the HTTP status. Saved probe material is parsed from the restricted
# TOML so interrupted cleanup remains possible even after Settings changes.
gitlab_probe_verify_request() {
  local dir="$1" url token system_id body code ca=()
  url="$(sed -n 's/^[[:space:]]*url[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$dir/config.toml" | head -1)"
  token="$(sed -n 's/^[[:space:]]*token[[:space:]]*=[[:space:]]*"\(glrt-[A-Za-z0-9_.-]*\)"[[:space:]]*$/\1/p' "$dir/config.toml" | head -1)"
  system_id="$(cat "$dir/.runner_system_id" 2>/dev/null)"
  local GITLAB_URL="$url"
  gitlab_validate_url >/dev/null 2>&1 || return 1
  printf '%s' "$token" | grep -qE '^glrt-[A-Za-z0-9_.-]{10,507}$' || return 1
  printf '%s' "$system_id" | grep -qE '^[sr]_[0-9A-Za-z]{12}$' || return 1
  if grep -qE '^[[:space:]]*tls-ca-file[[:space:]]*=' "$dir/config.toml"; then
    [ -s "$dir/certs/gitlab-ca.crt" ] || return 1
    ca=( --cacert "$dir/certs/gitlab-ca.crt" )
  fi
  body="token=$(urlencode "$token")&system_id=$(urlencode "$system_id")"
  code="$(printf '%s' "$body" \
    | curl -sS -g -m 12 -X POST -o /dev/null -w '%{http_code}' \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-binary @- ${ca[@]+"${ca[@]}"} \
      "$(gitlab_url)/api/v4/runners/verify" 2>/dev/null)" || return 1
  printf '%s\n' "$code"
}

gitlab_probe_unregister() {
  local dir="$1" image="$GITLAB_RUNNER_IMAGE" network tmpdir ca_source="" saved_url
  docker image inspect "$image" >/dev/null 2>&1 \
    || host_docker_pull "$image" >/dev/null 2>&1 \
    || { err "could not obtain GitLab Runner image for token-probe cleanup"; return 1; }
  gitlab_validate_manager_version "$image" unregister || return 1
  [ "$NETWORK_ISOLATION" = off ] && network=bridge || network="$RUNNER_NETWORK"
  printf '%s' "$network" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' || return 1
  if ! docker network inspect "$network" >/dev/null 2>&1; then
    ensure_network \
      || { err "GitLab token probe cannot create missing Docker network $network"; return 1; }
  fi
  if [ "$NETWORK_ISOLATION" = strict ]; then
    saved_url="$(sed -n 's/^[[:space:]]*url[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$dir/config.toml" | head -1)"
    local CI_PROVIDER=gitlab GITLAB_URL="$saved_url"
    firewall_prepare_replacement \
      || { err "GitLab token probe cannot install its saved strict endpoint exception"; return 1; }
  fi
  tmpdir="$(mktemp -d "$RUNDIR/gitlab-token-probe.XXXXXX" 2>/dev/null)" || return 1
  chmod 700 "$tmpdir" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
  if ! ( umask 077; cp "$dir/config.toml" "$tmpdir/config.toml" \
      && cp "$dir/.runner_system_id" "$tmpdir/.runner_system_id" ); then
    rm -rf "$tmpdir"; return 1
  fi
  if grep -qE '^[[:space:]]*tls-ca-file[[:space:]]*=' "$tmpdir/config.toml"; then
    ca_source="$dir/certs/gitlab-ca.crt"
    [ -s "$ca_source" ] || { rm -rf "$tmpdir"; return 1; }
    mkdir -p "$tmpdir/certs" \
      && ( umask 077; cp "$ca_source" "$tmpdir/certs/gitlab-ca.crt" ) \
      || { rm -rf "$tmpdir"; return 1; }
  fi
  chmod 600 "$tmpdir/config.toml" "$tmpdir/.runner_system_id" 2>/dev/null \
    || { rm -rf "$tmpdir"; return 1; }
  if [ -n "$ca_source" ]; then
    chmod 600 "$tmpdir/certs/gitlab-ca.crt" 2>/dev/null \
      || { rm -rf "$tmpdir"; return 1; }
  fi
  if ! docker run --rm --network "$network" -v "$tmpdir:/etc/gitlab-runner" "$image" \
      unregister --name "$(gitlab_probe_name)" >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    err "GitLab token probe manager could not be unregistered; protected retry material was retained"
    return 1
  fi
  rm -rf "$tmpdir"
}

gitlab_recover_pending_probe() {
  local dir old_target code
  dir="$(gitlab_probe_dir)"
  if [ ! -s "$dir/config.toml" ]; then
    # The API call happens only after the complete config is atomically
    # published. Partial temp files therefore cannot represent a remote manager.
    rm -f "$dir/config.toml.tmp" "$dir/.target" "$dir/.target.tmp" \
      "$dir/certs/gitlab-ca.crt.tmp" 2>/dev/null || return 1
    return 0
  fi
  old_target="$(cat "$dir/.target" 2>/dev/null || true)"
  code="$(gitlab_probe_verify_request "$dir")" \
    || { err "GitLab token probe has an unknown remote state; retry with its saved URL/token/CA available"; return 1; }
  [ "$code" = 200 ] \
    || { err "GitLab cannot recover the pending token probe manager (HTTP ${code:-unknown}); restore its prior credential or remove that manager in GitLab"; return 1; }
  gitlab_probe_unregister "$dir" || return 1
  gitlab_probe_scrub "$dir" || { err "could not scrub completed GitLab token probe"; return 1; }
  GITLAB_RECOVERED_PROBE_TARGET="$old_target"
}

gitlab_verify_manager_token() {
  local name="$1" suffix dir current_target code fresh=0
  case "$name" in "$NAME_PREFIX"-[0-9]*) suffix="${name#"$NAME_PREFIX"-}" ;; *) err "refusing unsafe GitLab verification slot: $name"; return 1 ;; esac
  case "$suffix" in ''|*[!0-9]*) err "refusing unsafe GitLab verification slot: $name"; return 1 ;; esac
  dir="$(gitlab_probe_dir)"
  GITLAB_RECOVERED_PROBE_TARGET=""
  gitlab_recover_pending_probe || return 1
  gitlab_validate_url || return 1
  gitlab_token_ready || { err "no valid GitLab glrt- runner token configured"; return 1; }
  current_target="$(gitlab_probe_target)"
  if [ "${GITLAB_TOKEN_PROBE_VALIDATED_TARGET:-}" = "$current_target" ]; then
    return 0
  fi
  if [ -n "$GITLAB_RECOVERED_PROBE_TARGET" ] \
     && [ "$GITLAB_RECOVERED_PROBE_TARGET" = "$current_target" ]; then
    GITLAB_TOKEN_PROBE_VALIDATED_TARGET="$current_target"
    log "verified GitLab runner authentication for $name and removed its temporary probe manager"
    return 0
  fi

  gitlab_probe_write "$dir" || { err "could not persist the GitLab token probe identity"; return 1; }
  fresh=1
  if ! code="$(gitlab_probe_verify_request "$dir")"; then
    err "GitLab token verification outcome is unknown; retry to complete exact probe-manager cleanup"
    return 1
  fi
  if [ "$code" != 200 ]; then
    if [ "$fresh" = 1 ] && [ "$code" = 403 ]; then
      gitlab_probe_scrub "$dir" || true
      err "GitLab rejected the runner token (HTTP 403)"
    else
      err "GitLab token verification failed (HTTP ${code:-unknown}); retry to complete probe-manager cleanup"
    fi
    return 1
  fi
  gitlab_probe_unregister "$dir" || return 1
  gitlab_probe_scrub "$dir" || { err "could not scrub completed GitLab token probe"; return 1; }
  GITLAB_TOKEN_PROBE_VALIDATED_TARGET="$current_target"
  log "verified GitLab runner authentication for $name and removed its temporary probe manager"
}

gitlab_write_docker_auth() {
  local name="$1" dir file auth authority
  dir="$(gitlab_slot_config_dir "$name")/docker"; file="$dir/config.json"
  mkdir -p "$dir" || return 1; chmod 700 "$dir" 2>/dev/null || true
  # GitLab jobs and services may override a locally built default image. Keep
  # configured registry auth available to every manager even in that case; the
  # GitHub adapter retains its historical remote-default-only host login policy.
  if [ -z "$REGISTRY_SERVER" ] || [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_TOKEN" ]; then
    rm -f "$file" 2>/dev/null \
      || { err "could not remove stale registry auth for $name"; return 1; }
    return 0
  fi
  authority="$(gitlab_registry_authority)" \
    || { err "registry server is not a safe hostname/port authority"; return 1; }
  auth="$(printf '%s:%s' "$REGISTRY_USERNAME" "$REGISTRY_TOKEN" | base64 | tr -d '\r\n')"
  ( umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}\n' \
      "$(printf '%s' "$authority" | json_escape)" "$(printf '%s' "$auth" | json_escape)" > "$file.tmp" ) || return 1
  chmod 600 "$file.tmp" 2>/dev/null || { rm -f "$file.tmp"; return 1; }
  mv "$file.tmp" "$file"
}

# Docker's registry trust directory is keyed by the exact registry authority
# (hostname, plus a non-default port). Keep this parser deliberately narrower
# than a general URL parser: its output becomes part of a DinD mount target.
gitlab_registry_authority() {
  local spec="$REGISTRY_SERVER" host port=""
  case "$spec" in https://*) spec="${spec#https://}" ;; http://*) return 1 ;; *://*) return 1 ;; esac
  spec="${spec%%/*}"
  case "$spec" in ''|*[[:space:]\"\'\\]*|*@*|*,*|*\?*|*\#*|*:*:*) return 1 ;; esac
  host="$spec"
  case "$spec" in *:*) host="${spec%:*}"; port="${spec##*:}" ;; esac
  printf '%s' "$host" | grep -qE '^[A-Za-z0-9][A-Za-z0-9.-]*$' || return 1
  if [ -n "$port" ]; then
    case "$port" in *[!0-9]*) return 1 ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  fi
  printf '%s\n' "$spec"
}

gitlab_write_config() {
  local idx="$1" name="$2" dir tmp url token job_image socket_source executor_host pull_policy slot_ca
  dir="$(gitlab_slot_config_dir "$name")"; tmp="$dir/config.toml.tmp"
  slot_ca="$dir/certs/gitlab-ca.crt"
  url="$(gitlab_url)"; token="$GITLAB_RUNNER_TOKEN"; job_image="$(effective_image)"
  if [ "$DIND" = "true" ]; then
    socket_source="/runner-services/docker.sock"
    executor_host="unix:///runner-services/docker.sock"
  else
    socket_source="/var/run/docker.sock"
    executor_host="unix:///var/run/docker.sock"
  fi
  pull_policy="$(gitlab_effective_pull_policy)"
  mkdir -p "$dir" "$dir/certs" || return 1
  chmod 700 "$dir" "$dir/certs" 2>/dev/null || true
  gitlab_ensure_system_id "$dir" || return 1
  gitlab_snapshot_ca "$dir" || return 1
  local vols=() m hostdir dest i
  mkdir -p "$CACHE_ROOT/gitlab-cache/$name" || return 1
  vols+=( "$socket_source:/var/run/docker.sock" "$CACHE_ROOT/gitlab-cache/$name:/cache" )
  # The helper image automatically installs a CA mounted at this documented
  # path. User-selected job images receive the file too, but must install or
  # explicitly use it themselves because their CA tooling is image-specific.
  [ -f "$slot_ca" ] \
    && vols+=( "$slot_ca:/etc/gitlab-runner/certs/ca.crt:ro" )
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] || continue
    hostdir="$(crf_safe_mount_subdir "${m%%:*}")" \
      || { err "refusing unsafe GitLab cache mount '${m%%:*}'"; return 1; }
    dest="$(gitlab_job_cache_destination "${m#*:}")"
    vols+=( "$hostdir:$dest" )
  done
  ( umask 077
    {
      echo 'concurrent = 1'
      echo 'check_interval = 0'
      printf 'shutdown_timeout = %s\n' "$GITLAB_SHUTDOWN_TIMEOUT"
      echo 'listen_address = "127.0.0.1:9252"'
      echo
      echo '[[runners]]'
      printf '  name = %s\n' "$(gitlab_toml_string "$(host)-$name")"
      printf '  url = %s\n' "$(gitlab_toml_string "$url")"
      printf '  token = %s\n' "$(gitlab_toml_string "$token")"
      echo '  executor = "docker"'
      echo '  limit = 1'
      echo '  request_concurrency = 1'
      echo '  environment = ["FF_NETWORK_PER_BUILD=1"]'
      [ -f "$slot_ca" ] && echo '  tls-ca-file = "/etc/gitlab-runner/certs/gitlab-ca.crt"'
      echo '  [runners.docker]'
      printf '    host = %s\n' "$(gitlab_toml_string "$executor_host")"
      echo '    tls_verify = false'
      printf '    image = %s\n' "$(gitlab_toml_string "$job_image")"
      printf '    pull_policy = %s\n' "$(gitlab_toml_string "$pull_policy")"
      printf '    allowed_pull_policies = [%s]\n' "$(gitlab_toml_string "$pull_policy")"
      [ -n "$GITLAB_ALLOWED_IMAGES" ] \
        && printf '    allowed_images = %s\n' "$(gitlab_toml_array "$GITLAB_ALLOWED_IMAGES")"
      [ -n "$GITLAB_ALLOWED_SERVICES" ] \
        && printf '    allowed_services = %s\n' "$(gitlab_toml_array "$GITLAB_ALLOWED_SERVICES")"
      echo '    privileged = false'
      echo '    disable_entrypoint_overwrite = false'
      echo '    oom_kill_disable = false'
      echo '    disable_cache = false'
      [ -n "$RUNNER_CPUS" ] && printf '    cpus = %s\n    service_cpus = %s\n' "$(gitlab_toml_string "$RUNNER_CPUS")" "$(gitlab_toml_string "$RUNNER_CPUS")"
      [ -n "$RUNNER_MEMORY" ] && printf '    memory = %s\n    service_memory = %s\n' "$(gitlab_toml_string "$RUNNER_MEMORY")" "$(gitlab_toml_string "$RUNNER_MEMORY")"
      printf '    shm_size = %s\n' "$GITLAB_SHM_SIZE"
      printf '    volumes = ['
      for ((i=0; i<${#vols[@]}; i++)); do
        [ "$i" -gt 0 ] && printf ', '
        printf '%s' "$(gitlab_toml_string "${vols[$i]}")"
      done
      echo ']'
      echo '    [runners.docker.container_labels]'
      echo '      "net.unraid.ci-runner-farm.provider" = "gitlab"'
      printf '      "net.unraid.ci-runner-farm.slot" = %s\n' "$(gitlab_toml_string "$name")"
    } > "$tmp"
  ) || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # A completed marker belongs to the manager represented by the previous live
  # config. Clear it before publishing a replacement, even when all visible
  # settings (and therefore the rendered TOML) happen to be identical.
  gitlab_clear_unregister_complete "$dir" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$dir/config.toml"
}

gitlab_build_manager_args() {
  local idx="$1"
  local name="${2:-${NAME_PREFIX}-${idx}}" dir sock sockdir socket_mount authdir slot_ca
  gitlab_validate_settings || return 1
  gitlab_token_ready || { err "no valid GitLab glrt- runner token configured"; return 1; }
  gitlab_write_config "$idx" "$name" || { err "could not write GitLab config for $name"; return 1; }
  gitlab_write_docker_auth "$name" || { err "could not write registry auth for $name"; return 1; }
  dir="$(gitlab_slot_config_dir "$name")"
  slot_ca="$dir/certs/gitlab-ca.crt"
  if [ "$DIND" = "true" ]; then
    sockdir="$(gitlab_socket_dir "$name")"
    sock="$sockdir/docker.sock"
    socket_mount="$sockdir:/runner-services"
  else
    sock="/var/run/docker.sock"
    socket_mount="/var/run/docker.sock:/var/run/docker.sock"
  fi
  ARGS=(
    -d --restart=no --name "$name" --hostname "$name" --pids-limit=2048
    --stop-signal SIGQUIT --stop-timeout "$GITLAB_SHUTDOWN_TIMEOUT"
    --label "${MANAGED_LABEL%=*}=true"
    --label "net.unraid.ci-runner-farm.provider=gitlab"
    --label "net.unraid.ci-runner-farm.role=manager"
    --label "net.unraid.ci-runner-farm.index=${idx}"
    --label "net.unraid.ci-runner-farm.confgen=$(crf_confgen)"
    --label "net.unraid.ci-runner-farm.socket=${sock}"
    # Local process liveness only. A GitLab/network/CA outage must not make a
    # healthy manager "unhealthy" and trigger destructive job reaping.
    --health-cmd 'wget -qO- http://127.0.0.1:9252/metrics >/dev/null 2>&1'
    --health-interval 30s --health-timeout 12s --health-retries 3 --health-start-period 30s
    -v "$dir:/etc/gitlab-runner"
    # Mount the directory in DinD mode, not the current socket inode. If the
    # independently restarting sidecar recreates docker.sock, the manager sees
    # the new file without needing its own container restart.
    -v "$socket_mount"
  )
  [ -f "$slot_ca" ] && ARGS+=( -v "$slot_ca:/etc/gitlab-runner/certs/gitlab-ca.crt:ro" )
  authdir="$dir/docker"
  if [ -f "$authdir/config.json" ]; then
    ARGS+=( -v "$authdir:/root/.docker:ro" -v "$authdir:/home/gitlab-runner/.docker:ro" )
  fi
  [ "$NETWORK_ISOLATION" != "off" ] && ARGS+=( --network "$RUNNER_NETWORK" )
  ARGS+=( "$GITLAB_RUNNER_IMAGE" )
}

gitlab_build_args() { gitlab_build_manager_args "$@"; }

gitlab_start_sidecar() {
  local idx="$1" name="$2" side sockdir sock data m hostdir registry_authority slot_ca
  side="$(gitlab_sidecar_name "$name")"
  if [ "$DIND" != "true" ]; then
    if docker inspect "$side" >/dev/null 2>&1; then
      gitlab_sidecar_owned "$side" \
        || { err "refusing to remove unowned container name collision: $side"; return 1; }
      docker rm -f "$side" >/dev/null 2>&1 || return 1
    fi
    return 0
  fi
  sockdir="$(gitlab_socket_dir "$name")"; sock="$sockdir/docker.sock"; data="$CACHE_ROOT/docker/$name"
  slot_ca="$(gitlab_slot_ca_file "$name")"
  if docker inspect "$side" >/dev/null 2>&1; then
    gitlab_sidecar_owned "$side" \
      || { err "refusing to replace unowned container name collision: $side"; return 1; }
    if docker ps --format '{{.Names}}' | grep -qx "$side" \
       && [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.confgen" }}' "$side" 2>/dev/null)" = "$(crf_confgen)" ] \
       && [ "$(docker inspect -f '{{.Config.Image}}' "$side" 2>/dev/null)" = "$GITLAB_DIND_IMAGE" ] \
       && on_expected_network "$side" \
       && docker --host "unix://$sock" info >/dev/null 2>&1; then return 0; fi
    local workloads
    if docker ps --format '{{.Names}}' | grep -qx "$side"; then
      if ! workloads="$(gitlab_running_executor_containers "$name")"; then
        err "refusing to replace $side because its running executor workload cannot be enumerated"
        return 1
      fi
      if [ -n "$workloads" ]; then
        err "refusing to replace $side while GitLab executor containers are still running"
        return 1
      fi
    fi
    docker stop -t 30 "$side" >/dev/null 2>&1 || true
    docker rm -f "$side" >/dev/null 2>&1 \
      || { err "could not replace stale GitLab sidecar $side"; return 1; }
  fi
  mkdir -p "$sockdir" "$data" "$CACHE_ROOT/dind-logs/$name" || return 1
  chmod 700 "$sockdir" 2>/dev/null || true
  rm -f "$sock" 2>/dev/null || true
  log "starting private GitLab Docker daemon $side"
  local sargs=(
    -d --restart=unless-stopped --name "$side" --hostname "$side" --privileged --pids-limit=4096
    --label "net.unraid.ci-runner-farm.sidecar=true"
    --label "net.unraid.ci-runner-farm.provider=gitlab"
    --label "net.unraid.ci-runner-farm.role=dind"
    --label "net.unraid.ci-runner-farm.index=${idx}"
    --label "net.unraid.ci-runner-farm.confgen=$(crf_confgen)"
    -e DOCKER_TLS_CERTDIR=
    -v "$data:/var/lib/docker"
    -v "$sockdir:/runner-services"
    -v "$CACHE_ROOT/dind-daemon.json:/etc/docker/daemon.json:ro"
    -v "$CACHE_ROOT/dind-logs/$name:/var/log/dind"
    # The nested daemon must see bind sources at the same absolute paths used
    # in config.toml. Expose only this slot's cache and explicitly configured
    # shared cache directories—never the whole CACHE_ROOT or sibling slots.
    -v "$CACHE_ROOT/gitlab-cache/$name:$CACHE_ROOT/gitlab-cache/$name"
  )
  if [ -f "$slot_ca" ]; then
    # The nested daemon resolves config.toml bind sources in its own mount
    # namespace, so mirror the host CA at the identical absolute path. Also
    # teach dockerd to trust that CA for the explicitly configured registry;
    # arbitrary image override registries remain operator-owned configuration.
    sargs+=( --mount "type=bind,src=$slot_ca,dst=$slot_ca,readonly" )
    registry_authority="$(gitlab_registry_authority 2>/dev/null || true)"
    [ -n "$registry_authority" ] \
      && sargs+=( --mount "type=bind,src=$slot_ca,dst=/etc/docker/certs.d/$registry_authority/ca.crt,readonly" )
  fi
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] || continue
    hostdir="$(crf_safe_mount_subdir "${m%%:*}")" || continue
    sargs+=( -v "$hostdir:$hostdir" )
  done
  [ -n "$RUNNER_CPUS" ]   && sargs+=( --cpus="$RUNNER_CPUS" )
  [ -n "$RUNNER_MEMORY" ] && sargs+=( --memory="$RUNNER_MEMORY" )
  [ "$NETWORK_ISOLATION" != "off" ] && sargs+=( --network "$RUNNER_NETWORK" )
  [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$NETWORK_ISOLATION" = "off" ] \
    && sargs+=( --add-host "host.docker.internal:host-gateway" )
  # docker:dind's stock entrypoint adds an unauthenticated TCP listener when
  # its first argument is an option. Pass `dockerd` explicitly so the entrypoint
  # retains PID cleanup/init/iptables setup without injecting any TCP listener.
  sargs+=( "$GITLAB_DIND_IMAGE" dockerd --host=unix:///runner-services/docker.sock )
  docker run "${sargs[@]}" >/dev/null || return 1
  local i
  for i in $(seq 1 60); do
    docker --host "unix://$sock" info >/dev/null 2>&1 && return 0
    sleep 1
  done
  err "$side did not expose a healthy Docker socket"
  docker logs --tail 40 "$side" >&2 2>/dev/null || true
  gitlab_remove_sidecar "$name" false >/dev/null 2>&1 || true
  return 1
}

gitlab_ensure_job_image() {
  local name="$1" image sock dir host_id nested_id policy
  image="$(effective_image)"
  if [ "$DIND" = "true" ]; then sock="$(gitlab_socket_dir "$name")/docker.sock"; else sock="/var/run/docker.sock"; fi
  policy="$(gitlab_effective_pull_policy)"
  if [ "$IMAGE_SOURCE" = "remote" ] && [ -n "$IMAGE" ]; then
    dir="$(gitlab_slot_config_dir "$name")/docker"
    case "$policy" in
      always) ;;
      if-not-present)
        docker --host "unix://$sock" image inspect "$image" >/dev/null 2>&1 && return 0 ;;
      *) err "unsupported effective GitLab pull policy: $policy"; return 1 ;;
    esac
    if [ -f "$dir/config.json" ]; then
      docker --config "$dir" --host "unix://$sock" pull "$image" >/dev/null
    else
      docker --host "unix://$sock" pull "$image" >/dev/null
    fi
  else
    docker image inspect "$image" >/dev/null 2>&1 || { err "built-in GitLab job image '$image' is unavailable — build it on the Runner image tab"; return 1; }
    host_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null)"
    nested_id="$(docker --host "unix://$sock" image inspect -f '{{.Id}}' "$image" 2>/dev/null)"
    if [ "$DIND" = "true" ]; then
      local load_builtin=false
      case "$GITLAB_PULL_POLICY" in
        # The upgrade-safe default keeps each private daemon synchronized with a
        # newly rebuilt local image. Explicit policies retain their ordinary
        # Docker meanings instead of overwriting an already cached image.
        auto) [ "$host_id" != "$nested_id" ] && load_builtin=true ;;
        always) load_builtin=true ;;
        if-not-present) [ -z "$nested_id" ] && load_builtin=true ;;
        *) err "unsupported GitLab pull policy: $GITLAB_PULL_POLICY"; return 1 ;;
      esac
      if [ "$load_builtin" = true ]; then
        log "loading built-in GitLab job image into $name's private Docker daemon"
        docker image save "$image" | docker --host "unix://$sock" image load >/dev/null || return 1
      fi
    fi
  fi
}

gitlab_unregister_manager() {
  local c="$1" dir image manager_name manager_network manager_networks network_count
  local runner_entries manager_names manager_tokens
  local identity marker tmpdir temp_config slot_ca ca_source="" unregister_ok=0
  docker inspect "$c" >/dev/null 2>&1 || return 0
  dir="$(gitlab_slot_config_dir "$c")"
  [ -s "$dir/config.toml" ] \
    || { log "warning: cannot unregister GitLab manager $c without its config.toml"; return 1; }
  runner_entries="$(grep -cE '^[[:space:]]*\[\[runners\]\][[:space:]]*$' "$dir/config.toml" 2>/dev/null || true)"
  manager_names="$(grep -cE '^[[:space:]]*name[[:space:]]*=' "$dir/config.toml" 2>/dev/null || true)"
  manager_tokens="$(grep -cE '^[[:space:]]*token[[:space:]]*=' "$dir/config.toml" 2>/dev/null || true)"
  [ "$runner_entries" = 1 ] && [ "$manager_names" = 1 ] && [ "$manager_tokens" = 1 ] \
    || { log "warning: refusing to unregister $c: config.toml must contain exactly one runner manager"; return 1; }
  # This farm supports only modern glrt- authentication tokens. That token form
  # makes `unregister` call GitLab's manager-only endpoint with this directory's
  # persisted system ID. Refuse older registration-created token forms because
  # their unregister path can delete the shared runner entity used by every slot.
  grep -qE '^[[:space:]]*token[[:space:]]*=[[:space:]]*"glrt-[A-Za-z0-9_.-]{10,507}"[[:space:]]*$' "$dir/config.toml" \
    || { log "warning: refusing to unregister $c: config.toml does not contain a modern glrt- manager token"; return 1; }
  # Select the one entry persisted for this slot. Read its saved name rather than
  # recomputing from the current hostname, which may have changed since creation.
  manager_name="$(sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"\([A-Za-z0-9_.-]*\)"[[:space:]]*$/\1/p' "$dir/config.toml" | head -1)"
  [ -n "$manager_name" ] \
    || { log "warning: refusing to unregister $c: config.toml has no safe manager name"; return 1; }
  [ -s "$dir/.runner_system_id" ] \
    && grep -qE '^[sr]_[0-9A-Za-z]{12}$' "$dir/.runner_system_id" 2>/dev/null \
    || { log "warning: refusing to unregister $c without its persisted system ID"; return 1; }
  # Retirement is called only after SIGQUIT has stopped the manager. Refusing a
  # direct unregister of a live process prevents it from accepting another job
  # between remote deletion and local container removal.
  if docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -qx true; then
    log "warning: refusing to unregister GitLab manager $c while it is still running"
    return 1
  fi

  identity="$(gitlab_unregister_identity "$dir")" \
    || { log "warning: could not fingerprint persisted GitLab manager $c"; return 1; }
  marker="$(gitlab_unregister_marker "$c")"
  if gitlab_unregister_is_complete "$dir" "$identity"; then
    log "GitLab manager $c was already unregistered remotely; retrying local cleanup"
    return 0
  fi

  image="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
  [ -n "$image" ] || image="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)"
  [ -n "$image" ] \
    || { log "warning: cannot resolve the image for stopped GitLab manager $c"; return 1; }
  gitlab_validate_manager_version "$image" unregister \
    || { log "warning: refusing to unregister $c through an unverified/pre-16 Runner image; upgrade the manager or use the confirmed local Force forget action"; return 1; }

  # Run the one-shot client in the stopped manager's actual network namespace
  # policy. In strict mode that subnet is the one covered by the retained
  # control-plane exception; the default bridge is equally explicit when
  # isolation was off. Refuse ambiguous/manual multi-network attachments.
  manager_networks="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$c" 2>/dev/null)" \
    || { log "warning: cannot resolve the Docker network for stopped GitLab manager $c"; return 1; }
  manager_networks="$(printf '%s\n' "$manager_networks" | sed '/^[[:space:]]*$/d')"
  network_count="$(printf '%s\n' "$manager_networks" | grep -c . || true)"
  [ "$network_count" = 1 ] \
    || { log "warning: refusing to unregister $c from an ambiguous or missing Docker network attachment"; return 1; }
  manager_network="$manager_networks"
  printf '%s' "$manager_network" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' \
    || { log "warning: refusing unsafe Docker network name while unregistering $c"; return 1; }
  docker network inspect "$manager_network" >/dev/null 2>&1 \
    || { log "warning: stopped GitLab manager $c network $manager_network no longer exists"; return 1; }

  # Never mount the live slot directory into `gitlab-runner unregister`: the
  # official command rewrites config.toml after a successful API call. Work on a
  # mode-restricted tmpfs copy so a later Docker-rm retry still has the exact old
  # URL/token/system-ID material and can use the completion marker above.
  tmpdir="$(mktemp -d "$RUNDIR/gitlab-unregister.XXXXXX" 2>/dev/null)" \
    || { log "warning: could not create secure unregister workspace for $c"; return 1; }
  chmod 700 "$tmpdir" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
  temp_config="$tmpdir/config.toml"
  if ! ( umask 077; cp "$dir/config.toml" "$temp_config" \
      && cp "$dir/.runner_system_id" "$tmpdir/.runner_system_id" ); then
    rm -rf "$tmpdir"
    log "warning: could not copy persisted manager identity for $c"
    return 1
  fi
  chmod 600 "$temp_config" "$tmpdir/.runner_system_id" 2>/dev/null \
    || { rm -rf "$tmpdir"; return 1; }

  # New slots always have an immutable per-slot snapshot. For legacy slots,
  # fall back narrowly to the currently configured global CA. If that old TOML
  # did not yet contain tls-ca-file, add it only to the disposable copy.
  slot_ca="$(gitlab_slot_ca_file "$c")"
  if [ -s "$slot_ca" ]; then
    ca_source="$slot_ca"
  elif [ -s "$GITLAB_CA_FILE" ]; then
    ca_source="$GITLAB_CA_FILE"
    log "warning: $c predates per-slot CA snapshots; using the current GitLab CA for unregister"
  fi
  if grep -qE '^[[:space:]]*tls-ca-file[[:space:]]*=' "$temp_config"; then
    if [ -z "$ca_source" ]; then
      rm -rf "$tmpdir"
      log "warning: cannot unregister $c: its persisted TLS CA is unavailable"
      return 1
    fi
  elif [ -n "$ca_source" ]; then
    if ! awk '
      !added && /^[[:space:]]*token[[:space:]]*=/ {
        print
        print "  tls-ca-file = \"/etc/gitlab-runner/certs/gitlab-ca.crt\""
        added=1
        next
      }
      { print }
      END { if (!added) exit 1 }
    ' "$temp_config" > "$temp_config.ca"; then
      rm -rf "$tmpdir"
      log "warning: could not add legacy CA trust to unregister copy for $c"
      return 1
    fi
    chmod 600 "$temp_config.ca" 2>/dev/null \
      && mv "$temp_config.ca" "$temp_config" \
      || { rm -rf "$tmpdir"; return 1; }
  fi
  if [ -n "$ca_source" ]; then
    mkdir -p "$tmpdir/certs" \
      && chmod 700 "$tmpdir/certs" 2>/dev/null \
      && ( umask 077; cp "$ca_source" "$tmpdir/certs/gitlab-ca.crt" ) \
      && chmod 600 "$tmpdir/certs/gitlab-ca.crt" 2>/dev/null \
      || { rm -rf "$tmpdir"; log "warning: could not stage TLS trust for unregistering $c"; return 1; }
  fi

  docker run --rm --network "$manager_network" -v "$tmpdir:/etc/gitlab-runner" "$image" \
    unregister --name "$manager_name" >/dev/null 2>&1 && unregister_ok=1
  rm -rf "$tmpdir"
  if [ "$unregister_ok" -ne 1 ]; then
    log "warning: could not unregister GitLab manager $c; its offline manager record may linger"
    return 1
  fi
  if ! gitlab_mark_unregister_complete "$dir" "$identity"; then
    log "warning: unregistered GitLab manager $c but could not persist local completion state"
    return 1
  fi
  chmod 600 "$marker" 2>/dev/null || true
  log "unregistered stopped GitLab manager $c"
}

# GitLab manager tokens are persistent, unlike GitHub's short-lived bootstrap
# registration token. On an ordinary Docker/array restart with an unchanged
# confgen, restart the same manager and system ID without remote unregister.
gitlab_start_stopped() {
  local c="$1" idx="$2" manager_id="${3:-}" current_id job side side_id i image dir
  printf '%s' "$manager_id" | grep -qE '^[0-9a-f]{64}$' \
    || { err "refusing to restart GitLab manager $c without a valid immutable container ID"; return 1; }
  dir="$(gitlab_slot_config_dir "$c")"
  # Once manager-only unregister succeeds, this exact local container must never
  # resume polling. Its completion marker exists specifically so a failed Docker
  # removal can retry local cleanup without contacting GitLab a second time.
  if [ -e "$dir/.remote-unregister-complete" ] \
     || [ -L "$dir/.remote-unregister-complete" ] \
     || [ -e "$dir/.remote-unregister-complete.tmp" ] \
     || [ -L "$dir/.remote-unregister-complete.tmp" ]; then
    err "refusing to restart remotely unregistered GitLab manager $c; retry Stop to finish local cleanup"
    return 1
  fi
  current_id="$(docker inspect -f '{{.Id}}' "$c" 2>/dev/null)" \
    || { err "could not revalidate stopped GitLab manager identity for $c"; return 1; }
  [ "$current_id" = "$manager_id" ] \
    || { err "refusing to restart GitLab manager $c because its container identity changed"; return 1; }
  # Validate the immutable image the stopped manager will actually execute. A
  # mutable configured tag may have advanced or disappeared during the outage.
  image="$(docker inspect -f '{{.Image}}' "$manager_id" 2>/dev/null)" \
    || { err "could not resolve stopped GitLab manager image for $c"; return 1; }
  [ -n "$image" ] \
    || { err "could not resolve stopped GitLab manager image for $c"; return 1; }
  gitlab_validate_manager_version "$image" runtime || return 1
  side="$(gitlab_sidecar_name "$c")"
  # A stopped manager can coexist with a surviving host-socket job or a live
  # private daemon. Prove that endpoint idle before any stale sidecar is
  # replaced. If an owned sidecar is stopped, starting that same immutable
  # object is non-destructive and lets us inspect its persisted daemon state.
  if [ "$DIND" = true ]; then
    if docker inspect "$side" >/dev/null 2>&1; then
      side_id="$(docker inspect -f '{{.Id}}' "$side" 2>/dev/null)" \
        || { err "could not resolve private Docker sidecar identity for $c"; return 1; }
      gitlab_sidecar_owned "$side_id" \
        || { err "refusing unowned sidecar name collision: $side"; return 1; }
      if ! docker ps --format '{{.Names}}' | grep -qx "$side"; then
        docker start "$side_id" >/dev/null \
          || { err "could not restart existing private Docker sidecar for $c"; return 1; }
      fi
      for i in $(seq 1 60); do
        docker --host "unix://$(gitlab_socket_dir "$c")/docker.sock" info >/dev/null 2>&1 && break
        sleep 1
      done
      docker --host "unix://$(gitlab_socket_dir "$c")/docker.sock" info >/dev/null 2>&1 \
        || { err "cannot prove the existing private Docker daemon for $c is idle"; return 1; }
      if ! job="$(gitlab_running_executor_containers "$c")"; then
        err "refusing to restart GitLab manager $c because its executor workload cannot be enumerated"
        return 1
      fi
    else
      # With no private-daemon container there cannot be a running nested
      # executor workload. start_sidecar can safely recreate the endpoint from
      # the persisted data root before the manager resumes polling.
      job=""
    fi
  elif ! job="$(gitlab_running_executor_containers "$c")"; then
    err "refusing to restart GitLab manager $c because its host executor workload cannot be enumerated"
    return 1
  fi
  if [ -n "$job" ]; then
    err "refusing to restart GitLab manager $c while surviving executor container ${job%%$'\n'*} is still active"
    return 1
  fi
  gitlab_start_sidecar "$idx" "$c" || return 1
  gitlab_ensure_job_image "$c" \
    || { err "could not prepare GitLab job image before restarting $c"; return 1; }
  docker start "$manager_id" >/dev/null \
    || { err "could not restart stopped GitLab manager $c"; return 1; }
}

gitlab_sidecar_owned() {
  [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.sidecar" }}' "$1" 2>/dev/null)" = true ] \
    && [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.provider" }}' "$1" 2>/dev/null)" = gitlab ] \
    && [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.role" }}' "$1" 2>/dev/null)" = dind ]
}

gitlab_manager_owned() {
  [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.managed" }}' "$1" 2>/dev/null)" = true ] \
    && [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.provider" }}' "$1" 2>/dev/null)" = gitlab ] \
    && [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.role" }}' "$1" 2>/dev/null)" = manager ]
}

gitlab_cleanup_orphan_sidecars() {
  local side slot provider side_id workloads failed=0
  for side in $(docker ps -a --filter 'label=net.unraid.ci-runner-farm.sidecar=true' --format '{{.Names}}' 2>/dev/null); do
    [ -n "$side" ] || continue
    gitlab_sidecar_owned "$side" || continue
    slot="${side%-dind}"
    provider="$(container_provider "$slot")"
    if ! docker inspect "$slot" >/dev/null 2>&1 || [ "$provider" != gitlab ]; then
      side_id="$(docker inspect -f '{{.Id}}' "$side" 2>/dev/null)" \
        || { err "could not resolve orphaned sidecar identity for $side"; failed=1; continue; }
      gitlab_sidecar_owned "$side_id" \
        || { err "refusing orphan cleanup after sidecar ownership changed: $side"; failed=1; continue; }
      if docker ps --format '{{.Names}}' | grep -qx "$side"; then
        if ! workloads="$(gitlab_running_executor_containers "$slot")"; then
          err "refusing to remove orphaned sidecar $side because its executor workload cannot be enumerated"
          failed=1
          continue
        fi
        if [ -n "$workloads" ]; then
          err "refusing to remove orphaned sidecar $side while GitLab executor containers are still running"
          failed=1
          continue
        fi
      fi
      log "removing orphaned privileged GitLab sidecar $side"
      docker stop -t 30 "$side_id" >/dev/null 2>&1 || true
      docker rm -f "$side_id" >/dev/null 2>&1 || failed=1
    fi
  done
  return "$failed"
}

gitlab_remove_sidecar() {
  local name="$1" purge="${2:-false}" side root
  case "$name" in
    "$NAME_PREFIX"-*) case "$name" in *[!A-Za-z0-9_.-]*) err "refusing unsafe GitLab slot name: $name"; return 1 ;; esac ;;
    *) err "refusing unexpected GitLab slot name: $name"; return 1 ;;
  esac
  side="$(gitlab_sidecar_name "$name")"
  if docker inspect "$side" >/dev/null 2>&1; then
    gitlab_sidecar_owned "$side" \
      || { err "refusing to remove unowned container name collision: $side"; return 1; }
    docker stop -t 30 "$side" >/dev/null 2>&1 || true
    docker rm -f "$side" >/dev/null 2>&1 || return 1
  fi
  if [ "$purge" = "true" ]; then
    root="$(crf_safe_cache_root)" || { err "refusing GitLab slot purge under unsafe CACHE_ROOT '$CACHE_ROOT'"; return 1; }
    rm -rf "$root/docker/$name" "$root/gitlab-sockets/$name" \
      "$root/gitlab-cache/$name" 2>/dev/null || return 1
  fi
}

gitlab_start_one() {
  local idx="$1" name="$2" residue_status snapshot residue_id residue_provider residue_role names
  docker image inspect "$GITLAB_RUNNER_IMAGE" >/dev/null 2>&1 \
    || host_docker_pull "$GITLAB_RUNNER_IMAGE" >/dev/null \
    || { err "could not pull GitLab Runner manager image $GITLAB_RUNNER_IMAGE"; return 1; }
  gitlab_validate_host_socket_manager_version || return 1
  # The verification transaction creates and removes a dedicated temporary
  # manager identity; actual slot credentials are not rendered until that
  # remote cleanup has succeeded.
  gitlab_verify_manager_token "$name" || return 1
  if ! gitlab_build_args "$idx" "$name"; then
    gitlab_scrub_retired_slot_credentials "$name" >/dev/null 2>&1 \
      || err "could not scrub unlaunched GitLab manager credentials for $name"
    err "GitLab manager $name not started (configuration error)"
    return 1
  fi
  if ! gitlab_start_sidecar "$idx" "$name"; then
    gitlab_scrub_retired_slot_credentials "$name" >/dev/null 2>&1 || true
    err "private Docker daemon for $name failed to start"
    return 1
  fi
  if ! gitlab_ensure_job_image "$name"; then
    gitlab_remove_sidecar "$name" false || true
    gitlab_scrub_retired_slot_credentials "$name" >/dev/null 2>&1 || true
    return 1
  fi
  log "starting GitLab manager $name (job cpus=$RUNNER_CPUS mem=$RUNNER_MEMORY url=$(gitlab_url))"
  if ! docker run "${ARGS[@]}" >/dev/null; then
    err "GitLab manager $name failed to start"
    if docker inspect "$name" >/dev/null 2>&1; then
      residue_status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
      if [ "$residue_status" = created ]; then
        snapshot="$(managed_runner_snapshot "$name" 2>/dev/null || true)"
        IFS='|' read -r residue_id residue_provider residue_role _ <<< "$snapshot"
        if printf '%s' "$residue_id" | grep -qE '^[0-9a-f]{64}$' \
           && [ "$residue_provider" = gitlab ] \
           && [ "$residue_role" = manager ] \
           && docker rm "$residue_id" >/dev/null 2>&1; then
          gitlab_remove_sidecar "$name" false || true
          gitlab_scrub_retired_slot_credentials "$name" >/dev/null 2>&1 || true
        else
          err "retaining unverified Created residue $name and its protected identity for safe operator cleanup"
        fi
      else
        err "retaining $name and its protected identity because it may have contacted GitLab before exiting"
      fi
    elif names="$(docker ps -a --format '{{.Names}}' 2>/dev/null)"; then
      if printf '%s\n' "$names" | grep -qxF "$name"; then
        err "retaining $name and its protected identity because Docker listed the name but its identity could not be inspected"
      else
        # A successful full-container enumeration is the only safe proof that
        # a failed `docker run` never left a manager that could have registered.
        gitlab_remove_sidecar "$name" false || true
        gitlab_scrub_retired_slot_credentials "$name" >/dev/null 2>&1 || true
      fi
    else
      err "retaining $name and its protected identity because Docker container state could not be enumerated"
    fi
    return 1
  fi
}

# Successful retirement no longer needs reusable credentials or the CA/token
# material that made manager-only unregister retryable. Scrub only after every
# remote and local lifecycle step has succeeded; any earlier failure deliberately
# leaves the complete slot identity intact. The stable system ID is non-secret and
# survives so a later manager for this farm slot reuses the same machine identity.
gitlab_scrub_retired_slot_credentials() {
  local name="$1" dir
  case "$name" in
    "$NAME_PREFIX"-*) case "$name" in *[!A-Za-z0-9_.-]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  dir="$(gitlab_slot_config_dir "$name")"
  rm -f \
    "$dir/config.toml" "$dir/config.toml.tmp" "$dir/config.toml.ca" \
    "$dir/docker/config.json" "$dir/docker/config.json.tmp" \
    "$dir/.remote-unregister-complete" "$dir/.remote-unregister-complete.tmp" \
    "$dir/certs/gitlab-ca.crt" "$dir/certs/gitlab-ca.crt.tmp" \
    "$dir/.runner_system_id.tmp" \
    || { err "could not scrub retired GitLab slot credentials for $name"; return 1; }
  rmdir "$dir/docker" "$dir/certs" 2>/dev/null || true
  log "scrubbed retired GitLab credentials for $name (system ID preserved)"
}

# Detect a slot whose Docker manager disappeared outside the normal retirement
# transaction while its reusable token/system-ID pair still exists. Silently
# deleting that pair would make exact manager-only unregister impossible and
# leave an offline machine attached to the shared GitLab runner. A completion
# marker proves the remote deletion already succeeded, in which case finishing
# the interrupted local scrub is safe and idempotent.
gitlab_assert_no_orphan_manager_configs() {
  local dir name identity failed=0
  # Verification can commit its disposable manager before an HTTP response is
  # lost. Complete that exact saved transaction before any provider lifecycle
  # continues, including a switch back to GitHub.
  gitlab_recover_pending_probe || return 1
  for dir in "$CFGDIR"/gitlab-runners/*; do
    [ -d "$dir" ] || continue
    [ -s "$dir/config.toml" ] || continue
    name="${dir##*/}"
    case "$name" in
      "$NAME_PREFIX"-[0-9]*) ;;
      *)
        err "refusing to discard unexpected GitLab manager config directory: $dir"
        failed=1
        continue
        ;;
    esac
    case "${name#"$NAME_PREFIX"-}" in
      ''|*[!0-9]*)
        err "refusing to discard unexpected GitLab manager config directory: $dir"
        failed=1
        continue
        ;;
    esac

    if docker inspect "$name" >/dev/null 2>&1; then
      gitlab_manager_owned "$name" \
        || { err "unowned container $name collides with retained GitLab manager credentials"; failed=1; }
      continue
    fi

    identity="$(gitlab_unregister_identity "$dir" 2>/dev/null || true)"
    if [ -n "$identity" ] && gitlab_unregister_is_complete "$dir" "$identity"; then
      gitlab_scrub_retired_slot_credentials "$name" || failed=1
      continue
    fi
    err "GitLab manager $name is missing but its unregister credentials remain; retry cleanup after restoring it, or explicitly Force forget local manager in the Fleet UI"
    failed=1
  done
  return "$failed"
}

gitlab_remove_runner() {
  local c="$1" purge="${2:-true}" failed=0 job
  # SIGQUIT stops accepting work and lets the current job finish. Only after the
  # manager exits do we remove this one manager identity remotely; the shared
  # runner entity and other slots remain intact.
  if provider_stop_container "$c"; then
    # A previously stopped manager may still have a live executor container.
    # SIGQUIT on a running manager normally waits for this to disappear; after
    # the stop completes, require that invariant before unregistering or taking
    # down the slot daemon. The separately confirmed force-forget action is the
    # only path allowed to interrupt such an orphaned workload deliberately.
    if ! job="$(gitlab_running_executor_containers "$c")"; then
      err "refusing to unregister GitLab manager $c because its executor workload cannot be enumerated"
      return 1
    fi
    if [ -n "$job" ]; then
      err "refusing to unregister GitLab manager $c while surviving executor container ${job%%$'\n'*} is still active"
      return 1
    fi
    # A transient API/CA/network failure must not discard the only persisted
    # config/system-ID pair that can retry exact manager removal. Keep the now-
    # stopped manager and sidecar intact; provider switch/recycle/Stop reports
    # failure and can be retried without orphaning a remote manager record.
    gitlab_unregister_manager "$c" || return 1
  elif docker inspect "$c" >/dev/null 2>&1; then
    # Never tear down the daemon/jobs underneath a manager that failed to stop.
    return 1
  else
    log "warning: $c disappeared before its GitLab manager identity could be unregistered"
    failed=1
  fi
  provider_remove_container "$c" || failed=1
  gitlab_remove_host_jobs "$c" || failed=1
  gitlab_remove_sidecar "$c" "$purge" || failed=1
  [ "$failed" -eq 0 ] || return 1
  gitlab_scrub_retired_slot_credentials "$c"
}

# Break-glass local cleanup after the normal manager-only unregister path has
# repeatedly failed. This deliberately never contacts GitLab: the operator must
# remove any lingering offline manager in GitLab's UI. Keep the stable system ID
# so a partially completed cleanup is retryable and diagnostics retain the one
# non-secret piece of remote identity.
gitlab_force_forget_local() {
  local c="$1" suffix dir side manager_id="" side_id="" failed=0 root
  case "$c" in
    "$NAME_PREFIX"-*) suffix="${c#"$NAME_PREFIX"-}" ;;
    *) err "refusing unexpected GitLab slot name: $c"; return 1 ;;
  esac
  case "$suffix" in ''|*[!0-9]*) err "refusing unsafe GitLab slot name: $c"; return 1 ;; esac

  side="$(gitlab_sidecar_name "$c")"
  if docker inspect "$c" >/dev/null 2>&1; then
    manager_id="$(docker inspect -f '{{.Id}}' "$c" 2>/dev/null)" \
      || { err "could not resolve GitLab manager identity for $c"; return 1; }
    gitlab_manager_owned "$manager_id" \
      || { err "refusing to force-forget unowned manager name collision: $c"; return 1; }
  fi
  if docker inspect "$side" >/dev/null 2>&1; then
    side_id="$(docker inspect -f '{{.Id}}' "$side" 2>/dev/null)" \
      || { err "could not resolve GitLab sidecar identity for $side"; return 1; }
    gitlab_sidecar_owned "$side_id" \
      || { err "refusing to force-forget unowned sidecar name collision: $side"; return 1; }
  fi

  # Stop new work first, then remove every plugin-labelled build/helper/service
  # container for this slot before taking down its private daemon.
  if [ -n "$manager_id" ]; then
    docker rm -f "$manager_id" >/dev/null 2>&1 \
      || { err "could not force-remove GitLab manager $c"; return 1; }
  fi
  gitlab_remove_host_jobs "$c" || failed=1
  if [ -n "$side_id" ]; then
    docker rm -f "$side_id" >/dev/null 2>&1 || failed=1
  fi
  [ "$failed" -eq 0 ] \
    || { err "local force-forget cleanup for $c is incomplete; retry the action"; return 1; }

  root="$(crf_safe_cache_root)" \
    || { err "refusing force-forget cache cleanup under unsafe CACHE_ROOT '$CACHE_ROOT'"; return 1; }
  rm -rf "$root/docker/$c" "$root/gitlab-sockets/$c" "$root/gitlab-cache/$c" \
    || { err "could not purge local Docker/cache state for $c; retry the action"; return 1; }

  dir="$(gitlab_slot_config_dir "$c")"
  rm -f \
    "$dir/config.toml" "$dir/config.toml.tmp" "$dir/config.toml.ca" \
    "$dir/docker/config.json" "$dir/docker/config.json.tmp" \
    "$dir/.remote-unregister-complete" "$dir/.remote-unregister-complete.tmp" \
    "$dir/certs/gitlab-ca.crt" "$dir/certs/gitlab-ca.crt.tmp" \
    "$dir/.runner_system_id.tmp" \
    || { err "could not scrub local GitLab credentials for $c; retry the action"; return 1; }
  log "WARNING: force-forgot local GitLab slot $c without unregistering it; its remote manager may remain in GitLab"
}

# Side-effect-free break-glass preflight. The common engine calls this before it
# stops fleet-wide workers so a stale UI request or fixed-name collision cannot
# perturb healthy capacity. The destructive function repeats the ownership
# checks and binds removals to immutable IDs to close the race after preflight.
gitlab_force_forget_target_ready() {
  local name="$1" suffix dir side manager_id side_id seen=0
  case "$name" in "$NAME_PREFIX"-[0-9]*) suffix="${name#"$NAME_PREFIX"-}" ;; *) return 1 ;; esac
  case "$suffix" in ''|*[!0-9]*) return 1 ;; esac
  dir="$(gitlab_slot_config_dir "$name")"; side="$(gitlab_sidecar_name "$name")"
  if docker inspect "$name" >/dev/null 2>&1; then
    manager_id="$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null)" || return 1
    gitlab_manager_owned "$manager_id" \
      || { err "refusing to force-forget unowned manager name collision: $name"; return 1; }
    seen=1
  fi
  if docker inspect "$side" >/dev/null 2>&1; then
    side_id="$(docker inspect -f '{{.Id}}' "$side" 2>/dev/null)" || return 1
    gitlab_sidecar_owned "$side_id" \
      || { err "refusing to force-forget unowned sidecar name collision: $side"; return 1; }
    seen=1
  fi
  [ -s "$dir/config.toml" ] && seen=1
  [ -s "$dir/.remote-unregister-complete" ] && seen=1
  [ -s "$dir/.runner_system_id" ] \
    && grep -qE '^[sr]_[0-9A-Za-z]{12}$' "$dir/.runner_system_id" 2>/dev/null \
    || { err "refusing local forget without the slot's persisted GitLab system ID"; return 1; }
  [ "$seen" -eq 1 ] \
    || { err "no retryable local GitLab manager identity exists for $name"; return 1; }
}

gitlab_stop_cleanup() { gitlab_remove_host_jobs; }

gitlab_imageupdate_pull() {
  local changed=1 before after
  before="$(image_id "$GITLAB_RUNNER_IMAGE")"
  host_docker_pull "$GITLAB_RUNNER_IMAGE" >/dev/null 2>&1
  after="$(image_id "$GITLAB_RUNNER_IMAGE")"
  if [ -n "$after" ] && [ "$before" != "$after" ]; then
    changed=0; log "image-update: GitLab manager $GITLAB_RUNNER_IMAGE ${before:-none} -> $after"
  fi
  if [ "$DIND" = true ]; then
    before="$(image_id "$GITLAB_DIND_IMAGE")"
    host_docker_pull "$GITLAB_DIND_IMAGE" >/dev/null 2>&1
    after="$(image_id "$GITLAB_DIND_IMAGE")"
    if [ -n "$after" ] && [ "$before" != "$after" ]; then
      changed=0; log "image-update: GitLab DinD $GITLAB_DIND_IMAGE ${before:-none} -> $after"
    fi
  fi
  return "$changed"
}

gitlab_queued_refresh() {
  [ -z "$GITLAB_API_TOKEN" ] && [ -f "$GITLAB_API_TOKEN_FILE" ] && GITLAB_API_TOKEN="$(cat "$GITLAB_API_TOKEN_FILE" 2>/dev/null || true)"
  if ! gitlab_api_token_ready || [ -z "$GITLAB_PROJECTS" ]; then
    echo "gitlab $(date +%s) -1" > "$RUNDIR/queued.cache"; return 0
  fi
  local total=0 got=0 failed=0 project encoded tmpd body headers n
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "gitlab $(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    encoded="$(urlencode "$project")"; body="$tmpd/body"; headers="$tmpd/headers"
    : > "$body"; : > "$headers"
    if gitlab_api_capture "/projects/$encoded/jobs?scope%5B%5D=pending&per_page=1" "$body" "$headers"; then
      got=1
      n="$(awk -F': *' 'tolower($1)=="x-total" {gsub(/\r/,"",$2); print $2; exit}' "$headers")"
      case "$n" in ''|*[!0-9]*) grep -qE '^\[[[:space:]]*\]$' "$body" && n=0 || n=1 ;; esac
      total=$((total + ${n:-0}))
    else
      failed=1
    fi
  done <<< "$(gitlab_projects_list)"
  rm -rf "$tmpd"
  [ "$got" = 1 ] && [ "$failed" = 0 ] || total=-1
  echo "gitlab $(date +%s) $total" > "$RUNDIR/queued.cache"
}

gitlab_stats_refresh() {
  [ -z "$GITLAB_API_TOKEN" ] && [ -f "$GITLAB_API_TOKEN_FILE" ] && GITLAB_API_TOKEN="$(cat "$GITLAB_API_TOKEN_FILE" 2>/dev/null || true)"
  if ! gitlab_api_token_ready || [ -z "$GITLAB_PROJECTS" ]; then
    echo "gitlab $(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0
  fi
  local ok=0 fail=0 cancel=0 other=0 total got=0 failed=0 project encoded body status
  # Read the project list on fd 3: the per-project status scan below is itself a
  # `while read` and would otherwise share this loop's stdin.
  while IFS= read -r project <&3; do
    [ -n "$project" ] || continue
    encoded="$(urlencode "$project")"
    if body="$(gitlab_api GET "/projects/$encoded/jobs?per_page=50&order_by=id&sort=desc")"; then
      got=1
      while IFS= read -r status; do
        case "$status" in
          success) ok=$((ok+1)) ;;
          failed) fail=$((fail+1)) ;;
          canceled) cancel=$((cancel+1)) ;;
          running|pending|created|preparing|waiting_for_resource|waiting_for_callback|canceling|manual|scheduled) : ;;
          ?*) other=$((other+1)) ;;
        esac
      # Split only API array peers, then anchor at each top-level job object.
      # Unanchored id/status matching also counts nested pipeline/runner status
      # fields and can triple the dashboard totals.
      done <<< "$(printf '%s' "$body" | tr -d '\r\n' | sed 's/},{/}\
{/g' \
        | grep -oE '^\[?\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*"status"[[:space:]]*:[[:space:]]*"[a-z_]+"' \
        | sed 's/.*"\([a-z_]*\)"$/\1/')"
    else
      failed=1
    fi
  done 3<<< "$(gitlab_projects_list)"
  if [ "$got" = 1 ] && [ "$failed" = 0 ]; then total=$((ok+fail+cancel+other)); else total=-1; fi
  echo "gitlab $(date +%s) $ok $fail $cancel $other $total" > "$RUNDIR/stats.cache"
}

gitlab_usage_stat_target() {
  local c="$1"
  [ "$(gitlab_socket_path "$c")" = /var/run/docker.sock ] && echo _ || gitlab_sidecar_name "$c"
}

gitlab_status_resources() {
  local c="$1" inspraw="$2" side_row side_state side_cpus side_mem
  side_row="$(printf '%s\n' "$inspraw" | grep -m1 -E "^/?$(gitlab_sidecar_name "$c")\|")"
  if [ -n "$side_row" ]; then
    IFS='|' read -r _ side_state side_cpus side_mem _ _ <<< "$side_row"
    cpus="$side_cpus"; mem="$side_mem"
  else
    [ -n "$RUNNER_CPUS" ] && cpus="$(awk -v n="$RUNNER_CPUS" 'BEGIN{printf "%.0f", n*1000000000}')"
    [ -n "$RUNNER_MEMORY" ] && mem="$(memory_limit_bytes "$RUNNER_MEMORY")"
  fi
}

gitlab_usage_context() {
  local c="$1" jcid jsock jmeta jenv project_from_url
  jcid="$(gitlab_job_container "$c")"; jsock="$(gitlab_socket_path "$c")"
  if [ -n "$jcid" ]; then
    jmeta="$(docker --host "unix://$jsock" inspect -f '{{index .Config.Labels "com.gitlab.gitlab-runner.job.id"}}{{println}}{{index .Config.Labels "com.gitlab.gitlab-runner.job.url"}}{{println}}{{index .Config.Labels "com.gitlab.gitlab-runner.job.ref"}}{{println}}{{.State.StartedAt}}' "$jcid" 2>/dev/null)"
    job_id="$(printf '%s\n' "$jmeta" | sed -n '1p' | grep -oE '^[0-9]+$' | head -1)"; job_id="${job_id:-_}"
    job_url="$(printf '%s\n' "$jmeta" | sed -n '2p')"
    ref="$(printf '%s\n' "$jmeta" | sed -n '3p')"
    jstarted="$(printf '%s\n' "$jmeta" | sed -n '4p' | grep -oE '^[0-9T:.Z+-]+' | head -1)"; jstarted="${jstarted:-_}"
    jenv="$(docker --host "unix://$jsock" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$jcid" 2>/dev/null \
      | grep -E '^CI_(JOB_NAME|PROJECT_PATH)=')"
    job="$(printf '%s\n' "$jenv" | grep '^CI_JOB_NAME=' | head -1 | cut -d= -f2-)"
    project="$(printf '%s\n' "$jenv" | grep '^CI_PROJECT_PATH=' | head -1 | cut -d= -f2-)"
    if [ -z "$project" ] && [ -n "$job_url" ]; then
      project_from_url="${job_url#$(gitlab_url)/}"
      project="${project_from_url%/-/jobs/*}"
    fi
    [ -z "$job" ] && [ "$job_id" != _ ] && job="GitLab job #$job_id"
    [ -n "$project" ] && [ -n "$ref" ] && ref_url="$(gitlab_url)/$project/-/tree/$(urlencode "$ref")"
  fi
}

# `gitlab-runner list` is the parse/schema fallback for official images that do
# not expose a lint command.  A zero exit code is insufficient: Runner has
# historically reported schema problems as diagnostics while still listing the
# file.  Also require the exact generated manager and Docker executor so an empty
# or silently skipped config cannot pass validation.
gitlab_list_output_valid() {
  local expected_name="$1" output="$2" plain
  # The official image colorizes key/value fields even without a TTY. Remove
  # only ANSI SGR sequences before matching diagnostics and Executor=docker.
  plain="$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')"
  if grep -Eiq \
    "jsonschema:|there might be a problem with your config|created missing unique system id|couldn.t save new system id|(^|[[:space:]])(FATAL|ERROR|PANIC)(:|[[:space:]])|failed to (load|decode|parse)|warning:.*(config|schema|unknown|unsupported|invalid)" \
    <<< "$plain"; then
    return 1
  fi
  grep -Fq -- "$expected_name" <<< "$plain" || return 1
  grep -Eq 'Executor[[:space:]]*=[[:space:]]*docker([[:space:]]|$)' <<< "$plain"
}

gitlab_validate() {
  gitlab_validate_settings || return 1
  docker image inspect "$GITLAB_RUNNER_IMAGE" >/dev/null 2>&1 \
    || host_docker_pull "$GITLAB_RUNNER_IMAGE" >/dev/null \
    || { err "validate: cannot pull GitLab manager image $GITLAB_RUNNER_IMAGE"; return 1; }
  gitlab_validate_host_socket_manager_version || return 1
  local existing_managed
  existing_managed="$(managed_names)" \
    || { err "validate: could not enumerate the managed fleet"; return 1; }
  if [ -n "$existing_managed" ]; then
    # Validation may run before recycling one member of a live mixed fleet. Add
    # current endpoints/rules without clearing the policy that still protects
    # busy managers on the previous provider configuration.
    provision_base || return 1
    firewall_prepare_replacement || return 1
  else
    provision_preflight || return 1
  fi
  local suffix name idx=99 dir sock image side manager_ca=() job_args=() slot_ca validation_cfgroot
  suffix="$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  printf '%s' "$suffix" | grep -qE '^[a-f0-9]{12}$' \
    || { err "validate: could not allocate a unique validation name"; return 1; }
  name="${NAME_PREFIX}-validate-$suffix"
  side="$(gitlab_sidecar_name "$name")"
  if docker inspect "$name" >/dev/null 2>&1 \
     || docker inspect "${name}-job" >/dev/null 2>&1; then
    err "validate: refusing unexpected random-name container collision for $name"
    return 1
  fi
  if docker inspect "$side" >/dev/null 2>&1; then
    gitlab_sidecar_owned "$side" \
      || { err "validate: refusing unowned container name collision: $side"; return 1; }
    gitlab_remove_sidecar "$name" false || return 1
  fi
  image="$(effective_image)"
  if [ "$IMAGE_SOURCE" = remote ]; then
    if gitlab_remote_image_host_pull_required; then
      gitlab_prepare_remote_image "$image" >/dev/null 2>&1 \
        || { err "validate: cannot prepare job image $image under the selected pull policy"; return 1; }
    fi
  else
    docker image inspect "$image" >/dev/null 2>&1 || { err "validate: built-in GitLab job image $image is unavailable"; return 1; }
  fi
  validation_cfgroot="$(mktemp -d "$RUNDIR/gitlab-validate-config.XXXXXX" 2>/dev/null)" \
    || { err "validate: could not create a temporary manager-config directory"; return 1; }
  chmod 700 "$validation_cfgroot" 2>/dev/null \
    || { rm -rf -- "$validation_cfgroot"; return 1; }
  # Dynamic scope redirects gitlab_slot_config_dir and every called adapter
  # helper to tmpfs. Validate must never write its dummy token/system ID to the
  # persistent flash configuration tree, even if the process is interrupted.
  local CFGDIR="$validation_cfgroot"
  local GITLAB_RUNNER_TOKEN="glrt-validationtoken000000000000"
  gitlab_write_config "$idx" "$name" \
    || { err "validate: could not render GitLab config.toml"; rm -rf -- "$validation_cfgroot"; return 1; }
  gitlab_write_docker_auth "$name" \
    || { err "validate: could not render registry auth"; rm -rf -- "$validation_cfgroot"; return 1; }
  dir="$(gitlab_slot_config_dir "$name")"
  slot_ca="$dir/certs/gitlab-ca.crt"
  [ -f "$slot_ca" ] && manager_ca=( -v "$slot_ca:/etc/gitlab-runner/certs/gitlab-ca.crt:ro" )
  if docker run --rm "$GITLAB_RUNNER_IMAGE" --help 2>&1 | grep -qE '(^|[[:space:]])lint([[:space:]]|$)'; then
    if ! docker run --rm -v "$dir:/etc/gitlab-runner" ${manager_ca[@]+"${manager_ca[@]}"} "$GITLAB_RUNNER_IMAGE" \
        lint --config /etc/gitlab-runner/config.toml >/dev/null 2>&1; then
      err "validate: gitlab-runner lint rejected the generated config.toml"
      rm -rf -- "$validation_cfgroot" 2>/dev/null || true
      return 1
    fi
  else
    # Current official images may not expose `lint`. `list` still runs the same
    # TOML decoder; inspect its diagnostics as well as its exit status because
    # some schema/config warnings historically returned zero.
    local list_output list_rc=0 expected_name
    expected_name="$(host)-$name"
    list_output="$(docker run --rm -v "$dir:/etc/gitlab-runner" ${manager_ca[@]+"${manager_ca[@]}"} \
      "$GITLAB_RUNNER_IMAGE" list 2>&1)" || list_rc=$?
    if [ "$list_rc" -ne 0 ] || ! gitlab_list_output_valid "$expected_name" "$list_output"; then
      err "validate: the official GitLab Runner image rejected, warned about, or did not list the generated Docker runner config.toml"
      rm -rf -- "$validation_cfgroot" 2>/dev/null || true
      return 1
    fi
  fi
  gitlab_start_sidecar "$idx" "$name" || { rm -rf -- "$validation_cfgroot" 2>/dev/null || true; return 1; }
  gitlab_ensure_job_image "$name" || { gitlab_remove_sidecar "$name" true; rm -rf -- "$validation_cfgroot" 2>/dev/null || true; return 1; }
  [ "$DIND" = true ] && sock="$(gitlab_socket_dir "$name")/docker.sock" || sock="/var/run/docker.sock"
  job_args=( --host "unix://$sock" run --rm --name "${name}-job" --pids-limit=2048
    --label "net.unraid.ci-runner-farm.provider=gitlab"
    --label "net.unraid.ci-runner-farm.slot=$name"
    --label "net.unraid.ci-runner-farm.role=validate-job" )
  [ -n "$RUNNER_CPUS" ] && job_args+=( --cpus="$RUNNER_CPUS" )
  [ -n "$RUNNER_MEMORY" ] && job_args+=( --memory="$RUNNER_MEMORY" )
  job_args+=( -v "$CACHE_ROOT/gitlab-cache/$name:/cache" "$image" /bin/sh -c 'test -d /cache && printf "GitLab Docker-executor job image OK\n"' )
  log "validate: parsing generated GitLab TOML and launching an inert Docker-executor job container..."
  if ! docker "${job_args[@]}"; then
    err "validate: the GitLab job image could not run through the selected Docker endpoint"
    gitlab_remove_sidecar "$name" true; rm -rf -- "$validation_cfgroot" 2>/dev/null || true
    return 1
  fi
  gitlab_remove_sidecar "$name" true \
    || { err "validate: could not remove the temporary GitLab sidecar/data"; rm -rf -- "$validation_cfgroot" 2>/dev/null || true; return 1; }
  rm -rf -- "$validation_cfgroot" "$CACHE_ROOT/gitlab-cache/$name" 2>/dev/null || true
  log "validate: OK (generated config parsed; temporary manager data, DinD daemon, and job container removed)."
}
