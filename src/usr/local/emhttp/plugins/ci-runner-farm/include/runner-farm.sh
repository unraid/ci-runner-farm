#!/bin/bash
###############################################################################
# CI Runner Farm - manage GitHub Actions self-hosted BUILD runners as Docker
# containers on Unraid. Multiple concurrent runners, container-only (no VM),
# warm shared caches on a fast pool, resource-capped so builds coexist with
# the host and the other workloads.
#
# Subcommands:
#   start            provision RUNNER_COUNT runner containers
#   stop             stop+remove all managed runner containers
#   restart          stop then start
#   scale <N>        grow/shrink the fleet to N runners
#   status           human-readable fleet table
#   status-json      machine-readable status for the web UI
#   logs <i>         tail logs for runner i
#   validate         dry-provision one container (no GitHub token needed) to
#                    prove mounts/limits/image on this box, then remove it
#   prune-cache      clear the shared cache root
###############################################################################
set -uo pipefail

PLUGIN="ci-runner-farm"
CFGDIR="/boot/config/plugins/${PLUGIN}"
CFG="${CFGDIR}/config.cfg"
TOKEN_FILE="${CFGDIR}/token"
MANAGED_LABEL="net.unraid.ci-runner-farm.managed=true"
NAME_PREFIX="ci-runner"

# ---- defaults (overridden by config.cfg) -----------------------------------
GH_SCOPE="repo"                       # repo | org
GH_OWNER="unraid"
GH_REPOS="unraid/repo-a unraid/repo-b"
RUNNER_GROUP=""
RUNNER_COUNT=4
RUNNER_LABELS="self-hosted,unraid,build"
RUNNER_CPUS=""                        # per-runner CPU cap; empty = uncapped (CFS time-shares fairly)
RUNNER_MEMORY="16g"                   # per-runner memory cap (kept: memory isn't time-shared like CPU)
CACHE_ROOT="/mnt/github-runner"
WORK_TMPFS_SIZE="8g"                  # empty => bind workdir to pool instead of RAM
IMAGE="ci-runner-farm-runner:latest"
EPHEMERAL="false"                     # true => runner deregisters after each job
ACCESS_TOKEN=""                       # GitHub PAT (repo scope; +admin:org for org)
SHARE_DOCKER_SOCK="true"              # mount host docker.sock for service containers
# ----------------------------------------------------------------------------

[ -f "$CFG" ] && . "$CFG"
[ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"

log()  { echo "[ci-runner-farm] $*"; }
err()  { echo "[ci-runner-farm] ERROR: $*" >&2; }
host() { hostname -s; }

managed_names() {
  docker ps -a --filter "label=${MANAGED_LABEL}" --format '{{.Names}}' | sort -V
}

repo_for_index() {
  # round-robin assign a target repo to runner index (repo scope, multi-repo)
  local idx="$1"; local arr=($GH_REPOS); local n=${#arr[@]}
  [ "$n" -eq 0 ] && { echo ""; return; }
  echo "${arr[$(( (idx-1) % n ))]}"
}

ensure_dirs() {
  mkdir -p "$CACHE_ROOT/pnpm-store" "$CACHE_ROOT/npm" "$CACHE_ROOT/yarn" "$CACHE_ROOT/ms-playwright" "$CACHE_ROOT/work"
}

# build the docker run argv for one runner. $1=index, $2=name-override(optional)
build_args() {
  local idx="$1"; local name="${2:-${NAME_PREFIX}-${idx}}"
  ARGS=(
    -d --restart=unless-stopped
    --name "$name" --hostname "$name"
    --pids-limit=4096
    --label "${MANAGED_LABEL%=*}=true"
    --label "net.unraid.ci-runner-farm.index=${idx}"
    -e RUNNER_NAME="$(host)-${name}"
    -e LABELS="$RUNNER_LABELS"
    -e EPHEMERAL="$EPHEMERAL"
    -e DISABLE_AUTO_UPDATE="true"
    -e RUNNER_ALLOW_RUNASROOT="1"
    -e RUNNER_WORKDIR="/_work"
    -e npm_config_cache="/root/.npm"
    -v "$CACHE_ROOT/pnpm-store:/root/.local/share/pnpm/store"
    -v "$CACHE_ROOT/npm:/root/.npm"
    -v "$CACHE_ROOT/yarn:/usr/local/share/.cache/yarn"
    -v "$CACHE_ROOT/ms-playwright:/root/.cache/ms-playwright"
  )
  [ -n "$RUNNER_CPUS" ]   && ARGS+=( --cpus="$RUNNER_CPUS" )
  [ -n "$RUNNER_MEMORY" ] && ARGS+=( --memory="$RUNNER_MEMORY" )
  [ -n "$ACCESS_TOKEN" ] && ARGS+=( -e ACCESS_TOKEN="$ACCESS_TOKEN" )
  [ "$SHARE_DOCKER_SOCK" = "true" ] && ARGS+=( -v /var/run/docker.sock:/var/run/docker.sock )
  if [ -n "$WORK_TMPFS_SIZE" ]; then
    ARGS+=( --tmpfs "/_work:rw,exec,size=${WORK_TMPFS_SIZE}" )
  else
    mkdir -p "$CACHE_ROOT/work/$name"
    ARGS+=( -v "$CACHE_ROOT/work/$name:/_work" )
  fi
  if [ "$GH_SCOPE" = "org" ]; then
    ARGS+=( -e RUNNER_SCOPE="org" -e ORG_NAME="$GH_OWNER" )
    [ -n "$RUNNER_GROUP" ] && ARGS+=( -e RUNNER_GROUP="$RUNNER_GROUP" )
  else
    local repo; repo="$(repo_for_index "$idx")"
    ARGS+=( -e RUNNER_SCOPE="repo" -e REPO_URL="https://github.com/${repo}" )
  fi
  ARGS+=( "$IMAGE" )
}

start_one() {
  local idx="$1"; local name="${NAME_PREFIX}-${idx}"
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    log "runner $name already exists; skipping"; return 0
  fi
  build_args "$idx"
  log "starting $name (cpus=$RUNNER_CPUS mem=$RUNNER_MEMORY scope=$GH_SCOPE)"
  docker run "${ARGS[@]}" >/dev/null
}

cmd_start() {
  [ -z "$ACCESS_TOKEN" ] && { err "no GitHub token configured (set it in the web UI). Use 'validate' to test provisioning without one."; return 1; }
  ensure_dirs
  local i
  for i in $(seq 1 "$RUNNER_COUNT"); do start_one "$i"; done
  log "fleet up: $(managed_names | wc -l) runner(s)"
}

cmd_stop() {
  local names; names="$(managed_names)"
  [ -z "$names" ] && { log "no managed runners running"; return 0; }
  echo "$names" | while read -r c; do [ -n "$c" ] && { log "stopping $c (graceful deregister)"; docker stop -t 30 "$c" >/dev/null 2>&1; docker rm "$c" >/dev/null 2>&1; }; done
}

cmd_scale() {
  local target="$1"; ensure_dirs
  local current; current="$(managed_names | wc -l)"
  if [ "$target" -gt "$current" ]; then
    [ -z "$ACCESS_TOKEN" ] && { err "no token configured"; return 1; }
    local i
    for i in $(seq 1 "$target"); do
      docker ps -a --format '{{.Names}}' | grep -qx "${NAME_PREFIX}-${i}" || start_one "$i"
    done
  elif [ "$target" -lt "$current" ]; then
    local i
    for i in $(seq "$current" -1 $((target+1)) ); do
      docker stop -t 30 "${NAME_PREFIX}-${i}" >/dev/null 2>&1; docker rm "${NAME_PREFIX}-${i}" >/dev/null 2>&1 && log "removed ${NAME_PREFIX}-${i}"
    done
  fi
  log "scaled to $(managed_names | wc -l) runner(s)"
}

runner_phase() {
  # crude busy/idle heuristic from the last meaningful log line
  local c="$1" line
  line="$(docker logs --tail 25 "$c" 2>&1 | grep -iE 'Running job|Listening for Jobs|Job .* completed|Configuration|error' | tail -1)"
  case "$line" in
    *"Running job"*)        echo "busy" ;;
    *"Listening for Jobs"*) echo "idle" ;;
    *"completed"*)          echo "idle" ;;
    *[Ee]rror*)             echo "error" ;;
    *)                      echo "starting" ;;
  esac
}

cmd_status() {
  local names; names="$(managed_names)"
  printf "%-22s %-10s %-8s %-10s %s\n" "NAME" "STATE" "PHASE" "CPU/MEM" "IMAGE"
  [ -z "$names" ] && { echo "(no managed runners)"; return 0; }
  echo "$names" | while read -r c; do
    [ -z "$c" ] && continue
    local st; st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    local cpus mem; cpus="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$c" 2>/dev/null)"
    mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$c" 2>/dev/null)"
    printf "%-22s %-10s %-8s %-10s %s\n" "$c" "$st" "$(runner_phase "$c")" "$((cpus/1000000000))c/$((mem/1024/1024/1024))g" "$IMAGE"
  done
}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

cmd_status_json() {
  local names; names="$(managed_names)"
  local out="["; local first=1
  for c in $names; do
    [ -z "$c" ] && continue
    local st cpus mem phase
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    cpus="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$c" 2>/dev/null)"
    mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$c" 2>/dev/null)"
    phase="$(runner_phase "$c")"
    [ $first -eq 0 ] && out+=","
    out+="{\"name\":\"$(echo "$c"|json_escape)\",\"state\":\"${st:-unknown}\",\"phase\":\"$phase\",\"cpus\":$(( ${cpus:-0}/1000000000 )),\"mem_gb\":$(( ${mem:-0}/1024/1024/1024 ))}"
    first=0
  done
  out+="]"
  echo "{\"count\":$(echo "$names" | grep -c . ),\"configured\":${RUNNER_COUNT},\"token\":$([ -n "$ACCESS_TOKEN" ] && echo true || echo false),\"runners\":${out}}"
}

cmd_logs() { docker logs --tail "${2:-100}" -f "${NAME_PREFIX}-${1:-1}"; }

cmd_validate() {
  # Prove the provisioning mechanics WITHOUT a GitHub token: launch the image
  # with an inert entrypoint, verify mounts/limits, then tear it down.
  ensure_dirs
  local name="${NAME_PREFIX}-validate"
  docker rm -f "$name" >/dev/null 2>&1
  build_args 99 "$name"
  # swap real entrypoint for an inert sleep so no registration is attempted
  local injected=(); local a
  for a in "${ARGS[@]}"; do
    [ "$a" = "$IMAGE" ] && injected+=( --entrypoint /bin/sh "$IMAGE" -c "sleep 30" ) || injected+=( "$a" )
  done
  log "validate: launching inert container to verify mounts/limits..."
  local errf; errf="$(mktemp /tmp/crf-validate.XXXXXX)"
  if ! docker run "${injected[@]}" >/dev/null 2>"$errf"; then
    err "docker run failed:"; cat "$errf" >&2; rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  echo "--- resource limits ---"
  docker inspect -f 'cpus={{.HostConfig.NanoCpus}} mem={{.HostConfig.Memory}} pids={{.HostConfig.PidsLimit}}' "$name"
  echo "--- mounts ---"
  docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' "$name"
  echo "--- tmpfs ---"
  docker inspect -f '{{json .HostConfig.Tmpfs}}' "$name"
  echo "--- docker.sock reachable inside container ---"
  docker exec "$name" sh -c '[ -S /var/run/docker.sock ] && echo "yes: docker.sock present" || echo "no socket"' 2>/dev/null
  docker rm -f "$name" >/dev/null 2>&1
  log "validate: OK (container removed). Provisioning mechanics verified on this host."
}

cmd_prune_cache() { rm -rf "${CACHE_ROOT:?}/"* && log "cache cleared: $CACHE_ROOT"; }

cmd_build_image() {
  # Build the runner image from the editable Dockerfile. Uses a CLEAN temp
  # context (only the Dockerfile) so the token/config never enter the build.
  local df="$CFGDIR/Dockerfile"
  [ -f "$df" ] || df="/usr/local/emhttp/plugins/$PLUGIN/default.Dockerfile"
  [ -f "$df" ] || { err "no Dockerfile found"; return 1; }
  local ctx; ctx="$(mktemp -d)"
  cp "$df" "$ctx/Dockerfile"
  log "building image '$IMAGE' from $df"
  docker build -t "$IMAGE" "$ctx"; local rc=$?
  rm -rf "$ctx"
  if [ $rc -eq 0 ]; then
    log "build complete: $IMAGE — restart the fleet to use it"
  else
    err "build failed (rc=$rc)"
  fi
  return $rc
}

case "${1:-status}" in
  start)        cmd_start ;;
  stop)         cmd_stop ;;
  restart)      cmd_stop; cmd_start ;;
  scale)        cmd_scale "${2:?usage: scale <N>}" ;;
  status)       cmd_status ;;
  status-json)  cmd_status_json ;;
  logs)         cmd_logs "${2:-1}" "${3:-100}" ;;
  validate)     cmd_validate ;;
  build-image)  cmd_build_image ;;
  prune-cache)  cmd_prune_cache ;;
  *) echo "usage: $0 {start|stop|restart|scale N|status|status-json|logs i|validate|build-image|prune-cache}"; exit 1 ;;
esac
