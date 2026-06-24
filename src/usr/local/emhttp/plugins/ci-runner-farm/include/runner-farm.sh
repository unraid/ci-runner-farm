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
REGISTRY_TOKEN_FILE="${CFGDIR}/registry-token"
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
IMAGE_SOURCE="builtin"                # builtin = run the locally-built image; remote = pull IMAGE from a registry
BUILTIN_IMAGE="ci-runner-farm-runner:latest"  # tag produced by the in-plugin image builder (build-image)
IMAGE=""                              # remote image ref, used when IMAGE_SOURCE=remote (e.g. ghcr.io/org/img:tag)
EPHEMERAL="false"                     # true => runner deregisters after each job
RUN_AS_ROOT="false"                   # false => jobs run as non-root 'runner' (sudo+docker groups), like
                                      # GitHub-hosted runners. true => jobs run as root (legacy).
ACCESS_TOKEN=""                       # GitHub PAT (repo scope; +admin:org for org)
SHARE_DOCKER_SOCK="true"              # mount host docker.sock for service containers (ignored when DIND=true)
DIND="true"                           # docker-in-docker: each runner gets its own daemon (--privileged).
                                      # Fixes GitHub Actions services: networking + 'port already allocated' collisions.
SHARED_IMAGE_CACHE="true"             # run a shared pull-through registry mirror so every DinD runner
                                      # reuses pulled images (postgres, etc.) instead of each pulling cold.
MIRROR_NAME="ci-runner-mirror"        # cache persists on the pool across restarts.
MIRROR_PORT="5000"
# ---- private registry auth: docker login so the host can pull a private IMAGE
REGISTRY_SERVER=""                     # e.g. ghcr.io — registry to docker login (empty = skip)
REGISTRY_USERNAME=""                   # registry username (password/token stored in registry-token file)
REGISTRY_TOKEN=""                      # registry password/token (loaded from registry-token file)
# ---- warm caches mounted into every runner (host-subdir:container-path) -----
# Cache mounts target the runner's home (/home/runner) so the non-root 'runner'
# user can read/write them (it cannot even traverse /root). RUNNER_UID:RUNNER_GID
# own the host cache dirs so the non-root runner can write (see ensure_dirs).
RUNNER_UID="1001"                     # uid of the image's 'runner' user (myoung34/github-runner)
RUNNER_GID="121"                      # gid of the 'runner' group
CACHE_MOUNTS="pnpm-store:/home/runner/.local/share/pnpm/store npm:/home/runner/.npm yarn:/home/runner/.cache/yarn ms-playwright:/home/runner/.cache/ms-playwright"
# ---- autoscaling (queue-aware): fleet floats between MIN and MAX ------------
AUTOSCALE="false"                     # true => a daemon grows/shrinks the fleet by demand
AUTOSCALE_MIN="2"                     # never go below this many runners
AUTOSCALE_MAX="16"                    # never go above this many
AUTOSCALE_MIN_IDLE="2"                # keep at least this many idle (warm) runners as headroom
AUTOSCALE_STEP="2"                    # add/remove this many per adjustment
AUTOSCALE_INTERVAL="30"              # seconds between checks
AUTOSCALE_IDLE_GRACE="5"             # consecutive over-idle checks before scaling down (anti-flap)
# ----------------------------------------------------------------------------

[ -f "$CFG" ] && . "$CFG"
[ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
[ -z "$REGISTRY_TOKEN" ] && [ -f "$REGISTRY_TOKEN_FILE" ] && REGISTRY_TOKEN="$(cat "$REGISTRY_TOKEN_FILE" 2>/dev/null)"
AUTOSCALE_PID="${CFGDIR}/autoscale.pid"

log()  { echo "[ci-runner-farm] $*"; }
err()  { echo "[ci-runner-farm] ERROR: $*" >&2; }
host() { hostname -s; }

managed_names() {
  docker ps -a --filter "label=${MANAGED_LABEL}" --format '{{.Names}}' | sort -V
}

current_count() { managed_names | grep -c . ; }

# is a runner actively running a job? (last meaningful log line)
runner_busy() {
  docker logs --tail 8 "$1" 2>&1 | grep -iE "Running job|Listening for Jobs|completed" | tail -1 | grep -qi "Running job"
}
busy_count() {
  local b=0 c
  for c in $(managed_names); do [ -n "$c" ] && runner_busy "$c" && b=$((b+1)); done
  echo "$b"
}

# remove up to $1 IDLE runners (highest index first), never below MIN, never busy ones
scale_down_idle() {
  local want="$1" removed=0 c
  for c in $(managed_names | sort -rV); do
    [ "$removed" -ge "$want" ] && break
    [ "$(current_count)" -le "$AUTOSCALE_MIN" ] && break
    if ! runner_busy "$c"; then
      log "autoscale: removing idle $c"
      remove_runner "$c"
      removed=$((removed+1))
    fi
  done
}

# one autoscaling evaluation: keep AUTOSCALE_MIN_IDLE warm runners, within [MIN,MAX]
autoscale_tick() {
  [ "$AUTOSCALE" = "true" ] || return 0
  local cur busy idle statef over target
  cur=$(current_count); busy=$(busy_count); idle=$((cur - busy))
  statef="${CFGDIR}/autoscale.state"; over=0
  [ -f "$statef" ] && over=$(cat "$statef" 2>/dev/null || echo 0)

  if [ "$idle" -lt "$AUTOSCALE_MIN_IDLE" ] && [ "$cur" -lt "$AUTOSCALE_MAX" ]; then
    target=$(( cur + AUTOSCALE_STEP )); [ "$target" -gt "$AUTOSCALE_MAX" ] && target=$AUTOSCALE_MAX
    log "autoscale: idle=$idle/$cur < buffer $AUTOSCALE_MIN_IDLE -> grow to $target"
    cmd_scale "$target" >/dev/null; echo 0 > "$statef"
  elif [ "$idle" -gt $(( AUTOSCALE_MIN_IDLE + AUTOSCALE_STEP )) ] && [ "$cur" -gt "$AUTOSCALE_MIN" ]; then
    over=$(( over + 1 )); echo "$over" > "$statef"
    if [ "$over" -ge "$AUTOSCALE_IDLE_GRACE" ]; then
      log "autoscale: idle=$idle/$cur high for $over checks -> shrink by $AUTOSCALE_STEP"
      scale_down_idle "$AUTOSCALE_STEP"; echo 0 > "$statef"
    fi
  else
    echo 0 > "$statef"
  fi
}

# long-running loop; re-reads config each tick so UI changes apply live
autoscale_daemon() {
  log "autoscale daemon up (min=$AUTOSCALE_MIN max=$AUTOSCALE_MAX buffer=$AUTOSCALE_MIN_IDLE step=$AUTOSCALE_STEP every ${AUTOSCALE_INTERVAL}s)"
  while true; do
    [ -f "$CFG" ] && . "$CFG"
    [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
    [ "$AUTOSCALE" = "true" ] || { log "autoscale disabled -> daemon exit"; rm -f "$AUTOSCALE_PID"; break; }
    autoscale_tick
    sleep "${AUTOSCALE_INTERVAL:-30}"
  done
}

autoscale_start() {
  [ "$AUTOSCALE" = "true" ] || return 0
  autoscale_stop
  nohup "$0" autoscale-daemon >>"${CFGDIR}/autoscale.log" 2>&1 &
  echo $! > "$AUTOSCALE_PID"
  log "autoscale daemon started (pid $(cat "$AUTOSCALE_PID"))"
}
autoscale_stop() {
  [ -f "$AUTOSCALE_PID" ] && kill "$(cat "$AUTOSCALE_PID")" 2>/dev/null
  rm -f "$AUTOSCALE_PID"
  pkill -f "runner-farm.sh autoscale-daemon" 2>/dev/null || true
}
autoscale_status() {
  if [ -f "$AUTOSCALE_PID" ] && kill -0 "$(cat "$AUTOSCALE_PID" 2>/dev/null)" 2>/dev/null; then
    echo "running (pid $(cat "$AUTOSCALE_PID"))"
  else echo "stopped"; fi
}

repo_for_index() {
  # round-robin assign a target repo to runner index (repo scope, multi-repo)
  local idx="$1"; local arr=($GH_REPOS); local n=${#arr[@]}
  [ "$n" -eq 0 ] && { echo ""; return; }
  echo "${arr[$(( (idx-1) % n ))]}"
}

# Inspect CACHE_ROOT and describe any problem that would break the fleet (empty
# output = OK). Split out from check_cache_root so the settings page can surface
# the SAME problems live, before the user clicks Start. Two classes:
#   - root filesystem (rootfs/tmpfs/overlay): RAM-backed, lost on reboot.
#   - FUSE user share (/mnt/user, fuse.shfs) while DinD is on: each runner's
#     Docker data root lands here, and overlay2 cannot run on FUSE, so buildx
#     and 'services:' jobs die with "mount overlay ... invalid argument".
cache_root_problem() {
  local line fstype target
  line=$(df -PT "$CACHE_ROOT" 2>/dev/null | awk 'NR==2')
  fstype=$(echo "$line" | awk '{print $2}')
  target=$(echo "$line" | awk '{print $NF}')
  case "$fstype" in
    rootfs|tmpfs|overlay|"")
      echo "CACHE_ROOT ($CACHE_ROOT) is on '${fstype:-unknown}' — the root filesystem, not a pool. Caches would fill RAM and vanish on reboot. Point it at a pool dataset, e.g. /mnt/<pool>/github-runner."
      return ;;
  esac
  [ "$target" = "/" ] && { echo "CACHE_ROOT ($CACHE_ROOT) resolves to '/'. Point it at a pool dataset, e.g. /mnt/<pool>/github-runner."; return; }
  if [ "$DIND" = "true" ]; then
    case "$fstype" in
      fuse.shfs|fuse*)
        echo "CACHE_ROOT ($CACHE_ROOT) is a /mnt/user share (FUSE/$fstype). With Docker-in-Docker on, each runner's Docker data root lives here and overlay2 cannot run on FUSE — buildx and 'services:' jobs fail with \"mount overlay ... invalid argument\". Point CACHE_ROOT at a pool dataset (e.g. /mnt/<pool>/github-runner), not /mnt/user/..."
        return ;;
    esac
  fi
}

# Hard guard before provisioning (start/scale/validate/boot): print the problem
# and fail. cache_root_problem() carries the detail and remediation.
check_cache_root() {
  local p; p="$(cache_root_problem)"
  [ -z "$p" ] && return 0
  err "$p"
  return 1
}

# docker login on the HOST so it can pull a private runner IMAGE (e.g. a private
# GHCR image). No-op unless server+username+token are all configured.
registry_login() {
  [ "$IMAGE_SOURCE" = "remote" ] || return 0
  [ -n "$REGISTRY_SERVER" ] || return 0
  local user="$REGISTRY_USERNAME" pass="$REGISTRY_TOKEN"
  # GHCR fallback: reuse the GitHub PAT (ACCESS_TOKEN) when no dedicated registry
  # token is set, so a private GHCR image pulls without configuring a second
  # token. Requires the PAT to carry the read:packages scope. Username can be
  # anything for GHCR PAT auth; default to the org/owner.
  if [ -z "$pass" ]; then
    case "$REGISTRY_SERVER" in
      ghcr.io|*.ghcr.io) pass="$ACCESS_TOKEN"; [ -z "$user" ] && user="$GH_OWNER" ;;
    esac
  fi
  [ -n "$user" ] && [ -n "$pass" ] || return 0
  if printf '%s' "$pass" | docker login "$REGISTRY_SERVER" -u "$user" --password-stdin >/dev/null 2>&1; then
    log "registry: logged in to $REGISTRY_SERVER as $user"
  else
    err "registry: docker login to $REGISTRY_SERVER failed (check server/username/token; GHCR needs read:packages on the PAT)"
    return 1
  fi
}

ensure_dirs() {
  mkdir -p "$CACHE_ROOT/work"
  local m dir
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] || continue
    dir="$CACHE_ROOT/${m%%:*}"
    mkdir -p "$dir"
    # Unless runners run as root, they write caches as the non-root 'runner' user
    # (RUNNER_UID:RUNNER_GID). Make the host cache dirs owned by it — chown only
    # when the owner differs so this stays fast on warm caches.
    if [ "$RUN_AS_ROOT" != "true" ] && [ "$(stat -c %u "$dir" 2>/dev/null)" != "$RUNNER_UID" ]; then
      chown -R "$RUNNER_UID:$RUNNER_GID" "$dir" 2>/dev/null || true
    fi
  done
  write_dind_config
}

# Shared pull-through registry mirror so all DinD runners reuse pulled images
# (docker.io) from one cache on the pool instead of each pulling cold.
ensure_mirror() {
  [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ] || return 0
  mkdir -p "$CACHE_ROOT/registry-mirror"
  if ! docker ps --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    docker rm -f "$MIRROR_NAME" >/dev/null 2>&1
    log "starting shared image cache ($MIRROR_NAME) on :$MIRROR_PORT"
    docker run -d --restart=unless-stopped --name "$MIRROR_NAME" \
      -p "${MIRROR_PORT}:5000" \
      -v "$CACHE_ROOT/registry-mirror:/var/lib/registry" \
      -e REGISTRY_PROXY_REMOTEURL="https://registry-1.docker.io" \
      registry:2 >/dev/null 2>&1 || err "could not start $MIRROR_NAME"
  fi
}

# daemon.json the inner dockerd of each DinD runner uses. Pins
# storage-driver=overlay2 — on a pool-backed data root the auto-detector may
# pick the zfs/btrfs driver and fail to start a fresh daemon, whereas overlay2
# runs on any of them (this matches how the Unraid host's own docker is set up).
# Adds the shared pull-through mirror when that's enabled.
write_dind_config() {
  [ "$DIND" = "true" ] || return 0
  local mirror=""
  [ "$SHARED_IMAGE_CACHE" = "true" ] && mirror=$(printf ',"registry-mirrors":["http://host.docker.internal:%s"],"insecure-registries":["host.docker.internal:%s"]' "$MIRROR_PORT" "$MIRROR_PORT")
  printf '{"storage-driver":"overlay2"%s}\n' "$mirror" > "$CACHE_ROOT/dind-daemon.json"
}

# resolve the image to run: the locally-built image (builtin) or a remote ref.
# Falls back to the built-in image if remote is selected but no IMAGE is set.
effective_image() {
  if [ "$IMAGE_SOURCE" = "remote" ] && [ -n "$IMAGE" ]; then echo "$IMAGE"; else echo "$BUILTIN_IMAGE"; fi
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
    -e RUN_AS_ROOT="$RUN_AS_ROOT"
    -e RUNNER_ALLOW_RUNASROOT="1"
    -e RUNNER_WORKDIR="/_work"
    -e npm_config_cache="/home/runner/.npm"
  )
  # warm caches mounted into the runner, configurable via CACHE_MOUNTS
  local m
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] && ARGS+=( -v "$CACHE_ROOT/${m%%:*}:${m#*:}" )
  done
  [ -n "$RUNNER_CPUS" ]   && ARGS+=( --cpus="$RUNNER_CPUS" )
  [ -n "$RUNNER_MEMORY" ] && ARGS+=( --memory="$RUNNER_MEMORY" )
  [ -n "$ACCESS_TOKEN" ] && ARGS+=( -e ACCESS_TOKEN="$ACCESS_TOKEN" )
  if [ "$DIND" = "true" ]; then
    # each runner runs its own dockerd: isolates service-container ports and
    # makes localhost:<port> reachable from job steps (the runner IS the host).
    ARGS+=( --privileged -e START_DOCKER_SERVICE=true )
    # Give the inner dockerd a real-filesystem data root. Without this it writes
    # /var/lib/docker onto the runner's overlay rootfs, so overlay2 (and buildx's
    # BuildKit) stack overlay-on-overlay and fail with "mount overlay ...
    # invalid argument". CACHE_ROOT must be a pool, not FUSE (check_cache_root).
    mkdir -p "$CACHE_ROOT/docker/$name"
    ARGS+=( -v "$CACHE_ROOT/docker/$name:/var/lib/docker" )
    # inner daemon.json: storage-driver + optional pull-through mirror
    ARGS+=( -v "$CACHE_ROOT/dind-daemon.json:/etc/docker/daemon.json:ro" )
    [ "$SHARED_IMAGE_CACHE" = "true" ] && ARGS+=( --add-host "host.docker.internal:host-gateway" )
  elif [ "$SHARE_DOCKER_SOCK" = "true" ]; then
    ARGS+=( -v /var/run/docker.sock:/var/run/docker.sock )
  fi
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
  ARGS+=( "$(effective_image)" )
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
  check_cache_root || return 1
  ensure_dirs
  ensure_mirror
  registry_login
  # with autoscaling on, start the floor (MIN) and let the daemon grow to demand
  local startn="$RUNNER_COUNT"
  [ "$AUTOSCALE" = "true" ] && startn="$AUTOSCALE_MIN"
  local i
  for i in $(seq 1 "$startn"); do start_one "$i"; done
  log "fleet up: $(managed_names | wc -l) runner(s)"
  [ "$AUTOSCALE" = "true" ] && autoscale_start
}

# Tear down a runner: graceful stop, remove the container, and drop its DinD
# data root (the per-runner /var/lib/docker bind dir created in build_args) so
# the pool is reclaimed instead of leaking a tree per retired runner.
remove_runner() {
  local c="$1"
  docker stop -t 30 "$c" >/dev/null 2>&1
  docker rm "$c" >/dev/null 2>&1
  rm -rf "$CACHE_ROOT/docker/$c" 2>/dev/null || true
}

cmd_stop() {
  autoscale_stop
  local names; names="$(managed_names)"
  [ -z "$names" ] && { log "no managed runners running"; return 0; }
  echo "$names" | while read -r c; do [ -n "$c" ] && { log "stopping $c (graceful deregister)"; remove_runner "$c"; }; done
}

cmd_scale() {
  local target="$1"; ensure_dirs; registry_login
  local current; current="$(managed_names | wc -l)"
  if [ "$target" -gt "$current" ]; then
    [ -z "$ACCESS_TOKEN" ] && { err "no token configured"; return 1; }
    check_cache_root || return 1
    local i
    for i in $(seq 1 "$target"); do
      docker ps -a --format '{{.Names}}' | grep -qx "${NAME_PREFIX}-${i}" || start_one "$i"
    done
  elif [ "$target" -lt "$current" ]; then
    local i
    for i in $(seq "$current" -1 $((target+1)) ); do
      remove_runner "${NAME_PREFIX}-${i}" && log "removed ${NAME_PREFIX}-${i}"
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
    printf "%-22s %-10s %-8s %-10s %s\n" "$c" "$st" "$(runner_phase "$c")" "$((cpus/1000000000))c/$((mem/1024/1024/1024))g" "$(effective_image)"
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
  local as="off"; [ "$AUTOSCALE" = "true" ] && as="$(autoscale_status)"
  local warn; warn="$(cache_root_problem | json_escape)"
  echo "{\"count\":$(echo "$names" | grep -c . ),\"configured\":${RUNNER_COUNT},\"token\":$([ -n "$ACCESS_TOKEN" ] && echo true || echo false),\"autoscale\":\"${as} [${AUTOSCALE_MIN}-${AUTOSCALE_MAX}, buffer ${AUTOSCALE_MIN_IDLE}]\",\"warning\":\"${warn}\",\"runners\":${out}}"
}

cmd_logs() { docker logs --tail "${2:-100}" -f "${NAME_PREFIX}-${1:-1}"; }

cmd_validate() {
  # Prove the provisioning mechanics WITHOUT a GitHub token: launch the image
  # with an inert entrypoint, verify mounts/limits, then tear it down.
  check_cache_root || return 1
  ensure_dirs
  registry_login
  local name="${NAME_PREFIX}-validate"
  docker rm -f "$name" >/dev/null 2>&1
  build_args 99 "$name"
  # swap real entrypoint for an inert sleep so no registration is attempted
  local injected=(); local a; local eimg; eimg="$(effective_image)"
  for a in "${ARGS[@]}"; do
    [ "$a" = "$eimg" ] && injected+=( --entrypoint /bin/sh "$eimg" -c "sleep 30" ) || injected+=( "$a" )
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
  rm -rf "$CACHE_ROOT/docker/$name" 2>/dev/null || true
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
  log "building image '$BUILTIN_IMAGE' from $df"
  docker build -t "$BUILTIN_IMAGE" "$ctx"; local rc=$?
  rm -rf "$ctx"
  if [ $rc -eq 0 ]; then
    log "build complete: $BUILTIN_IMAGE — set Image source to Built-in and restart the fleet to use it"
  else
    err "build failed (rc=$rc)"
  fi
  return $rc
}

# Called from the plugin install step, which ALSO re-runs on every boot
# (rc.local reinstalls all .plg). At boot this fires before the array/dockerd
# are up, so wait for both, then bring the fleet up idempotently. The caller
# detaches it so it never blocks install/boot. No-op until a token is configured
# (a fresh install waits for the user); cmd_start skips existing containers and
# (re)starts the autoscale daemon, so the fleet self-heals after a reboot.
cmd_boot_autostart() {
  [ -n "$ACCESS_TOKEN" ] || { log "boot-autostart: no token configured yet — skipping"; return 0; }
  local i
  for i in $(seq 1 150); do
    docker info >/dev/null 2>&1 && check_cache_root >/dev/null 2>&1 && break
    sleep 4
  done
  docker info >/dev/null 2>&1 || { err "boot-autostart: dockerd not ready after wait — giving up"; return 1; }
  check_cache_root >/dev/null 2>&1 || { err "boot-autostart: cache pool not ready after wait — giving up"; return 1; }
  log "boot-autostart: docker + cache pool ready — bringing fleet up"
  cmd_start
}

case "${1:-status}" in
  start)        cmd_start ;;
  boot-autostart)   cmd_boot_autostart ;;
  stop)         cmd_stop ;;
  restart)      cmd_stop; cmd_start ;;
  scale)        cmd_scale "${2:?usage: scale <N>}" ;;
  status)       cmd_status ;;
  status-json)  cmd_status_json ;;
  logs)         cmd_logs "${2:-1}" "${3:-100}" ;;
  validate)         cmd_validate ;;
  build-image)      cmd_build_image ;;
  prune-cache)      cmd_prune_cache ;;
  autoscale-daemon) autoscale_daemon ;;
  autoscale-tick)   autoscale_tick ;;
  autoscale-start)  autoscale_start ;;
  autoscale-stop)   autoscale_stop ;;
  autoscale-status) autoscale_status ;;
  *) echo "usage: $0 {start|boot-autostart|stop|restart|scale N|status|status-json|logs i|validate|build-image|prune-cache|autoscale-tick|autoscale-start|autoscale-stop|autoscale-status}"; exit 1 ;;
esac
