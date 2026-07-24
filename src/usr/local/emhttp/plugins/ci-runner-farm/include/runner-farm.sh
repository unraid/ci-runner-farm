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
# Ephemeral runtime caches/locks live on tmpfs, not the USB flash (they are
# rewritten every 60-300s while a settings tab is open — a flash-wear antipattern).
RUNDIR="/var/local/emhttp/${PLUGIN}"
mkdir -p "$RUNDIR" 2>/dev/null || RUNDIR="$CFGDIR"
CFG="${CFGDIR}/${PLUGIN}.cfg"
TOKEN_FILE="${CFGDIR}/token"
REGISTRY_TOKEN_FILE="${CFGDIR}/registry-token"
MANAGED_LABEL="net.unraid.ci-runner-farm.managed=true"
NAME_PREFIX="ci-runner"

# ---- defaults (overridden by ci-runner-farm.cfg) ---------------------------
GH_SCOPE="repo"                       # repo | org
GH_OWNER="unraid"
GH_REPOS="unraid/repo-a unraid/repo-b"
RUNNER_GROUP=""
RUNNER_COUNT=4
RUNNER_LABELS="self-hosted,unraid,build"
RUNNER_CPUS=""                        # per-runner CPU cap; empty = uncapped (CFS time-shares fairly)
RUNNER_MEMORY="16g"                   # per-runner memory cap (kept: memory isn't time-shared like CPU)
CACHE_ROOT="/mnt/cache/github-runner" # must be a dedicated SUBDIR under a pool/disk, never a bare mount root (see crf_safe_cache_root)
WORK_TMPFS_SIZE="8g"                  # empty => bind workdir to pool instead of RAM
IMAGE_SOURCE="builtin"                # builtin = run the locally-built image; remote = pull IMAGE from a registry
BUILTIN_IMAGE="ci-runner-farm-runner:latest"  # tag produced by the in-plugin image builder (build-image)
IMAGE=""                              # remote image ref, used when IMAGE_SOURCE=remote (e.g. ghcr.io/org/img:tag)
EPHEMERAL="false"                     # true => runner deregisters after each job
RUN_AS_ROOT="false"                   # false => jobs run as non-root 'runner' (sudo+docker groups), like
                                      # GitHub-hosted runners. true => jobs run as root (legacy).
ACCESS_TOKEN=""                       # GitHub PAT (repo scope; +admin:org for org). Stays host-side:
                                      # runners get a short-lived registration token, never the PAT itself.
SHARE_DOCKER_SOCK="false"             # mount host docker.sock for service containers (ignored when DIND=true).
                                      # Off by default: it gives jobs root-equivalent host access — opt in only
                                      # for trusted/private repos. DIND=true (the default) supersedes it anyway.
DIND="true"                           # docker-in-docker: each runner gets its own daemon (--privileged).
                                      # Fixes GitHub Actions services: networking + 'port already allocated' collisions.
SHARED_IMAGE_CACHE="true"             # run a shared pull-through registry mirror so every DinD runner
                                      # reuses pulled images (postgres, etc.) instead of each pulling cold.
MIRROR_NAME="ci-runner-mirror"        # cache persists on the pool across restarts.
MIRROR_PORT="5000"
# ---- network isolation -----------------------------------------------------
NETWORK_ISOLATION="off"               # off     = runners on the default docker bridge (legacy).
                                      # isolate = dedicated bridge; runners can't reach your OTHER
                                      #           Unraid containers (docker inter-network isolation).
                                      # strict  = isolate + DOCKER-USER egress rules that block the
                                      #           runners from the Unraid host + your LAN (RFC1918),
                                      #           while still allowing the internet + the shared mirror.
RUNNER_NETWORK="ci-runner-net"        # name of the dedicated bridge (created when isolation != off).
                                      # Docker auto-allocates its subnet; we read it back for the rules.
FW_TAG="ci-runner-farm"               # iptables comment tag used to find/remove our DOCKER-USER rules
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
# ---- image auto-update: keep the runner image current, roll the fleet --------
IMAGE_AUTOUPDATE="false"             # true => a daemon periodically pulls the runner image and,
                                     # when the digest moves, recreates runners on the new image.
IMAGE_AUTOUPDATE_INTERVAL="1800"     # seconds between update checks (default 30 min)
IMAGE_DRAIN_TIMEOUT="3600"           # max seconds to wait for a busy runner to finish its job
                                     # before leaving it on the old image this cycle (0 = wait forever)
# shellcheck disable=SC2034  # consumed only by RunnerFarmDashboard.page's Cond, never inside this script
DASHBOARD_WIDGET_ENABLE="true"       # show the Main->Dashboard status tile (read only by RunnerFarmDashboard.page's Cond)
# ----------------------------------------------------------------------------

# Allowlist of keys the settings page may set. load_cfg only ever assigns these.
CFG_KEYS="GH_SCOPE GH_OWNER GH_REPOS RUNNER_GROUP RUNNER_COUNT RUNNER_LABELS \
RUNNER_CPUS RUNNER_MEMORY CACHE_ROOT WORK_TMPFS_SIZE IMAGE_SOURCE IMAGE EPHEMERAL \
RUN_AS_ROOT REGISTRY_SERVER REGISTRY_USERNAME CACHE_MOUNTS SHARE_DOCKER_SOCK DIND \
SHARED_IMAGE_CACHE NETWORK_ISOLATION RUNNER_NETWORK MIRROR_PORT AUTOSCALE AUTOSCALE_MIN \
AUTOSCALE_MAX AUTOSCALE_MIN_IDLE AUTOSCALE_STEP AUTOSCALE_INTERVAL \
AUTOSCALE_IDLE_GRACE IMAGE_AUTOUPDATE IMAGE_AUTOUPDATE_INTERVAL IMAGE_DRAIN_TIMEOUT \
DASHBOARD_WIDGET_ENABLE"

# Read ci-runner-farm.cfg WITHOUT sourcing it (the file is written by the web form, so
# sourcing would execute anything a crafted value smuggled in). Parse KEY="value"
# lines ourselves and assign via printf -v — a literal string set, never eval'd —
# and only for keys on the allowlist above.
load_cfg() {
  [ -f "$CFG" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    [ "${line#*=}" = "$line" ] && continue           # no '=' on the line
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    case "$key" in *[!A-Za-z0-9_]*|'') continue;; esac
    case " $CFG_KEYS " in *" $key "*) ;; *) continue;; esac
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    printf -v "$key" '%s' "$val"
  done < "$CFG"
}

load_cfg
[ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
[ -z "$REGISTRY_TOKEN" ] && [ -f "$REGISTRY_TOKEN_FILE" ] && REGISTRY_TOKEN="$(cat "$REGISTRY_TOKEN_FILE" 2>/dev/null)"
# PID files live on tmpfs (RUNDIR), not flash: they're pure per-boot runtime state,
# so this both spares the USB stick and means a stale PID can't survive a reboot to
# later match an unrelated reused PID that autoscale_stop would then kill.
AUTOSCALE_PID="${RUNDIR}/autoscale.pid"
IMAGEUPDATE_PID="${RUNDIR}/imageupdate.pid"
SECURITY_CACHE="${RUNDIR}/security-warn.cache"   # cached public-repo warning (TTL below), so the
SECURITY_TTL="300"                               # UI's 5s status poll never hammers the GitHub API

log()  { echo "[ci-runner-farm] $*"; }
err()  { echo "[ci-runner-farm] ERROR: $*" >&2; }
host() { hostname -s; }

managed_names() {
  docker ps -a --filter "label=${MANAGED_LABEL}" --format '{{.Names}}' | sort -V
}

current_count() { managed_names | grep -c . ; }

# is a runner actively running a job? (last meaningful log line)
# Single busy/idle/starting/error predicate shared by the autoscaler (scale-down
# safety) and the UI status, so the two can never disagree. Deterministic: ask the
# runner which agent process is live (Runner.Worker = running a job, Runner.Listener
# = idle-waiting) in one docker exec, matching the image's own healthcheck, with a
# log-tail fallback for non-standard images or the brief gap between agent processes.
runner_state() {
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
runner_busy() { [ "$(runner_state "$1")" = busy ]; }
busy_count() {
  local b=0 c
  for c in $(managed_names); do [ -n "$c" ] && runner_busy "$c" && b=$((b+1)); done
  echo "$b"
}

# ── Config generation ────────────────────────────────────────────────────────
# A short fingerprint of every config value that build_args BAKES INTO a runner
# container at creation (image, resources, mounts, DinD/mirror, network, registration
# identity) — i.e. the settings that only take effect on recreate, NOT the live keys the
# daemons re-read each tick (autoscale thresholds, image-autoupdate cadence). Stamped as
# a label on every runner so the reconciler can tell which runners predate a config
# change and migrate them onto the new config as they go idle. IMPORTANT: whenever you
# add a setting that build_args bakes into the container, add it here too.
crf_confgen() {
  printf '%s\0' "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" "$RUNNER_GROUP" "$RUNNER_LABELS" \
    "$EPHEMERAL" "$RUNNER_CPUS" "$RUNNER_MEMORY" "$WORK_TMPFS_SIZE" "$CACHE_MOUNTS" \
    "$DIND" "$SHARE_DOCKER_SOCK" "$RUN_AS_ROOT" "$IMAGE_SOURCE" "$IMAGE" \
    "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" \
    "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" \
    | sha256sum | cut -c1-12
}
# The config fingerprint a running runner was created with ('' for runners created before
# this feature existed — they read as stale and migrate on the next reconcile).
runner_confgen() { docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.confgen" }}' "$1" 2>/dev/null; }
# How many RUNNING runners predate the current baked config (drives the drain loop and the
# UI "migrating" indicator).
count_stale_runners() {
  local cur c n=0; cur="$(crf_confgen)"
  for c in $(docker ps --filter "label=${MANAGED_LABEL}" --format '{{.Names}}'); do
    [ -n "$c" ] || continue
    [ "$(runner_confgen "$c")" = "$cur" ] || n=$((n+1))
  done
  echo "$n"
}

# Effective autoscale floor: AUTOSCALE_MIN, clamped to AUTOSCALE_MAX so a floor
# misconfigured above the ceiling can never bypass the resource cap.
autoscale_floor() { local f="$AUTOSCALE_MIN"; [ "$f" -gt "$AUTOSCALE_MAX" ] && f="$AUTOSCALE_MAX"; echo "$f"; }

# remove up to $1 IDLE runners (highest index first), never below the effective
# floor (MIN clamped to MAX), never busy ones
scale_down_idle() {
  local want="$1" removed=0 c floor
  floor="$(autoscale_floor)"
  for c in $(managed_names | sort -rV); do
    [ "$removed" -ge "$want" ] && break
    [ "$(current_count)" -le "$floor" ] && break
    if ! runner_busy "$c"; then
      log "autoscale: removing idle $c"
      remove_runner "$c"
      removed=$((removed+1))
    fi
  done
}

# Remove managed runners that can no longer service jobs, so the grow step below
# refills the floor with a freshly registered one. Two failure modes qualify:
#
#   1. exited/dead — crash, OOM, inner-dockerd failure, or a host/Docker restart
#      not yet reconciled. With --restart=no the plugin owns recovery.
#   2. running + Docker health=unhealthy — the runner's GitHub registration was
#      removed out from under it, so its listener loops forever on "Registration
#      was not found / Retrying until reconnected". It never exits, so mode (1)
#      misses it. The runner image's HEALTHCHECK flags exactly this state.
#
# Either way the zombie lingers and — because its last log line isn't "Running
# job" — counts as phantom *idle* capacity in busy_count/idle, suppressing growth
# so the live fleet silently shrinks to zero usable runners while current_count
# still looks full (jobs then queue forever behind zombies). Never reaped: a
# container still starting (state != running, or health=starting within the
# HEALTHCHECK start-period) or one on an image without a healthcheck (health
# empty => treated as fine, so this is a safe no-op until the new image ships).
# Caches/DinD roots persist as bind mounts across the recycle.
reap_dead_runners() {
  local c st health
  for c in $(managed_names); do
    [ -n "$c" ] || continue
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null)"
    case "$st" in
      exited|dead)
        log "autoscale: reaping dead runner $c (state=$st)" ;;
      running)
        [ "$health" = "unhealthy" ] || continue
        log "autoscale: reaping unhealthy runner $c (disconnected; health=$health)" ;;
      *) continue ;;
    esac
    deregister_runner_api "$c"
    docker rm -f "$c" >/dev/null 2>&1
  done
}

# one autoscaling evaluation: keep AUTOSCALE_MIN_IDLE warm runners, within [MIN,MAX]
autoscale_tick() {
  [ "$AUTOSCALE" = "true" ] || return 0
  reap_dead_runners        # drop dead containers first so idle accounting is real
  local cur busy idle statef over target
  cur=$(current_count); busy=$(busy_count); idle=$((cur - busy))
  statef="${RUNDIR}/autoscale.state"; over=0
  [ -f "$statef" ] && over=$(cat "$statef" 2>/dev/null || echo 0)

  # runner churn (crash, reap, or ephemeral exit) can drop the fleet below the
  # floor between ticks; the grow branch below only ever adds STEP to the
  # current count, so enforce AUTOSCALE_MIN unconditionally first. Clamp the
  # floor to AUTOSCALE_MAX so a floor misconfigured above the ceiling can
  # never bypass the resource cap.
  local floor
  floor="$(autoscale_floor)"
  if [ "$cur" -lt "$floor" ]; then
    log "autoscale: count $cur < floor $floor -> grow to $floor"
    cmd_scale "$floor" >/dev/null; echo 0 > "$statef"
    return 0
  fi

  if [ "$idle" -lt "$AUTOSCALE_MIN_IDLE" ] && [ "$cur" -lt "$AUTOSCALE_MAX" ]; then
    target=$(( cur + AUTOSCALE_STEP )); [ "$target" -gt "$AUTOSCALE_MAX" ] && target=$AUTOSCALE_MAX
    log "autoscale: idle=$idle/$cur < buffer $AUTOSCALE_MIN_IDLE -> grow to $target"
    cmd_scale "$target" >/dev/null; echo 0 > "$statef"
  elif [ "$idle" -gt $(( AUTOSCALE_MIN_IDLE + AUTOSCALE_STEP )) ] && [ "$cur" -gt "$floor" ]; then
    over=$(( over + 1 )); echo "$over" > "$statef"
    if [ "$over" -ge "$AUTOSCALE_IDLE_GRACE" ]; then
      log "autoscale: idle=$idle/$cur high for $over checks -> shrink by $AUTOSCALE_STEP"
      scale_down_idle "$AUTOSCALE_STEP"; echo 0 > "$statef"
    fi
  else
    echo 0 > "$statef"
  fi
  # Continuous safety net behind the Apply-triggered drain: migrate one runner still on a
  # previous baked config onto the current one (idle only). Also the path that eventually
  # picks up a direct cfg edit, or a runner whose job outlasted the Apply drain timeout.
  # Runs LAST so it never perturbs the scale math above; already under the fleet lock.
  reconcile_stale_runners
}

# long-running loop; re-reads config each tick so UI changes apply live
autoscale_daemon() {
  log "autoscale daemon up (min=$AUTOSCALE_MIN max=$AUTOSCALE_MAX buffer=$AUTOSCALE_MIN_IDLE step=$AUTOSCALE_STEP every ${AUTOSCALE_INTERVAL}s)"
  while true; do
    load_cfg
    [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
    [ "$AUTOSCALE" = "true" ] || { log "autoscale disabled -> daemon exit"; rm -f "$AUTOSCALE_PID"; break; }
    with_fleet_lock try autoscale_tick
    sleep "${AUTOSCALE_INTERVAL:-30}"
  done
}

autoscale_start() {
  [ "$AUTOSCALE" = "true" ] || return 0
  autoscale_stop
  nohup "$0" autoscale-daemon >>"${RUNDIR}/autoscale.log" 2>&1 &
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

# ---- image auto-update -----------------------------------------------------
# Keep the runner image current without operator intervention: a daemon pulls
# the configured image on a schedule and, when its digest moves, recreates each
# runner on the new image — draining (waiting for the current job to finish)
# first so no build is interrupted. Also refreshes the shared pull-through
# mirror image in place. Lifecycle mirrors the autoscale daemon: started by
# cmd_start when IMAGE_AUTOUPDATE=true, self-exits when the flag is turned off.

image_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }

# Pull the runner image (when it's a pullable remote ref) and the mirror image.
# Returns 0 iff the RUNNER image digest moved (that's what triggers a roll; the
# mirror is refreshed in place and never rolls the fleet), 1 otherwise. Uses a
# return code, not stdout, so the log() lines below don't pollute the signal. A
# builtin image is locally built and has no upstream to pull — rebuild it via
# build-image instead.
imageupdate_pull() {
  local changed=1 before after img
  img="$(effective_image)"
  if [ "$IMAGE_SOURCE" = "remote" ] && [ -n "$IMAGE" ]; then
    registry_login
    before="$(image_id "$img")"
    docker pull "$img" >/dev/null 2>&1
    after="$(image_id "$img")"
    if [ -n "$after" ] && [ "$before" != "$after" ]; then
      changed=0; log "image-update: $img ${before:-none} -> $after"
    fi
  else
    log "image-update: image source is builtin ($img) — nothing to pull; rebuild via build-image to update"
  fi
  # keep the shared pull-through mirror image current too (recreate in place if it moved)
  if [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ]; then
    before="$(image_id registry:2)"
    docker pull registry:2 >/dev/null 2>&1
    after="$(image_id registry:2)"
    if [ -n "$after" ] && [ "$before" != "$after" ]; then
      log "image-update: mirror image registry:2 changed -> recreating $MIRROR_NAME"
      docker rm -f "$MIRROR_NAME" >/dev/null 2>&1; ensure_mirror
    fi
  fi
  return $changed
}

# Drain one runner (wait for its current job to finish), then recreate it on the
# freshly-pulled image. Never interrupts a running job. If it stays busy past
# IMAGE_DRAIN_TIMEOUT, leave it on the old image — the next cycle retries.
drain_and_recreate() {
  local c="$1" waited=0 idx limit
  limit="${IMAGE_DRAIN_TIMEOUT:-3600}"
  # Wait for the runner to finish its job WITHOUT holding the fleet lock across the
  # (up to IMAGE_DRAIN_TIMEOUT — hours) idle-wait. fd 8 is the fleet mutex, held by our
  # with_fleet_lock caller; we hand it back during each sleep and re-take it only to
  # mutate, so the operator's Stop/Scale/Recycle (and daemon ticks) aren't starved for
  # the whole drain — and Stop can actually abort a runaway rollover.
  while runner_busy "$c"; do
    if [ "$limit" -gt 0 ] && [ "$waited" -ge "$limit" ]; then
      log "image-update: $c still busy after ${limit}s — leaving on old image this cycle"
      return 1
    fi
    flock -u 8 2>/dev/null                 # release the fleet lock while idle-waiting
    sleep 15; waited=$((waited+15))
    flock -w 20 8 2>/dev/null || { log "image-update: fleet busy elsewhere — deferring $c to next cycle"; return 1; }
  done
  # Re-holding the lock here. If the runner vanished while we were unlocked (the
  # operator hit Stop/Recycle mid-drain), do NOT recreate it — never resurrect a
  # runner the operator just removed.
  docker ps -a --format '{{.Names}}' | grep -qx "$c" || { log "image-update: $c no longer present — skipping recreate"; return 0; }
  idx="$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.index" }}' "$c" 2>/dev/null)"
  [ -z "$idx" ] && idx="${c##*-}"
  log "image-update: $c idle -> recreating on new image"
  remove_runner "$c"
  start_one "$idx"
}

# Roll the whole fleet onto the new image, one runner at a time so capacity stays
# up while each drains. Re-reads managed_names each loop (recreated names persist).
imageupdate_rollover() {
  local c
  for c in $(managed_names); do
    [ -n "$c" ] && drain_and_recreate "$c"
  done
  log "image-update: rollover complete ($(managed_names | wc -l) runner(s) on $(effective_image))"
}

# one update evaluation: pull, and roll only if the runner image actually changed
imageupdate_tick() {
  [ "$IMAGE_AUTOUPDATE" = "true" ] || return 0
  imageupdate_pull || return 0   # nonzero = image unchanged this cycle
  log "image-update: new runner image detected -> draining + recreating fleet"
  imageupdate_rollover
}

# long-running loop; re-reads config each tick so UI changes apply live
imageupdate_daemon() {
  log "image-update daemon up (every ${IMAGE_AUTOUPDATE_INTERVAL}s, drain-timeout ${IMAGE_DRAIN_TIMEOUT}s)"
  while true; do
    load_cfg
    [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
    [ -z "$REGISTRY_TOKEN" ] && [ -f "$REGISTRY_TOKEN_FILE" ] && REGISTRY_TOKEN="$(cat "$REGISTRY_TOKEN_FILE" 2>/dev/null)"
    [ "$IMAGE_AUTOUPDATE" = "true" ] || { log "image auto-update disabled -> daemon exit"; rm -f "$IMAGEUPDATE_PID"; break; }
    with_fleet_lock try imageupdate_tick
    sleep "${IMAGE_AUTOUPDATE_INTERVAL:-1800}"
  done
}

imageupdate_start() {
  [ "$IMAGE_AUTOUPDATE" = "true" ] || return 0
  imageupdate_stop
  nohup "$0" imageupdate-daemon >>"${RUNDIR}/imageupdate.log" 2>&1 &
  echo $! > "$IMAGEUPDATE_PID"
  log "image-update daemon started (pid $(cat "$IMAGEUPDATE_PID"))"
}
imageupdate_stop() {
  [ -f "$IMAGEUPDATE_PID" ] && kill "$(cat "$IMAGEUPDATE_PID")" 2>/dev/null
  rm -f "$IMAGEUPDATE_PID"
  pkill -f "runner-farm.sh imageupdate-daemon" 2>/dev/null || true
}
imageupdate_status() {
  if [ -f "$IMAGEUPDATE_PID" ] && kill -0 "$(cat "$IMAGEUPDATE_PID" 2>/dev/null)" 2>/dev/null; then
    echo "running (pid $(cat "$IMAGEUPDATE_PID"))"
  else echo "stopped"; fi
}

repo_for_index() {
  # round-robin assign a target repo to runner index (repo scope, multi-repo)
  local idx="$1"
  # shellcheck disable=SC2206  # GH_REPOS is a deliberately space-separated list
  local arr=($GH_REPOS); local n=${#arr[@]}
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
  # Location guard FIRST: CACHE_ROOT must resolve under /mnt/<pool> and not a system
  # dir or share root. This gates the mkdir/chown -R (ensure_dirs) and the bind mount
  # into every runner (build_args), so a value like /boot or /mnt/user/... — which
  # passes the fs-type check below — is rejected here before it can chown the flash
  # or expose a host path (and the PAT) to untrusted workflow code.
  crf_safe_cache_root >/dev/null 2>&1 || { err "CACHE_ROOT ($CACHE_ROOT) is unsafe — point it at a pool dataset under /mnt/<pool>, not a share root or system dir"; return 1; }
  local p; p="$(cache_root_problem)"
  [ -z "$p" ] && return 0
  err "$p"
  return 1
}

# ---- host-side GitHub runner tokens ----------------------------------------
# The long-lived PAT must NEVER enter a runner container: a job step could read
# it straight out of its own environment (`printenv ACCESS_TOKEN`), and a repo/org
# PAT is far more powerful than the per-job GITHUB_TOKEN. So we keep the PAT here
# on the host (where it already lives) and hand each container only a short-lived
# (~1h), single-purpose runner REGISTRATION token. The base image (myoung34) uses
# RUNNER_TOKEN directly when set and only falls back to minting from ACCESS_TOKEN
# when RUNNER_TOKEN is absent — so passing the token and omitting the PAT works.

# Thin GitHub REST helper: gh_api METHOD PATH -> response body on stdout (empty on
# failure). Requires ACCESS_TOKEN. Used for the token + deregistration calls below.
gh_api() {
  [ -n "$ACCESS_TOKEN" ] || return 1
  # Pass the bearer token via --config on stdin so the PAT never appears in argv
  # (/proc/<pid>/cmdline is world-readable), unlike a -H flag on the command line.
  printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
    | curl -fsSL -m 10 -X "$1" --config - \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com$2" 2>/dev/null
}

# Mint a runner registration token for a scope. $1 = "org:<name>" or
# "repo:<owner/repo>". Echoes the token (empty on failure). GitHub's
# registration-token endpoint returns {"token":"...","expires_at":"..."}.
registration_token() {
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

# Deregister a runner from GitHub host-side, by name, using the PAT. This replaces
# the base image's in-container SIGTERM deregister (we disable it via
# DISABLE_AUTOMATIC_DEREGISTRATION) — that path re-mints from ACCESS_TOKEN and so
# required the PAT inside the container. Doing it here is both safer (PAT stays on
# the host) and more robust (runs even when the container is hard-killed).
# Best-effort: a busy runner can't be deleted (GitHub 422) and a leftover offline
# entry is harmless — the next Start re-registers the same name with --replace.
deregister_runner_api() {
  local c="$1" rname idx repo base id
  [ -n "$ACCESS_TOKEN" ] && [ -n "$c" ] || return 0
  rname="$(host)-${c}"                          # matches RUNNER_NAME set in build_args
  if [ "$GH_SCOPE" = "org" ]; then
    base="/orgs/${GH_OWNER}"
  else
    idx="${c##*-}"; repo="$(repo_for_index "$idx")"
    [ -n "$repo" ] || return 0
    base="/repos/${repo}"
  fi
  # Resolve name -> id from the (pretty-printed, multi-line) runners list. Track the
  # last-seen id and name, and emit only at a runner-only key ("os") — label objects
  # carry "id"+"name" too but never "os", and a runner's own id/name precede its
  # labels, so at the "os" line cur/nm still hold the runner's values. Robust to the
  # API's whitespace/line formatting (a single-line grep pair is not).
  id="$(gh_api GET "${base}/actions/runners?per_page=100" | awk -v want="$rname" '
      /"id"[[:space:]]*:/   { if (match($0, /[0-9]+/)) cur = substr($0, RSTART, RLENGTH) }
      /"name"[[:space:]]*:/ { s=$0; sub(/^[^:]*:[[:space:]]*"/, "", s); sub(/".*/, "", s); nm=s }
      /"os"[[:space:]]*:/   { if (nm == want) { print cur; exit } }
    ')"
  [ -n "$id" ] || return 0
  # Best-effort (all callers force-remove the container regardless), but surface a
  # DELETE failure in the fleet log so a lingering "offline" registration on GitHub
  # isn't completely silent — recycle/scale-down otherwise report only success.
  if gh_api DELETE "${base}/actions/runners/${id}" >/dev/null 2>&1; then
    log "deregistered $rname from GitHub (id $id)"
  else
    log "warning: could not deregister $rname (id $id) from GitHub — a stale offline runner may linger"
  fi
}

# Fetch one GitHub REST endpoint for EVERY repo in GH_REPOS concurrently, writing each
# repo's raw response body to "$outdir/<n>" (n = 1-based position of the non-empty repo
# in GH_REPOS). The three background refreshers (queued, stats, public-repo) each sweep
# every target repo; doing it serially made refresh latency scale with repo count
# (N x per-call round-trip). Fan-out is chunked — drain every $maxpar — so a large repo
# list can't spawn hundreds of simultaneous curls or trip GitHub's concurrent-request
# secondary limit. Callers re-walk GH_REPOS with the SAME skip-empty rule so file <n>
# lines up with the right repo. Requires $ACCESS_TOKEN in scope.
gh_fetch_all() {
  local suffix="$1" outdir="$2" maxpar="${3:-8}" timeout="${4:-10}"
  local n=0 r
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    n=$((n+1))
    # PAT via --config on stdin so it never lands in argv (/proc/<pid>/cmdline is
    # world-readable and reachable from a broken-out privileged runner) — same
    # hardening as gh_api. printf is a shell builtin (no argv exposure) and the whole
    # printf|curl pipeline is backgrounded as a unit, so each curl gets its own stdin.
    printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
      | curl -s --max-time "$timeout" --config - \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${r}${suffix}" > "$outdir/$n" 2>/dev/null &
    [ $((n % maxpar)) -eq 0 ] && wait
  done
  wait
}

# The single biggest footgun: pointing privileged runners at a PUBLIC repo. A
# fork PR on a public repo runs attacker-controlled code, and here that code runs
# in a --privileged DinD container (or with the host docker.sock mounted) — i.e.
# root on the Unraid box. This asks GitHub, using the PAT, whether any repo-scope
# target is public while privileged, and returns a warning describing it (empty
# = nothing to warn about). It WARNS, never blocks — an operator who knows what
# they're doing (e.g. an internal-only public repo) isn't trapped. Only relevant
# for repo scope; org scope should use a runner group restricted to private repos.
# Result is cached with a TTL (SECURITY_TTL) so the UI's 5s status poll doesn't
# hit the GitHub API on every refresh.
public_repo_problem() {
  [ "$GH_SCOPE" = "repo" ] || { echo ""; return; }
  { [ "$DIND" = "true" ] || [ "$SHARE_DOCKER_SOCK" = "true" ]; } || { echo ""; return; }
  [ -n "$ACCESS_TOKEN" ] || { echo ""; return; }   # can't query without a token
  if [ -f "$SECURITY_CACHE" ]; then
    local age; age=$(( $(date +%s) - $(stat -c %Y "$SECURITY_CACHE" 2>/dev/null || echo 0) ))
    [ "$age" -ge 0 ] && [ "$age" -lt "$SECURITY_TTL" ] && { cat "$SECURITY_CACHE"; return; }
  fi
  local pub="" repo vis tmpd n=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo ""; return; }   # transient temp failure: don't cache, retry next call
  # One concurrent visibility probe per repo (see gh_fetch_all). GitHub's repo API
  # returns "visibility":"public|private|internal"; a 404 (a repo the PAT can't see)
  # returns a JSON error body with no "visibility" field, so it reads as unknown and is
  # not flagged — the same outcome the old per-repo `curl -f` gave.
  gh_fetch_all "" "$tmpd" 8 5
  for repo in $GH_REPOS; do
    [ -n "$repo" ] || continue
    n=$((n+1))
    vis="$(grep -o '"visibility"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmpd/$n" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [ "$vis" = "public" ] && pub="$pub ${repo}"
  done
  rm -rf "$tmpd"
  local msg=""
  [ -n "$pub" ] && msg="PUBLIC repo(s) targeted while runners are privileged (DinD / host docker.sock):${pub}. Fork-PR code on a public repo would run as root on this server. Use trusted/private repos only, or an org runner-group restricted to private repos. See the Security section of the plugin README."
  printf '%s' "$msg" > "$SECURITY_CACHE" 2>/dev/null || true
  printf '%s' "$msg"
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
  if printf '%s' "$pass" | docker login -u "$user" --password-stdin -- "$REGISTRY_SERVER" >/dev/null 2>&1; then
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
    dir="$(crf_safe_mount_subdir "${m%%:*}")" || { err "skipping unsafe cache mount '${m%%:*}' — it escapes CACHE_ROOT"; continue; }
    # Only ever chown -R a cache dir WE create here. A pre-existing dir is left
    # untouched: we never recurse ownership into a tree we didn't make — on a shared
    # cache root that could be the operator's own data whose name happens to collide
    # with a cache mount (e.g. a 'docker'/'npm' dir already on the pool). When runners
    # are non-root, a freshly created (empty) dir is handed to RUNNER_UID:RUNNER_GID so
    # the 'runner' user can populate it. (Re-owning an existing cache after a
    # RUN_AS_ROOT flip is a one-time 'prune-cache', not a silent chown -R of live data.)
    [ -d "$dir" ] && continue
    mkdir -p "$dir" || { err "could not create cache dir '$dir'"; continue; }
    [ "$RUN_AS_ROOT" != "true" ] && chown -R "$RUNNER_UID:$RUNNER_GID" "$dir" 2>/dev/null || true
  done
  write_dind_config
}

# Dedicated user-defined bridge for the fleet (created when NETWORK_ISOLATION is
# on). Docker isolates user-defined bridges from each other, so runners here can't
# reach your OTHER Unraid containers. Docker auto-allocates the subnet; strict mode
# reads it back for the egress rules. No-op (and never created) when isolation=off.
ensure_network() {
  [ "$NETWORK_ISOLATION" = "off" ] && return 0
  docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1 && return 0
  log "creating isolated runner network $RUNNER_NETWORK"
  # Label our networks so they're identifiable as plugin-created. (RUNNER_NETWORK
  # defaults to the plugin-specific 'ci-runner-net'; a foreign network deliberately
  # pointed at by a hand-edited RUNNER_NETWORK is not verified here to preserve
  # upgrade compatibility with pre-label networks — see docs on isolation caveats.)
  docker network create --driver bridge --label net.unraid.ci-runner-farm=1 "$RUNNER_NETWORK" >/dev/null \
    || err "could not create network $RUNNER_NETWORK"
}

# Does container $1 sit on the network the CURRENT isolation mode expects? Used to
# detect a mid-flight NETWORK_ISOLATION change (off <-> isolate/strict) so the mirror
# and runners left on the old network get recreated on Start. off => default 'bridge';
# isolate/strict => the dedicated $RUNNER_NETWORK.
on_expected_network() {
  local nets; nets=" $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null) "
  if [ "$NETWORK_ISOLATION" = "off" ]; then
    echo "$nets" | grep -q " bridge "
  else
    echo "$nets" | grep -q " $RUNNER_NETWORK "
  fi
}

# Shared pull-through registry mirror so all DinD runners reuse pulled images
# (docker.io) from one cache on the pool instead of each pulling cold. When network
# isolation is on the mirror joins the dedicated bridge and runners reach it by name
# ($MIRROR_NAME:5000) over that bridge — so it keeps working even in strict mode,
# where host access is blocked. Otherwise it's published on the host ($MIRROR_PORT)
# and reached via host.docker.internal (the legacy path).
ensure_mirror() {
  [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ] || return 0
  mkdir -p "$CACHE_ROOT/registry-mirror"
  # If the mirror is up but on the wrong network for the current mode (operator
  # switched NETWORK_ISOLATION without a full Stop/Start), drop it so it's recreated
  # below on the right network — otherwise runners can't reach it by name and strict's
  # firewall keys off its stale IP. Its cache is on the pool volume, so this is cheap.
  if docker ps -a --format '{{.Names}}' | grep -qx "$MIRROR_NAME" && ! on_expected_network "$MIRROR_NAME"; then
    log "network mode changed -> recreating shared image cache ($MIRROR_NAME)"
    docker rm -f "$MIRROR_NAME" >/dev/null 2>&1
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    docker rm -f "$MIRROR_NAME" >/dev/null 2>&1
    local netargs=()
    if [ "$NETWORK_ISOLATION" != "off" ]; then
      ensure_network
      netargs=( --network "$RUNNER_NETWORK" )
      log "starting shared image cache ($MIRROR_NAME) on $RUNNER_NETWORK"
    else
      # Bind the published mirror to the docker0 bridge gateway (where runners reach
      # it via host.docker.internal:host-gateway) instead of 0.0.0.0 — so it is NOT an
      # open, unauthenticated Docker Hub proxy exposed to the LAN/WAN. Fall back to
      # localhost if the gateway can't be resolved (safe: the mirror is only a cache,
      # so an unreachable one just means direct pulls — never a wildcard bind).
      local gwip; gwip="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
      netargs=( -p "${gwip:-127.0.0.1}:${MIRROR_PORT}:5000" )
      # Pre-flight: a wildcard 0.0.0.0:PORT held by ANY other container/process blocks
      # the publish on every interface (Docker's allocator treats the port as globally
      # taken), so give an actionable error up front instead of a doomed docker run.
      if command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${MIRROR_PORT}$"; then
        err "shared image cache: host port ${MIRROR_PORT} is already in use by another service — set MIRROR_PORT to a free port in /boot/config/plugins/ci-runner-farm/ci-runner-farm.cfg, then Restart the fleet"
        return 1
      fi
      log "starting shared image cache ($MIRROR_NAME) on ${gwip:-127.0.0.1}:$MIRROR_PORT"
    fi
    # Capture the real docker error (don't swallow it): "port is already allocated",
    # an image-pull failure, etc. were otherwise lost, leaving only a generic message.
    local mout
    if ! mout="$(docker run -d --restart=unless-stopped --name "$MIRROR_NAME" \
        "${netargs[@]}" \
        -v "$CACHE_ROOT/registry-mirror:/var/lib/registry" \
        -e REGISTRY_PROXY_REMOTEURL="https://registry-1.docker.io" \
        registry:2 2>&1)"; then
      err "could not start $MIRROR_NAME: ${mout##*: }"
      docker rm -f "$MIRROR_NAME" >/dev/null 2>&1   # clear the Created residue so the next cycle retries clean
    fi
  fi
}

# daemon.json the inner dockerd of each DinD runner uses. Pins
# storage-driver=overlay2 — on a pool-backed data root the auto-detector may
# pick the zfs/btrfs driver and fail to start a fresh daemon, whereas overlay2
# runs on any of them (this matches how the Unraid host's own docker is set up).
# Adds the shared pull-through mirror when that's enabled.
write_dind_config() {
  [ "$DIND" = "true" ] || return 0
  local mirror="" ep
  if [ "$SHARED_IMAGE_CACHE" = "true" ]; then
    # Isolated: reach the mirror by container name over the dedicated bridge (works
    # in strict mode, where host access is blocked). Legacy: via the published host
    # port. The inner dockerd shares the runner's netns, so Docker DNS resolves the
    # name for it.
    if [ "$NETWORK_ISOLATION" != "off" ]; then ep="${MIRROR_NAME}:5000"; else ep="host.docker.internal:${MIRROR_PORT}"; fi
    mirror=$(printf ',"registry-mirrors":["http://%s"],"insecure-registries":["%s"]' "$ep" "$ep")
  fi
  printf '{"storage-driver":"overlay2"%s}\n' "$mirror" > "$CACHE_ROOT/dind-daemon.json"
}

# --- strict-mode egress firewall (DOCKER-USER) ------------------------------
# strict isolation blocks runners from reaching the Unraid host and your LAN while
# still allowing the internet (GitHub, package registries) and the shared mirror.
# We drive Docker's DOCKER-USER chain (the supported hook for user rules on
# forwarded container traffic). Rules are scoped to the runner network's subnet, so
# nothing else on the box is affected. Best-effort: a missing iptables or chain
# just means egress isn't restricted (logged), never a failed Start.

# Remove every rule we previously added (matched by our comment tag), highest line
# number first so deletes don't renumber out from under us. Covers BOTH chains we
# touch: DOCKER-USER (forwarded traffic) and INPUT (traffic to the host's own IPs).
# Idempotent.
firewall_clear() {
  command -v iptables >/dev/null 2>&1 || return 0
  local chain n
  for chain in DOCKER-USER INPUT; do
    for n in $(iptables -w -L "$chain" --line-numbers -n 2>/dev/null \
               | awk -v t="$FW_TAG" 'index($0,t){print $1}' | sort -rn); do
      iptables -w -D "$chain" "$n" 2>/dev/null || true
    done
  done
}

# Install the egress rules for strict mode. Reads the runner network's subnet and
# the mirror's IP back from docker (no pinned subnet -> no collisions). RETURN =
# "leave DOCKER-USER, let Docker's normal ACCEPT handle it"; public destinations
# match none of the DROPs and fall through, so internet egress still works.
firewall_apply() {
  [ "$NETWORK_ISOLATION" = "strict" ] || return 0
  command -v iptables >/dev/null 2>&1 || { err "strict isolation needs iptables — egress NOT restricted"; return 0; }
  docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1 || { err "strict isolation: $RUNNER_NETWORK missing — egress NOT restricted"; return 0; }
  local s gw mip i=1
  s="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  gw="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  [ -n "$s" ] || { err "strict isolation: could not resolve $RUNNER_NETWORK subnet — egress NOT restricted"; return 0; }
  mip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MIRROR_NAME" 2>/dev/null)"
  firewall_clear
  # Order matters (top-down): allow mirror + established replies, THEN drop host +
  # every private range. Inserting at increasing indices keeps them in this order
  # ahead of Docker's trailing RETURN.
  [ -n "$mip" ] && { iptables -w -I DOCKER-USER "$i" -s "$s" -d "$mip" -p tcp --dport 5000 -j RETURN -m comment --comment "$FW_TAG:mirror"; i=$((i+1)); }
  iptables -w -I DOCKER-USER "$i" -d "$s" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN -m comment --comment "$FW_TAG:estab"; i=$((i+1))
  [ -n "$gw" ] && { iptables -w -I DOCKER-USER "$i" -s "$s" -d "$gw" -j DROP -m comment --comment "$FW_TAG:host"; i=$((i+1)); }
  iptables -w -I DOCKER-USER "$i" -s "$s" -d 10.0.0.0/8     -j DROP -m comment --comment "$FW_TAG:lan10";  i=$((i+1))
  iptables -w -I DOCKER-USER "$i" -s "$s" -d 172.16.0.0/12  -j DROP -m comment --comment "$FW_TAG:lan172"; i=$((i+1))
  iptables -w -I DOCKER-USER "$i" -s "$s" -d 192.168.0.0/16 -j DROP -m comment --comment "$FW_TAG:lan192"; i=$((i+1))
  iptables -w -I DOCKER-USER "$i" -s "$s" -d 100.64.0.0/10  -j DROP -m comment --comment "$FW_TAG:cgnat"; i=$((i+1))
  # DOCKER-USER is in the FORWARD path only. A runner reaching the Unraid host's OWN
  # ip (e.g. the webGUI on the LAN address, or the host's tailscale ip) is delivered
  # locally via INPUT and never forwarded, so the rules above miss it — that leaves
  # the management UI reachable. Drop new traffic from the runner subnet to the host
  # here too; the runner needs nothing that originates host-side (the mirror is a
  # container = forwarded, DNS is Docker's embedded resolver inside the netns).
  iptables -w -I INPUT 1 -s "$s" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN -m comment --comment "$FW_TAG:in-estab"
  iptables -w -I INPUT 2 -s "$s" -j DROP -m comment --comment "$FW_TAG:in-drop"
  log "strict isolation: egress locked to internet+mirror for $s (Unraid host + LAN blocked)"
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
    # --restart=no (NOT unless-stopped): the registration token baked in below is
    # short-lived (~1h) and the runner re-runs config on start, so letting Docker
    # auto-restart a crashed/exited runner makes it re-register with an expired
    # token — GitHub returns 404 ("Not configured") and the container crash-loops.
    # The plugin is the sole supervisor: start_stopped_managed (boot) and
    # reap_dead_runners (autoscale) recreate a dead runner with a freshly minted
    # token instead of resurrecting it with the stale one.
    -d --restart=no
    --name "$name" --hostname "$name"
    --pids-limit=4096
    --label "${MANAGED_LABEL%=*}=true"
    --label "net.unraid.ci-runner-farm.index=${idx}"
    --label "net.unraid.ci-runner-farm.confgen=$(crf_confgen)"
    -e RUNNER_NAME="$(host)-${name}"
    -e LABELS="$RUNNER_LABELS"
    -e DISABLE_AUTO_UPDATE="true"
    -e DISABLE_AUTOMATIC_DEREGISTRATION="true"   # we deregister host-side (deregister_runner_api)
    -e RUN_AS_ROOT="$RUN_AS_ROOT"
    -e RUNNER_ALLOW_RUNASROOT="1"
    -e RUNNER_WORKDIR="/_work"
    -e npm_config_cache="/home/runner/.npm"
  )
  # myoung34 entrypoints enable ephemeral mode when the EPHEMERAL env var is
  # PRESENT (any value, including "false") — so only pass it when it is true,
  # otherwise EPHEMERAL="false" silently produces one-job-then-exit runners.
  [ "$EPHEMERAL" = "true" ] && ARGS+=( -e EPHEMERAL="true" )
  # warm caches mounted into the runner, configurable via CACHE_MOUNTS
  local m
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] || continue
    local hostdir; hostdir="$(crf_safe_mount_subdir "${m%%:*}")" || { err "skipping unsafe cache mount '${m%%:*}'"; continue; }
    ARGS+=( -v "$hostdir:${m#*:}" )
  done
  [ -n "$RUNNER_CPUS" ]   && ARGS+=( --cpus="$RUNNER_CPUS" )
  [ -n "$RUNNER_MEMORY" ] && ARGS+=( --memory="$RUNNER_MEMORY" )
  # network isolation: put the runner on the dedicated bridge (off = default bridge)
  [ "$NETWORK_ISOLATION" != "off" ] && ARGS+=( --network "$RUNNER_NETWORK" )
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
    # Persisted DinD diagnostics dir (kept by remove_runner, unlike the data root):
    # the runner image's wait-docker.sh snapshots inner-daemon state (storage driver,
    # Native Overlay Diff, backing fs, userxattr, uid_map) here and mirrors the inner
    # dockerd log, so a layer-extraction failure (e.g. the whiteout "operation not
    # permitted" mknod seen on ZFS-backed overlay2 under the services: workload) leaves
    # a post-mortem trail off the ephemeral container. Inspect $CACHE_ROOT/dind-logs/<runner>.
    mkdir -p "$CACHE_ROOT/dind-logs/$name"
    ARGS+=( -v "$CACHE_ROOT/dind-logs/$name:/var/log/dind" )
    # Legacy mirror path: reach the host-published mirror via host.docker.internal.
    # Under isolation the mirror is on the dedicated bridge and reached by name, so
    # host-gateway isn't needed (and is blocked in strict) — skip it.
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
  local scope_target=""
  if [ "$GH_SCOPE" = "org" ]; then
    ARGS+=( -e RUNNER_SCOPE="org" -e ORG_NAME="$GH_OWNER" )
    [ -n "$RUNNER_GROUP" ] && ARGS+=( -e RUNNER_GROUP="$RUNNER_GROUP" )
    scope_target="org:$GH_OWNER"
  else
    local repo; repo="$(repo_for_index "$idx")"
    ARGS+=( -e RUNNER_SCOPE="repo" -e REPO_URL="https://github.com/${repo}" )
    scope_target="repo:$repo"
  fi
  # Hand the container a short-lived registration token, never the PAT (see the
  # host-side token helpers above). Skipped when no PAT is configured — e.g. the
  # 'validate' path, which swaps the entrypoint for a sleep and never registers.
  if [ -n "$ACCESS_TOKEN" ] && [ "${NO_REGISTER:-0}" != "1" ]; then
    local reg; reg="$(registration_token "$scope_target")"
    [ -z "$reg" ] && { err "could not mint a runner registration token for ${scope_target#*:} (check the PAT's scope/permissions)"; return 1; }
    ARGS+=( -e RUNNER_TOKEN="$reg" )
  fi
  ARGS+=( "$(effective_image)" )
}

start_one() {
  local idx="$1"; local name="${NAME_PREFIX}-${idx}"
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    log "runner $name already exists; skipping"; return 0
  fi
  build_args "$idx" || { err "runner $name not started (registration-token error)"; return 1; }
  log "starting $name (cpus=$RUNNER_CPUS mem=$RUNNER_MEMORY scope=$GH_SCOPE)"
  docker run "${ARGS[@]}" >/dev/null
}

# Recreate a stopped managed runner with a FRESH registration token. We cannot
# `docker start` it in place: the baked-in RUNNER_TOKEN is short-lived (~1h) and
# the runner re-runs config on start, so a stale token yields a GitHub 404
# ("Not configured") and a crash loop. Only the container is removed — the warm
# caches and the DinD data root are bind mounts on the pool (see build_args), so
# they survive under the same name and the replacement starts warm. The stale
# GitHub registration is dropped host-side first (the PAT never touches the
# container) so the fresh runner re-registers cleanly.
recreate_stopped_runner() {
  local c="$1" idx
  idx="$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.index" }}' "$c" 2>/dev/null)"
  [ -z "$idx" ] && idx="${c##*-}"
  deregister_runner_api "$c"
  docker rm -f "$c" >/dev/null 2>&1
  start_one "$idx"
}

# Bring back managed runner containers that exist but are stopped — e.g. after
# Unraid stopped Docker for an array stop, which leaves them "exited", reconciled
# by the docker_started event hook. Each is recreated with a fresh registration
# token (see recreate_stopped_runner) rather than started in place, because the
# original token has almost certainly expired by the time Docker comes back.
start_stopped_managed() {
  local c st
  for c in $(managed_names); do
    [ -n "$c" ] || continue
    st="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)"
    [ "$st" = "true" ] && continue
    log "recreating stopped runner $c with a fresh registration token"
    recreate_stopped_runner "$c"
  done
}

# Cache/network provisioning shared by cmd_start and the Fleet recycle path before
# they run start_one: validate the cache root (hard guard — aborts on FUSE for
# DIND, etc.), create the cache dirs / isolated network / image-cache mirror, and
# log in to a remote registry. Returns non-zero (problem already logged) when the
# cache-root guard OR a real registry login fails, so callers can bail before
# provisioning (registry_login is a no-op returning 0 for the built-in image or
# when no remote registry/creds are set, so it only bites an actually-failed remote
# auth). Firewall handling is deliberately NOT here: the strict-mode egress rules
# are keyed on the runner subnet, not per container, so a replacement rejoining
# that subnet is already covered by the fleet's existing rules. cmd_start
# (re)programs them via provision_preflight; recycle must NOT clear+reapply them
# mid-recycle, which would briefly drop egress protection for every strict runner.
# (cmd_scale runs its own lighter inline subset and is intentionally not a caller.)
provision_base() {
  check_cache_root || return 1
  ensure_dirs
  ensure_network
  ensure_mirror
  registry_login || return 1
}

# Full Start preflight: the shared base provisioning, then (re)program the strict
# egress firewall (firewall_apply is a no-op unless NETWORK_ISOLATION=strict).
provision_preflight() {
  provision_base || return 1
  firewall_clear                                # drop stale rules (e.g. strict -> off/isolate)
  firewall_apply                                # re-add egress rules (no-op unless strict)
}

# Serialize all fleet mutation (UI start/stop/restart/scale/recycle AND the autoscale
# / image-update daemon ticks) behind one lock (fd 8), so a manual action and a daemon
# tick can't race into a duplicate docker-run or a false "removed but not recreated"
# (e.g. a "Scale to N" silently reverted by the next autoscale tick). Mode "wait": UI
# commands block briefly. Mode "try": daemon ticks take it non-blocking and simply
# skip a contended tick (retried next interval), so a stuck UI action can never
# deadlock the daemons. Runs the command in a subshell that holds fd 8 for its duration.
with_fleet_lock() {
  local mode="$1"; shift
  if [ "$mode" = try ]; then
    ( flock -n 8 || exit 0; "$@" ) 8>"$RUNDIR/fleet.lock"
  else
    ( flock -w 20 8 || { err "fleet busy (another start/stop/scale/recycle or a daemon tick is running) — try again"; exit 1; }; "$@" ) 8>"$RUNDIR/fleet.lock"
  fi
}
cmd_restart() { cmd_stop; cmd_start; }

# Operator convenience: (re)start the shared image cache + regenerate the runner DinD
# config to match — WITHOUT a full fleet Start/Restart (useful after changing
# SHARED_IMAGE_CACHE / MIRROR_PORT, or to clear a failed mirror). The mirror is a
# separate container so this doesn't disrupt runners; already-running runners pick up
# the new mirror endpoint only when they are next recreated.
cmd_mirror_up() {
  ensure_mirror
  write_dind_config
  if docker ps --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    log "shared image cache ($MIRROR_NAME) is up"
  elif [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ]; then
    err "shared image cache is not running — see the error above"
  fi
}

# ── Drain-aware config reconciliation ────────────────────────────────────────
# Recycle AT MOST ONE running runner that predates the current baked config onto the new
# one, while it is IDLE or in an ERROR state — a busy runner keeps its in-flight job and is
# caught on a later pass once it finishes, so a settings change never kills a job. One-per-pass so
# the fleet migrates gradually and never drops all its capacity at once. Lock-free: the
# CALLER must hold the fleet lock (cmd_recycle, which this calls, assumes the dispatch or
# caller already locked). Returns 0 always; callers poll count_stale_runners to know when
# the fleet is fully migrated.
reconcile_stale_runners() {
  local cur c gen; cur="$(crf_confgen)"
  for c in $(docker ps --filter "label=${MANAGED_LABEL}" --format '{{.Names}}' | sort -V); do
    [ -n "$c" ] || continue
    gen="$(runner_confgen "$c")"
    [ "$gen" = "$cur" ] && continue                  # already on the current config
    # Migrate idle runners; also migrate error-state ones (a wedged runner will never
    # reach idle on its own, so leaving it would strand it on the old config forever).
    # Busy/starting runners are left for a later pass.
    case "$(runner_state "$c")" in idle|error) ;; *) continue ;; esac
    log "reconcile: $c predates a config change — recycling it onto the current config"
    if ! cmd_recycle "$c" >/dev/null 2>&1; then
      if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
        log "reconcile: recycle of $c failed but it is still present — will retry next pass"
      else
        # cmd_recycle removed it but the replacement failed to start: the fleet just
        # shrank and no later pass can retry a runner that no longer exists. Record it
        # so the drain reports the loss instead of a clean-migration success.
        log "reconcile: $c was removed but its replacement failed to start — fleet is down one runner"
        echo "$c" >> "$RUNDIR/reconcile.shrink"
      fi
    fi
    return 0                                          # one per pass; the drain/tick loop re-invokes
  done
  return 0
}

# Detached worker behind the Settings "Apply" button: migrate every stale runner onto the
# new config as each goes idle, then exit. Re-reads the cfg each pass so an Apply made
# mid-drain retargets the SAME drain (the flock in the dispatch keeps it to one). Gives up
# after IMAGE_DRAIN_TIMEOUT on runners whose job outlasts it — they migrate on their next
# idle via the autoscale tick, or on the next Apply/recycle. Progress is logged to
# autoscale.log, which the farm-log panel tails.
cmd_reconcile_drain() {
  local deadline announced=0 lost
  rm -f "$RUNDIR/reconcile.shrink"                  # fresh tally of runners lost this drain (see reconcile_stale_runners)
  deadline=$(( $(date +%s) + ${IMAGE_DRAIN_TIMEOUT:-3600} ))
  while :; do
    load_cfg
    [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
    [ "$(count_stale_runners)" -eq 0 ] && break
    [ "$announced" = 0 ] && { log "reconcile: config changed — migrating runners onto it as they go idle"; announced=1; }
    with_fleet_lock wait reconcile_stale_runners
    [ "$(count_stale_runners)" -eq 0 ] && break
    # IMAGE_DRAIN_TIMEOUT=0 means "wait forever" (per the settings help), so only enforce
    # the deadline when it's positive — matching drain_and_recreate's `limit -gt 0` guard.
    [ "${IMAGE_DRAIN_TIMEOUT:-3600}" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ] && { log "reconcile: $(count_stale_runners) runner(s) still on the old config after the drain timeout (finishing jobs or wedged in startup) — they'll migrate on their next idle, or Restart the fleet to force it now"; break; }
    sleep 15
  done
  lost="$([ -f "$RUNDIR/reconcile.shrink" ] && grep -c . "$RUNDIR/reconcile.shrink" 2>/dev/null || echo 0)"
  if [ "$announced" = 1 ]; then
    if [ "${lost:-0}" -gt 0 ]; then
      if [ "$(count_stale_runners)" -eq 0 ]; then
        log "reconcile: migration finished but $lost runner(s) were removed without a replacement — Start/Restart the fleet to restore capacity"
      else
        log "reconcile: migration incomplete, and $lost runner(s) were also removed without a replacement — Start/Restart the fleet to restore capacity"
      fi
    elif [ "$(count_stale_runners)" -eq 0 ]; then
      log "reconcile: fleet is now on the current config"
    fi
  fi
  rm -f "$RUNDIR/reconcile.shrink"
}

# Kick off the drain detached so the Settings Apply returns immediately (recycling is
# slow). Safe no-op when nothing is stale (the drain exits on the first count). Output
# shows in the Apply progress frame — human text, not JSON.
cmd_reconcile_config() {
  nohup "$0" reconcile-drain >>"$RUNDIR/autoscale.log" 2>&1 &
  local msg="Configuration saved. Any runner on a previous config will migrate as it goes idle (busy jobs finish first)."
  # A NETWORK_ISOLATION change applies per-runner only as each recycles — so running
  # jobs keep their OLD network until they finish. Say so plainly: a gradual, background
  # migration of a security-isolation setting can otherwise read as immediate enforcement.
  [ "$NETWORK_ISOLATION" != off ] && msg="$msg  NOTE: network isolation ($NETWORK_ISOLATION) takes effect on each runner only as it recycles — running jobs keep their current network until they finish. Restart the fleet to enforce it on every runner immediately."
  echo "$msg"
}

cmd_start() {
  [ -z "$ACCESS_TOKEN" ] && { err "no GitHub token configured (set it in the web UI). Use 'validate' to test provisioning without one."; return 1; }
  rm -f "$SECURITY_CACHE"                       # force a fresh public-repo check on an explicit Start
  local secp; secp="$(public_repo_problem)"
  [ -n "$secp" ] && err "SECURITY: $secp"       # warn, do not block (operator's call)
  provision_preflight || return 1               # cache-root guard + dirs/network/mirror/firewall/registry
  # If NETWORK_ISOLATION changed while the fleet was up, existing runners are still
  # on the old network — they must be recreated so the new mode actually applies (a
  # half-isolated fleet is a false sense of security). Do this in the BACKGROUND: a
  # network change bumps the confgen fingerprint, so the detached reconcile drain
  # migrates each stale runner onto the new network as it goes idle (running jobs
  # finish first), exactly like a Settings Apply. Draining inline here would block
  # this synchronous Start request under the fleet lock for up to IMAGE_DRAIN_TIMEOUT
  # (hours) while a busy runner finishes. Runners already on the right network match
  # and are left untouched, so a normal Start migrates nothing.
  local c need_migrate=0
  for c in $(managed_names); do
    [ -n "$c" ] && ! on_expected_network "$c" && { need_migrate=1; break; }
  done
  [ "$need_migrate" = 1 ] && { log "network mode changed -> migrating runners onto the new network in the background as they go idle"; nohup "$0" reconcile-drain >>"$RUNDIR/autoscale.log" 2>&1 & }
  # bring back any runners Unraid/Docker left exited (array stop, daemon restart)
  start_stopped_managed
  # with autoscaling on, start the floor (MIN) and let the daemon grow to demand
  local startn="$RUNNER_COUNT"
  [ "$AUTOSCALE" = "true" ] && startn="$AUTOSCALE_MIN"
  local i
  for i in $(seq 1 "$startn"); do start_one "$i"; done
  log "fleet up: $(managed_names | wc -l) runner(s)"
  [ "$AUTOSCALE" = "true" ] && autoscale_start
  [ "$IMAGE_AUTOUPDATE" = "true" ] && imageupdate_start
}

# Tear down a runner: graceful stop, remove the container, and drop its DinD
# data root (the per-runner /var/lib/docker bind dir created in build_args) so
# the pool is reclaimed instead of leaking a tree per retired runner.
remove_runner() {
  local c="$1"
  [ -n "$c" ] || return 0                      # never let an empty name make the rm below target docker/
  deregister_runner_api "$c"                  # host-side (PAT stays off the container)
  docker stop -t 30 "$c" >/dev/null 2>&1
  docker rm "$c" >/dev/null 2>&1
  # $c is a managed container name (ci-runner-N) — no '/' or '..'; path stays under our docker/ subtree.
  [ -n "$CACHE_ROOT" ] && rm -rf "$CACHE_ROOT/docker/$c" 2>/dev/null || true
}

# Full teardown: daemons, runner containers, and the shared pull-through mirror.
# Reached from the UI Stop button AND from plugin uninstall (the .plg remove step
# calls 'stop'), so it must leave nothing running. The mirror's on-pool cache dir
# ($CACHE_ROOT/registry-mirror) is intentionally left behind — like the config and
# token — so a later Start rebuilds the container with its cache warm; only the
# container is removed here, not the cached layers.
cmd_stop() {
  autoscale_stop
  imageupdate_stop
  local names; names="$(managed_names)"
  if [ -z "$names" ]; then
    log "no managed runners running"
  else
    echo "$names" | while read -r c; do [ -n "$c" ] && { log "stopping $c (graceful deregister)"; remove_runner "$c"; }; done
  fi
  # drop the shared image-cache container so uninstall/Stop don't orphan it
  if docker ps -a --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    log "removing shared image cache ($MIRROR_NAME)"
    docker rm -f "$MIRROR_NAME" >/dev/null 2>&1 || true
  fi
  # tear down the strict-mode egress rules and the now-empty dedicated network
  firewall_clear
  if [ "$NETWORK_ISOLATION" != "off" ] && docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1; then
    log "removing isolated runner network ($RUNNER_NETWORK)"
    docker network rm "$RUNNER_NETWORK" >/dev/null 2>&1 || true
  fi
}

cmd_scale() {
  local target="$1"
  # Server-side validate + clamp. The form's max="20" is presentation-only, so a
  # crafted POST (n=99999) would otherwise drive an unbounded provisioning loop —
  # a container + a minted GitHub registration token per iteration (host / API
  # exhaustion). The autoscale path is already bounded by AUTOSCALE_MAX; bound the
  # manual path with a hard ceiling too.
  case "$target" in ''|*[!0-9]*) err "scale target must be a non-negative integer"; return 1 ;; esac
  local HARD_MAX=64
  [ "$target" -gt "$HARD_MAX" ] && { log "scale: clamping requested $target to hard max $HARD_MAX"; target=$HARD_MAX; }
  # Guard the cache-root shape BEFORE ensure_dirs runs mkdir/chown under it — on every
  # scale path (down/same, not just up), so an unsafe CACHE_ROOT never gets provisioned.
  crf_safe_cache_root >/dev/null 2>&1 || { err "refusing to scale: CACHE_ROOT ($CACHE_ROOT) is unsafe — point it at a dedicated subdir under /mnt/<pool>, not a bare pool/disk/share root or system dir"; return 1; }
  ensure_dirs; registry_login
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

cmd_status() {
  local names; names="$(managed_names)"
  printf "%-22s %-10s %-8s %-10s %s\n" "NAME" "STATE" "PHASE" "CPU/MEM" "IMAGE"
  [ -z "$names" ] && { echo "(no managed runners)"; return 0; }
  echo "$names" | while read -r c; do
    [ -z "$c" ] && continue
    local st; st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    local cpus mem; cpus="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$c" 2>/dev/null)"
    mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$c" 2>/dev/null)"
    printf "%-22s %-10s %-8s %-10s %s\n" "$c" "$st" "$(runner_state "$c")" "$((cpus/1000000000))c/$((mem/1024/1024/1024))g" "$(effective_image)"
  done
}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }
# JSON-encode stdin as a string literal (with surrounding quotes), preserving newlines
# as \n — for multi-line log payloads where json_escape's control-char stripping would
# collapse the log into one line.
json_string() {
  local str; str="$(cat)"
  str="${str//\\/\\\\}"; str="${str//\"/\\\"}"
  str="${str//$'\t'/\\t}"; str="${str//$'\r'/\\r}"; str="${str//$'\n'/\\n}"
  str="$(printf '%s' "$str" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$str"
}

cmd_image_info_json() {
  # Image facts for the settings page's Runner image tab: existence, id, age,
  # size, base image, and how many managed runners currently run on it.
  local img; img="$(effective_image)"
  local id; id="$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)"
  if [ -z "$id" ]; then
    echo "{\"exists\":false,\"image\":\"$(echo "$img"|json_escape)\",\"source\":\"$(echo "$IMAGE_SOURCE"|json_escape)\"}"
    return 0
  fi
  local created size; created="$(docker image inspect -f '{{.Created}}' "$img")"
  size="$(docker image inspect -f '{{.Size}}' "$img")"
  local df="$CFGDIR/Dockerfile"
  [ -f "$df" ] || df="/usr/local/emhttp/plugins/$PLUGIN/default.Dockerfile"
  local base; base="$(grep -m1 '^FROM ' "$df" 2>/dev/null | awk '{print $2}')"
  local inuse=0 c cid
  for c in $(managed_names); do
    cid="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
    [ "$cid" = "$id" ] && inuse=$((inuse+1))
  done
  echo "{\"exists\":true,\"image\":\"$(echo "$img"|json_escape)\",\"id\":\"$(echo "$id" | cut -c8-19)\",\"created\":\"$created\",\"size_mb\":$(( ${size:-0}/1024/1024 )),\"base\":\"$(echo "$base"|json_escape)\",\"in_use\":$inuse,\"dockerfile\":\"$(echo "$df"|json_escape)\",\"source\":\"$(echo "$IMAGE_SOURCE"|json_escape)\"}"
}

# "1.5GiB" / "512MiB" / "900kB" -> integer MiB (docker stats human units)
to_mib() {
  echo "$1" | awk '{
    v=$0; sub(/[A-Za-z]+$/,"",v); u=$0; sub(/^[0-9.]+/,"",u);
    if (u ~ /^G/) v*=1024; else if (u ~ /^k/ || u ~ /^K/) v/=1024; else if (u ~ /^B/) v/=1048576;
    printf "%d", v }'
}

cmd_queued_refresh() {
  # Sum queued workflow runs across GH_REPOS into a cache file. Invoked in the
  # background from cmd_queued_json so the UI poll never blocks on 20+ curls.
  [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  [ -n "$ACCESS_TOKEN" ] || { echo "$(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  local total=0 got=0 r n body tmpd i=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "$(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  gh_fetch_all "/actions/runs?status=queued&per_page=1" "$tmpd"
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    i=$((i+1)); body="$(cat "$tmpd/$i" 2>/dev/null)"
    case "$body" in *'"total_count"'*) got=1 ;; esac
    n="$(printf '%s' "$body" | grep -m1 -oE '"total_count":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
    total=$(( total + ${n:-0} ))
  done
  rm -rf "$tmpd"
  # total=-1 signals "unavailable" (no token / every repo query failed) so the UI
  # shows a dash instead of a confident "0 queued" — same sentinel as stats/usage.
  [ "$got" = "1" ] || total=-1
  echo "$(date +%s) $total" > "$RUNDIR/queued.cache"
}

# Warm dependency caches under CACHE_ROOT — safe to clear even while runners are
# up (worst case is a cache miss, not a broken job). Deliberately EXCLUDES work/
# and docker/, which hold running runners' live workspaces and DinD data.
CACHE_PKG_DIRS="cargo-registry cargo-git sccache npm yarn pnpm-store ms-playwright"

# Resolve + validate CACHE_ROOT for destructive/expensive ops (rm -rf in
# cmd_prune_cache / cmd_cache_clear_pkg, chown -R in ensure_dirs). realpath -m
# collapses ../ . and trailing slashes lexically (target need not exist) so the guard
# checks the REAL location, not the raw string. CACHE_ROOT must be a dedicated
# SUBDIRECTORY under a pool/disk — /mnt/<mount>/<subdir> — never a bare mount root: a
# pool root (/mnt/cache), an array disk (/mnt/disk1), a UD device (/mnt/disks), or a
# share root (/mnt/user) all hold the operator's OTHER data (appdata, VM vdisks,
# docker.img, unrelated shares), so rm -rf / chown -R must never target one. The
# legacy shipped default /mnt/github-runner (a dedicated pool) is grandfathered so
# already-configured installs keep working. Echoes the canonical root on success; a
# reason on stderr and returns 1 otherwise.
crf_safe_cache_root() {
  local root
  root="$(realpath -m -- "$CACHE_ROOT" 2>/dev/null)" || { echo unresolvable >&2; return 1; }
  [ "$root" = "/mnt/github-runner" ] && { printf '%s' "$root"; return 0; }   # legacy default — grandfathered
  # System dirs and FUSE user-share roots are always unsafe.
  case "$root" in
    ""|"/"|"/mnt" \
    |"/mnt/user"|"/mnt/user"/*|"/mnt/user0"|"/mnt/user0"/* \
    |"/boot"*|"/usr"*|"/etc"*|"/var"*|"/root"*|"/bin"*|"/sbin"*|"/lib"*)
      echo unsafe >&2; return 1 ;;
  esac
  # Require a dedicated subdirectory, never a bare mount root. Unassigned Devices,
  # remote (SMB/NFS) mounts, and addons expose each device/share as
  # /mnt/<container>/<name>, where that <name> level is ITSELF a mount root holding
  # the operator's data — so for those containers require one level deeper
  # (e.g. /mnt/disks/<dev>/<subdir>), not just /mnt/disks/<dev>. For pools and array
  # disks, /mnt/<pool>/<subdir> (>=2 levels) is the dedicated subdir.
  case "$root" in
    /mnt/disks/*/*|/mnt/remotes/*/*|/mnt/addons/*/*) printf '%s' "$root"; return 0 ;;
    /mnt/disks/*|/mnt/remotes/*|/mnt/addons/*)
      echo "device/remote mount root (point CACHE_ROOT at a subdirectory under it, e.g. ${root%/}/github-runner)" >&2; return 1 ;;
    /mnt/*/*) printf '%s' "$root"; return 0 ;;
    /mnt/*)   echo "bare-mount-root (point CACHE_ROOT at a subdirectory, e.g. /mnt/<pool>/github-runner)" >&2; return 1 ;;
    *)        echo not-under-mnt >&2; return 1 ;;
  esac
}

# Resolve a CACHE_MOUNTS host subdir against the (canonical) cache root and confirm
# it stays UNDER that root — rejecting `../` traversal or absolute paths in the
# space-separated, web-settable CACHE_MOUNTS list before they reach mkdir/chown -R
# (ensure_dirs) or a bind mount into every runner (build_args). Echoes the safe
# absolute path on success; returns 1 (caller logs + skips the entry) otherwise.
crf_safe_mount_subdir() {
  local root real
  root="$(realpath -m -- "$CACHE_ROOT" 2>/dev/null)" || return 1
  real="$(realpath -m -- "$CACHE_ROOT/$1" 2>/dev/null)" || return 1
  case "$real" in "$root"/*) printf '%s' "$real"; return 0 ;; *) return 1 ;; esac
}

cmd_cache_usage_refresh() {
  # du can be slow on a multi-GB cache, so this runs detached and the result is
  # cached; the UI reads the cache and only triggers a refresh when it is stale.
  local root total=0 pkg=0 d n
  root="$(crf_safe_cache_root 2>/dev/null)" || { echo "$(date +%s) -1 0" > "$RUNDIR/cache-usage.cache"; return 0; }
  [ -d "$root" ] || { echo "$(date +%s) 0 0" > "$RUNDIR/cache-usage.cache"; return 0; }
  # Scope the "cache" total to the warm caches — exclude each runner's Docker data
  # root (docker/), the workspace (work/), the image mirror, and DinD logs, which are
  # the fleet's Docker storage (tens of GB per runner), not clearable cache.
  total="$(du -sb --exclude=docker --exclude=work --exclude=registry-mirror --exclude=dind-logs "$root" 2>/dev/null | cut -f1)"; [ -n "$total" ] || total=-1
  for d in $CACHE_PKG_DIRS; do
    [ -d "$root/$d" ] && { n="$(du -sb "$root/$d" 2>/dev/null | cut -f1)"; pkg=$(( pkg + ${n:-0} )); }
  done
  echo "$(date +%s) ${total:--1} ${pkg:-0}" > "$RUNDIR/cache-usage.cache"
}

cmd_cache_usage_json() {
  local now ts total pkg age=999999
  now=$(date +%s)
  if [ -f "$RUNDIR/cache-usage.cache" ]; then
    read -r ts total pkg < "$RUNDIR/cache-usage.cache"
    age=$(( now - ${ts:-0} ))
  fi
  if [ "$age" -gt 300 ]; then
    ( flock -n 9 || exit 0; "$0" cache-usage-refresh ) 9>"$RUNDIR/cache-usage.lock" >/dev/null 2>&1 &
  fi
  echo "{\"total\":${total:--1},\"pkg\":${pkg:-0},\"age\":$age}"
}

cmd_cache_clear_pkg() {
  # Clear ONLY the warm package caches (never work/ or docker/). Reuses the
  # prune-cache root-shape guard so a misconfigured CACHE_ROOT can't wipe a share.
  local root d removed=0 failed=0
  root="$(crf_safe_cache_root)" || { echo "{\"ok\":false,\"error\":\"unsafe cache root\"}"; return 1; }
  for d in $CACHE_PKG_DIRS; do
    [ -d "$root/$d" ] || continue
    if rm -rf "${root:?}/${d:?}/"* 2>/dev/null; then removed=$((removed+1)); else failed=$((failed+1)); fi
  done
  ( "$0" cache-usage-refresh ) >/dev/null 2>&1 &
  if [ "$failed" -gt 0 ]; then
    log "cache clear: $failed dir(s) could not be removed under $root"
    echo "{\"ok\":false,\"error\":\"could not remove $failed dir(s)\",\"cleared\":$removed}"; return 1
  fi
  log "package caches cleared ($removed dir(s)) under $root"
  echo "{\"ok\":true,\"cleared\":$removed}"
}

cmd_stats_refresh() {
  # Tally recent workflow-run conclusions across GH_REPOS. Detached + cached so
  # the per-repo API sweep never blocks the UI (see queued for the pattern).
  [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  [ -n "$ACCESS_TOKEN" ] || { echo "$(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0; }
  local ok=0 fail=0 cancel=0 other=0 total got=0 r body c tmpd i=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "$(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0; }
  gh_fetch_all "/actions/runs?per_page=50" "$tmpd"
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    i=$((i+1)); body="$(cat "$tmpd/$i" 2>/dev/null)"
    case "$body" in *'"workflow_runs"'*) got=1 ;; esac
    while IFS= read -r c; do
      case "$c" in
        *'"success"'*)                              ok=$((ok+1)) ;;
        *'"failure"'*|*'"timed_out"'*|*'"startup_failure"'*) fail=$((fail+1)) ;;
        *'"cancelled"'*)                            cancel=$((cancel+1)) ;;
        *null*) : ;;  # in progress / queued — not a completed run
        ?*)     other=$((other+1)) ;;
      esac
    done <<< "$(echo "$body" | grep -oE '"conclusion": ?(null|"[a-z_]+")')"
  done
  rm -rf "$tmpd"
  # total=-1 signals "stats unavailable" (bad token / API down) vs a real zero.
  if [ "$got" = "1" ]; then total=$((ok+fail+cancel+other)); else total=-1; fi
  echo "$(date +%s) $ok $fail $cancel $other $total" > "$RUNDIR/stats.cache"
}

cmd_stats_json() {
  local now ts ok fail cancel other total age=999999
  now=$(date +%s)
  if [ -f "$RUNDIR/stats.cache" ]; then
    read -r ts ok fail cancel other total < "$RUNDIR/stats.cache"
    age=$(( now - ${ts:-0} ))
  fi
  if [ "$age" -gt 300 ]; then
    ( flock -n 9 || exit 0; "$0" stats-refresh ) 9>"$RUNDIR/stats.lock" >/dev/null 2>&1 &
  fi
  echo "{\"ok\":${ok:-0},\"fail\":${fail:-0},\"cancel\":${cancel:-0},\"other\":${other:-0},\"total\":${total:--1},\"age\":$age}"
}

cmd_queued_json() {
  local now ts count age=999999
  now=$(date +%s)
  if [ -f "$RUNDIR/queued.cache" ]; then
    read -r ts count < "$RUNDIR/queued.cache"
    age=$(( now - ${ts:-0} ))
  fi
  # flock, not a plain lock file: the advisory lock is released by the kernel
  # even on SIGKILL/reboot, so a killed refresh can never wedge future refreshes.
  if [ "$age" -gt 60 ]; then
    ( flock -n 9 || exit 0; "$0" queued-refresh ) 9>"$RUNDIR/queued.lock" >/dev/null 2>&1 &
  fi
  echo "{\"queued\":${count:--1},\"age\":$age}"
}

cmd_recycle() {
  # Deregister, remove, AND recreate one runner with a fresh registration token.
  # Recreating (not just removing) keeps the fleet at its configured size even
  # when autoscaling is off (the default) — otherwise a manual recycle would
  # permanently shrink a fixed-size fleet by one. Mirrors recreate_stopped_runner:
  # the warm caches and DinD data root are pool bind mounts keyed by the same
  # name, so the replacement comes back warm.
  local name="$1" idx
  echo "$name" | grep -qE "^${NAME_PREFIX}-[0-9]+$" || { echo '{"ok":false,"error":"bad name"}'; return 1; }
  idx="$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.index" }}' "$name" 2>/dev/null)"
  [ -z "$idx" ] && idx="${name##*-}"
  # Warn (don't block) if the rest of the fleet is on a different network than the
  # current NETWORK_ISOLATION setting: build_args below uses the LIVE config, so a lone
  # recycle after an isolation change silently places this one runner on the new
  # network while its siblings stay on the old — a half-isolated fleet is a false sense
  # of security. Tell the operator to restart the fleet to make it consistent.
  local other
  for other in $(managed_names); do
    [ -n "$other" ] && [ "$other" != "$name" ] || continue
    on_expected_network "$other" || { log "recycle: WARNING — $other is not on the network the current NETWORK_ISOLATION setting expects; recycling $name will place it on the new network, leaving the fleet split. Restart the fleet to reconcile."; break; }
  done
  # Provision what the replacement needs (cache-root guard, dirs, isolated network,
  # mirror, registry login) BEFORE removing the old container, so a config change
  # since the last Start can't leave the runner removed-but-not-replaced. NOT the
  # firewall: strict-mode egress rules are subnet-keyed, so the replacement rejoins
  # a subnet the fleet's existing rules already cover — a clear+reapply here would
  # briefly drop egress protection for every strict runner (and the rules already
  # protect the new one). Abort with the runner intact if the cache-root guard,
  # registry login, or isolated network is unavailable.
  provision_base || { echo '{"ok":false,"error":"provisioning preflight failed (see log)"}'; return 1; }
  if [ "$NETWORK_ISOLATION" != "off" ] && ! docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1; then
    log "recycle: $name left in place — runner network $RUNNER_NETWORK unavailable"
    echo '{"ok":false,"error":"runner network unavailable"}'; return 1
  fi
  # Recycle deliberately skips the full firewall_clear+reapply cmd_start runs — on a
  # healthy strict fleet the replacement rejoins a subnet the existing rules already
  # cover, and clear+reapply would briefly drop egress for EVERY strict runner. But
  # re-assert when the firewall state is genuinely STALE: (a) strict was enabled since
  # the last Start so no rules exist yet (the replacement would start unprotected), or
  # (b) provision_base recreated the image mirror with a new IP so the strict mirror
  # allow rule now dangles and DinD pull-through would break. Steady state (rules
  # present + current mirror IP still allowed) skips, so there is no per-recycle
  # blackout. firewall_apply reprograms from the live subnet + mirror IP.
  if [ "$NETWORK_ISOLATION" = "strict" ] && command -v iptables >/dev/null 2>&1; then
    local fwrules mip subnet
    fwrules="$(iptables -w -L DOCKER-USER -n 2>/dev/null)"
    mip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MIRROR_NAME" 2>/dev/null)"
    # The current runner-network subnet: provision_base above may have RECREATED
    # $RUNNER_NETWORK (e.g. after a docker network prune) with a fresh auto-allocated
    # subnet. The existing rules are subnet-scoped (-s <cidr>), so if the live subnet
    # no longer appears in them the fleet is sitting on a range the DROP rules were
    # never written for — strict egress is silently unenforced until we reapply.
    subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
    if ! printf '%s' "$fwrules" | grep -qF "$FW_TAG" \
       || { [ -n "$mip" ] && ! printf '%s' "$fwrules" | grep -qF "$mip"; } \
       || { [ -n "$subnet" ] && ! printf '%s' "$fwrules" | grep -qF "$subnet"; }; then
      log "recycle: (re)applying strict egress rules — firewall state was stale"
      firewall_apply
    fi
  fi
  # Validate the REPLACEMENT can be fully provisioned BEFORE touching the old
  # container. build_args assembles everything start_one needs — it mints a fresh
  # GitHub registration token and resolves the image. A cleared token (no
  # ACCESS_TOKEN, which build_args silently skips) or a PAT that can no longer mint
  # one would otherwise let the replacement run unregistered, or fail, only after
  # the old runner is already gone. Guard the empty-token case explicitly, then
  # reuse the validated args so the runner we start is the one we vetted.
  [ -n "$ACCESS_TOKEN" ] || { echo '{"ok":false,"error":"no GitHub token configured"}'; return 1; }
  build_args "$idx" || { echo '{"ok":false,"error":"cannot provision replacement (check the GitHub token)"}'; return 1; }
  # Verify the exact target image while the old runner is still intact. A valid
  # registry login does not prove that a newly configured tag exists, and the
  # built-in image may have been removed since this runner was started.
  local image="${ARGS[${#ARGS[@]}-1]}"
  if [ "$IMAGE_SOURCE" = "remote" ]; then
    docker pull "$image" >/dev/null 2>&1 || {
      log "recycle: $name left in place — could not pull replacement image $image"
      echo '{"ok":false,"error":"cannot pull replacement image"}'; return 1
    }
  elif ! docker image inspect "$image" >/dev/null 2>&1; then
    log "recycle: $name left in place — built-in replacement image $image is unavailable"
    echo '{"ok":false,"error":"built-in replacement image is unavailable"}'; return 1
  fi
  # Stop gracefully first so the runner's inner dockerd can flush its overlay2 /
  # containerd metadata before removal. The DinD data root ($CACHE_ROOT/docker/$name)
  # is preserved and reused WARM by the replacement, so a bare SIGKILL (docker rm -f
  # with no stop) risks handing the new container an unclean data root that fails to
  # mount. Then force-remove.
  docker stop -t 30 "$name" >/dev/null 2>&1
  if ! docker rm -f "$name" >/dev/null 2>&1; then
    log "recycle: docker rm failed for $name"; echo '{"ok":false,"error":"remove failed"}'; return 1
  fi
  deregister_runner_api "$name"
  log "recycling $name (manual, from fleet page)"
  if ! docker run "${ARGS[@]}" >/dev/null 2>&1; then
    log "recycle: $name removed but its replacement failed to start (idx=$idx)"
    echo '{"ok":false,"error":"removed but not recreated"}'; return 1
  fi
  echo '{"ok":true}'
}

cmd_logs_tail() {
  echo "$1" | grep -qE "^${NAME_PREFIX}-[0-9]+$" || return 1
  docker logs --tail "${2:-150}" "$1" 2>&1
}

# base64 a value for the space-delimited cache (empty -> "_" placeholder); _d64 reverses.
_b64() { local v; v="$(printf '%s' "$1" | base64 -w0 2>/dev/null)"; printf '%s' "${v:-_}"; }
_d64() { [ "$1" = "_" ] && return 0; printf '%s' "$1" | base64 -d 2>/dev/null; }
_uu()  { [ "$1" = "_" ] && return 0; printf '%s' "$1"; }

cmd_usage_refresh() {
  # Everything the 5s status poll would otherwise fork per runner, computed ONCE
  # out-of-band: batched docker stats (cpu/mem), the unified phase, and — for busy
  # runners — the job context. cmd_status_json then paints from this cache + a single
  # batched inspect, so the hot path no longer runs docker logs/exec per runner.
  # Line: "name cpu_pct mem_mib phase b64(job) jstarted b64(repo) pr b64(branch) run_id"
  # Also refresh the status-envelope verdicts here, OFF the poll hot path: cache the
  # cache-root (df) warning and keep the public-repo security cache warm, so
  # cmd_status_json never runs df or the per-repo curls inline (and there's no
  # unlocked stampede — this refresher is flock-guarded via usage.lock).
  cache_root_problem > "$RUNDIR/warn.cache" 2>/dev/null
  # Write the public-repo security verdict to a cache the poll reads (empty when
  # there's nothing to warn about, which also clears a stale warning after the config
  # is fixed) — so cmd_status_json never runs the per-repo curls on its own hot path.
  public_repo_problem > "$RUNDIR/sec.cache" 2>/dev/null
  local names; names="$(managed_names)"
  [ -n "$names" ] || { : > "$RUNDIR/usage.cache"; return 0; }
  local statsraw
  # shellcheck disable=SC2086  # $names is intentionally word-split into one arg per runner
  statsraw="$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' $names 2>/dev/null)"
  : > "$RUNDIR/usage.cache.tmp"
  local c
  for c in $names; do
    [ -z "$c" ] && continue
    local srow cpu="" mem_mib=0
    srow="$(printf '%s\n' "$statsraw" | grep -m1 -- "^${c}|")"
    cpu="$(printf '%s' "$srow" | cut -d'|' -f2 | tr -d '%' | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1)"
    mem_mib="$(to_mib "$(printf '%s' "$srow" | cut -d'|' -f3 | awk -F' / ' '{print $1}')")"
    local phase; phase="$(runner_state "$c")"
    local job="" jstarted="_" jrepo="" jpr="_" jbranch="" jrun="_"
    if [ "$phase" = "busy" ]; then
      local jline
      jline="$(docker logs --timestamps --tail 60 "$c" 2>&1 | grep 'Running job: ' | tail -1 | tr -d '\r')"
      job="${jline##*Running job: }"
      jstarted="$(echo "$jline" | awk '{print $1}' | grep -oE '^[0-9T:.Z-]+' | head -1)"; jstarted="${jstarted:-_}"
      local jenv jref
      jenv="$(docker exec "$c" sh -c 'for p in /proc/[0-9]*/environ; do if tr "\0" "\n" < $p 2>/dev/null | grep -q "^GITHUB_REPOSITORY="; then tr "\0" "\n" < $p | grep -E "^GITHUB_(REPOSITORY|RUN_ID|REF_NAME)="; break; fi; done' 2>/dev/null)"
      if [ -n "$jenv" ]; then
        jrepo="$(echo "$jenv" | grep '^GITHUB_REPOSITORY=' | head -1 | cut -d= -f2)"
        jrun="$(echo "$jenv" | grep '^GITHUB_RUN_ID=' | head -1 | cut -d= -f2 | grep -oE '^[0-9]+' | head -1)"; jrun="${jrun:-_}"
        jref="$(echo "$jenv" | grep '^GITHUB_REF_NAME=' | head -1 | cut -d= -f2-)"
        if echo "$jref" | grep -qE '^[0-9]+/merge$'; then jpr="${jref%%/merge*}"; else jbranch="$jref"; fi
      fi
    fi
    printf '%s %s %s %s %s %s %s %s %s %s\n' "$c" "${cpu:-0}" "${mem_mib:-0}" "$phase" \
      "$(_b64 "$job")" "$jstarted" "$(_b64 "$jrepo")" "$jpr" "$(_b64 "$jbranch")" "$jrun" >> "$RUNDIR/usage.cache.tmp"
  done
  mv "$RUNDIR/usage.cache.tmp" "$RUNDIR/usage.cache" 2>/dev/null
}

cmd_status_json() {
  local names; names="$(managed_names)"
  # Per-runner cpu/mem/phase/job all come from a background-refreshed cache (see
  # cmd_usage_refresh) so this 5s-per-tab call makes just TWO docker calls total (the
  # `docker ps` in managed_names + one batched inspect for live state and resource
  # limits), never per runner; trigger a cache refresh when stale.
  local usage="" uage=999 nowu
  nowu=$(date +%s)
  if [ -f "$RUNDIR/usage.cache" ]; then
    usage="$(cat "$RUNDIR/usage.cache" 2>/dev/null)"
    uage=$(( nowu - $(stat -c %Y "$RUNDIR/usage.cache" 2>/dev/null || echo 0) ))
  fi
  # Trigger the background refresh whenever the cache is stale — even with an EMPTY
  # fleet, so the cache-root (df) and public-repo security warnings stay fresh during
  # first-time setup (before any runner exists), which is exactly when they matter.
  # Decouple the refresh cadence from the 5s poll for LARGE fleets: cmd_usage_refresh
  # runs one `docker exec` per runner (runner_state), so re-firing every poll would
  # saturate the daemon at scale. Small fleets stay snappy (4s); fleets above the UI's
  # 20-runner max throttle to ~9s, trading slightly staler cpu/mem bars for roughly
  # half the background docker load.
  local rthresh=4; [ "$(printf '%s\n' "$names" | grep -c .)" -gt 20 ] && rthresh=9
  if [ "$uage" -gt "$rthresh" ]; then
    ( flock -n 9 || exit 0; "$0" usage-refresh ) 9>"$RUNDIR/usage.lock" >/dev/null 2>&1 &
  fi
  # ONE batched inspect for the whole fleet's live state + cpu/mem limits (perf: was
  # three separate docker inspects per runner). {{.Name}} carries a leading '/'.
  local inspraw="" cur_gen stalec=0
  cur_gen="$(crf_confgen)"
  # shellcheck disable=SC2086  # $names is intentionally word-split into one arg per runner
  [ -n "$names" ] && inspraw="$(docker inspect -f '{{.Name}}|{{.State.Status}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.Memory}}|{{index .Config.Labels "net.unraid.ci-runner-farm.confgen"}}' $names 2>/dev/null)"
  local out="["; local first=1
  for c in $names; do
    [ -z "$c" ] && continue
    local irow st cpus mem cgen stale=false
    # {{.Name}} carries a leading '/', so field 1 is "/name"; split the pipe-delimited
    # inspect row with one read builtin instead of three cut subshells per runner.
    irow="$(printf '%s\n' "$inspraw" | grep -m1 -E "^/?${c}\|")"
    IFS='|' read -r _ st cpus mem cgen <<< "$irow"
    # A RUNNING runner whose baked-config fingerprint differs from the current cfg predates
    # a config change; the reconciler migrates it as it goes idle. Surface the count for the UI.
    [ "$st" = running ] && [ "$cgen" != "$cur_gen" ] && { stale=true; stalec=$((stalec+1)); }
    # phase + cpu/mem usage + job context: all from the background cache line
    # "name cpu mem phase b64(job) jstarted b64(repo) pr b64(branch) run_id".
    local urow phase="starting" cpu_pct=-1 mem_used_mib=-1
    local job="" jstarted="" jrepo="" jpr="" jbranch="" jrun=""
    urow="$(printf '%s\n' "$usage" | grep -m1 -- "^${c} ")"
    if [ -n "$urow" ]; then
      # shellcheck disable=SC2086  # deliberate positional split of the fixed cache line
      set -- $urow
      cpu_pct="$2"; mem_used_mib="$3"; phase="$4"
      job="$(_d64 "$5" | json_escape)"; jstarted="$(_uu "$6")"
      jrepo="$(_d64 "$7" | json_escape)"; jpr="$(_uu "$8")"
      jbranch="$(_d64 "$9" | json_escape)"; jrun="$(_uu "${10}")"
    fi
    case "$cpu_pct" in ''|*[!0-9.-]*) cpu_pct=-1 ;; esac
    case "$mem_used_mib" in ''|*[!0-9-]*) mem_used_mib=-1 ;; esac
    case "$jpr" in *[!0-9]*) jpr="" ;; esac
    case "$jrun" in *[!0-9]*) jrun="" ;; esac
    [ $first -eq 0 ] && out+=","
    out+="{\"name\":\"$(echo "$c"|json_escape)\",\"state\":\"${st:-unknown}\",\"phase\":\"$phase\",\"job\":\"${job}\",\"job_started\":\"${jstarted}\",\"repo\":\"${jrepo}\",\"pr\":\"${jpr}\",\"branch\":\"${jbranch}\",\"run_id\":\"${jrun}\",\"cpus\":$(( ${cpus:-0}/1000000000 )),\"mem_gb\":$(( ${mem:-0}/1024/1024/1024 )),\"cpu_pct\":${cpu_pct:-0},\"mem_used_mib\":${mem_used_mib:-0},\"stale\":${stale}}"
    first=0
  done
  out+="]"
  local as="off"; [ "$AUTOSCALE" = "true" ] && as="$(autoscale_status)"
  local iu="off"; [ "$IMAGE_AUTOUPDATE" = "true" ] && iu="$(imageupdate_status) (every $((IMAGE_AUTOUPDATE_INTERVAL/60))m)"
  local warn; warn="$(cat "$RUNDIR/warn.cache" 2>/dev/null | json_escape)"
  # Read the security verdict from cache (written by cmd_usage_refresh) — never call
  # public_repo_problem inline here: on a cold/expired cache that would run the
  # per-repo GitHub curls on the poll's own response path and stall it.
  local sec; sec="$(cat "$RUNDIR/sec.cache" 2>/dev/null | json_escape)"
  echo "{\"count\":$(echo "$names" | grep -c . ),\"configured\":${RUNNER_COUNT},\"token\":$([ -n "$ACCESS_TOKEN" ] && echo true || echo false),\"autoscale\":\"${as} [${AUTOSCALE_MIN}-${AUTOSCALE_MAX}, buffer ${AUTOSCALE_MIN_IDLE}]\",\"image_autoupdate\":\"$(echo "$iu" | json_escape)\",\"warning\":\"${warn}\",\"security\":\"${sec}\",\"stale\":${stalec},\"runners\":${out}}"
}

# Aggregate-only status for the Main -> Dashboard nchan widget: {count,up,busy,idle}.
# Deliberately OMITS the per-runner repo/branch/pr/run_id/job detail that status-json
# carries: the nchan "/sub/<channel>" endpoint is served by Unraid's nginx WITHOUT the
# webGUI login (nchan_authorize_request is commented out in stock locations.conf), so a
# payload pushed there is readable by any client that can reach the box — we must not
# broadcast private repo/job metadata to the whole LAN. The widget only renders these
# counts anyway. One batched inspect + the shared usage cache; triggers the same
# background refresh as status-json so busy/idle stay fresh when only the tile is open.
cmd_dashboard_json() {
  local names up=0 busy=0 idle=0 c st ph usage uage nowu inspraw rthresh
  names="$(managed_names)"
  nowu=$(date +%s); uage=999
  [ -f "$RUNDIR/usage.cache" ] && uage=$(( nowu - $(stat -c %Y "$RUNDIR/usage.cache" 2>/dev/null || echo 0) ))
  rthresh=4; [ "$(printf '%s\n' "$names" | grep -c .)" -gt 20 ] && rthresh=9
  [ "$uage" -gt "$rthresh" ] && ( flock -n 9 || exit 0; "$0" usage-refresh ) 9>"$RUNDIR/usage.lock" >/dev/null 2>&1 &
  usage="$([ -f "$RUNDIR/usage.cache" ] && cat "$RUNDIR/usage.cache" 2>/dev/null)"
  # shellcheck disable=SC2086  # $names is intentionally word-split into one arg per runner
  [ -n "$names" ] && inspraw="$(docker inspect -f '{{.Name}}|{{.State.Status}}' $names 2>/dev/null)"
  for c in $names; do
    [ -n "$c" ] || continue
    st="$(printf '%s\n' "$inspraw" | grep -m1 -E "^/?${c}\|" | cut -d'|' -f2)"
    [ "$st" = running ] || continue
    up=$((up+1))
    ph="$(printf '%s\n' "$usage" | grep -m1 -- "^${c} " | awk '{print $4}')"
    case "$ph" in busy) busy=$((busy+1)) ;; idle) idle=$((idle+1)) ;; esac
  done
  printf '{"count":%s,"up":%s,"busy":%s,"idle":%s}\n' "$(printf '%s\n' "$names" | grep -c .)" "$up" "$busy" "$idle"
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
  local NO_REGISTER=1               # validate swaps the entrypoint for a sleep — never registers
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
  [ -n "$name" ] && [ -n "$CACHE_ROOT" ] && rm -rf "$CACHE_ROOT/docker/$name" 2>/dev/null || true
  log "validate: OK (container removed). Provisioning mechanics verified on this host."
}

# Clear the plugin's caches under CACHE_ROOT. Two independent safeguards: (1) the
# root must pass crf_safe_cache_root — a dedicated subdir under a pool/disk, never a
# bare pool/disk/share root or system dir; and (2) even then we delete ONLY the
# subdirectories this plugin creates, never a wholesale "$root"/* glob — so a
# mis-pointed root can't take out unrelated data that shares the pool.
cmd_prune_cache() {
  # Guard + canonicalize the root, then delete ONLY the subdirectories THIS plugin
  # creates under it — the warm package caches, each runner's DinD data root +
  # workspace, the image mirror, the DinD logs, and the generated daemon config.
  # NEVER a bare "$root"/* glob: even if CACHE_ROOT is somehow mis-pointed at a
  # shared location, prune then cannot wipe unrelated data (appdata, VMs, other
  # shares) that happens to sit alongside our subdirs on the same pool.
  local root d m dirs removed=0
  root="$(crf_safe_cache_root)" || { err "refusing to prune-cache: CACHE_ROOT='$CACHE_ROOT' is unsafe (system dir, share/pool root, or unresolvable — point it at /mnt/<pool>/<subdir>)"; return 1; }
  dirs="docker work dind-logs registry-mirror $CACHE_PKG_DIRS"
  for m in $CACHE_MOUNTS; do dirs="$dirs ${m%%:*}"; done
  for d in $dirs; do
    case "$d" in ''|.|..|*/*) continue ;; esac   # simple child names only — never a path/traversal
    [ -e "$root/$d" ] && { rm -rf "${root:?}/${d:?}" && removed=$((removed+1)); }
  done
  rm -f "${root:?}/dind-daemon.json" 2>/dev/null
  log "cache pruned ($removed dir(s)) under $root"
}

# --- Runner-image build orchestration. The engine owns the flock/launch/liveness
#     state machine (previously inlined in exec.php); exec.php now just runs the verb. ---

# Start a build serialized by an flock, reporting success only once the lock is held.
# Open fd 9 on the lock, take it non-blocking, branch on the exit code: 0 = won ->
# truncate the log HERE (before returning, so a poll can't read a prior build's
# __BUILD_RC__) then run the build in a nohup'd child that INHERITS fd 9 (holding the
# lock for the whole build, released only when that child exits — even on SIGKILL);
# 1 = held; anything else (flock missing / unwritable flash) -> launch error.
cmd_build_async() {
  # Log + lock on tmpfs (RUNDIR), NOT flash: a docker build streams thousands of
  # lines and appending each to /boot would hammer the USB stick. The log is only
  # needed for the current session's build, so losing it on reboot is fine.
  local log="$RUNDIR/build.log" lock="$RUNDIR/build.lock" inner
  mkdir -p "$RUNDIR" 2>/dev/null
  exec 9> "$lock" || { echo '{"ok":false,"error":"could not open the build lock (runtime dir not writable?)"}'; return 0; }
  flock -n 9; local rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$log"
    inner="'$0' build-image >> '$log' 2>&1; echo \"__BUILD_RC__=\$?\" >> '$log'"
    nohup sh -c "$inner" </dev/null >/dev/null 2>&1 &
    echo '{"ok":true,"action":"build-image"}'
  elif [ "$rc" -eq 1 ]; then
    echo '{"ok":false,"error":"a build is already running"}'
  else
    echo '{"ok":false,"error":"could not start the build (is flock available and the config dir writable?)"}'
  fi
}

# {ok,running,rc,log} for the current/last build. running = the build-image process is
# live (the [r] bracket-glob keeps this pgrep from matching its own cmdline); rc parses
# from the __BUILD_RC__ sentinel only once the build is no longer running.
cmd_build_status() {
  local log="$RUNDIR/build.log" txt running rc n disp
  txt="$([ -f "$log" ] && tail -n 120 "$log")"
  if pgrep -f '[r]unner-farm.sh build-image' >/dev/null 2>&1; then running=true; else running=false; fi
  rc=null
  if [ "$running" = false ]; then
    n="$(printf '%s' "$txt" | grep -oE '__BUILD_RC__=[0-9]+' | tail -1 | grep -oE '[0-9]+')"
    [ -n "$n" ] && rc="$n"
  fi
  disp="$(printf '%s' "$txt" | grep -v '__BUILD_RC__=')"
  printf '{"ok":true,"running":%s,"rc":%s,"log":%s}\n' "$running" "$rc" "$(printf '%s' "$disp" | json_string)"
}

# {ok,log} — live farm activity for the Fleet log idle state: the autoscale daemon log
# (tmpfs) or boot.log before the daemon ran, minus docker's noisy swap-limit warning.
cmd_farm_log() {
  local as="$RUNDIR/autoscale.log" bt="$CFGDIR/boot.log" src txt
  src="$as"; [ -f "$as" ] || src="$bt"
  txt="$([ -f "$src" ] && tail -n 150 "$src" | grep -v 'swap limit capabilities' | tail -n 60)"
  printf '{"ok":true,"log":%s}\n' "$(printf '%s' "$txt" | json_string)"
}

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

# Called from the plugin install step (which ALSO re-runs on every boot via
# rc.local reinstalling all .plg) AND from the Unraid `docker_started` event hook
# (which fires on an array stop->start or Docker service restart without a
# reboot). It may fire before the array/dockerd are up, so wait for both, then
# bring the fleet up idempotently. The caller detaches it so it never blocks
# install/boot/the event sequence. No-op until a token is configured (a fresh
# install waits for the user); cmd_start restarts exited runners, skips running
# ones, and (re)starts the autoscale daemon, so the fleet self-heals after a
# reboot OR a Docker restart.
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
  # Serialize the actual fleet bring-up behind the same lock every other mutation
  # uses: on a Docker-service restart (no reboot) the autoscale/image daemons may
  # still be alive and ticking, so an unlocked cmd_start here would race them into
  # duplicate 'docker run's. The long readiness wait above stays OUTSIDE the lock.
  with_fleet_lock wait cmd_start
}

case "${1:-status}" in
  start)        with_fleet_lock wait cmd_start ;;
  boot-autostart)   cmd_boot_autostart ;;
  stop)         with_fleet_lock wait cmd_stop ;;
  restart)      with_fleet_lock wait cmd_restart ;;
  mirror-up)    with_fleet_lock wait cmd_mirror_up ;;
  scale)        with_fleet_lock wait cmd_scale "${2:?usage: scale <N>}" ;;
  status)       cmd_status ;;
  status-json)  cmd_status_json ;;
  dashboard-json) cmd_dashboard_json ;;
  image-info-json) cmd_image_info_json ;;
  queued-json)  cmd_queued_json ;;
  queued-refresh) cmd_queued_refresh ;;
  cache-usage-json) cmd_cache_usage_json ;;
  cache-usage-refresh) cmd_cache_usage_refresh ;;
  usage-refresh) cmd_usage_refresh ;;
  cache-clear-pkg) cmd_cache_clear_pkg ;;
  stats-json)   cmd_stats_json ;;
  stats-refresh) cmd_stats_refresh ;;
  recycle)      with_fleet_lock wait cmd_recycle "${2:?usage: recycle <name>}" ;;
  reconcile-config) cmd_reconcile_config ;;
  reconcile-drain)  ( flock -w 5 7 || { echo "reconcile: a drain is already running (it re-reads the cfg each pass and will pick up this change) — skipping duplicate" >>"$RUNDIR/autoscale.log"; exit 0; }; cmd_reconcile_drain ) 7>"$RUNDIR/reconcile.lock" ;;
  logs-tail)    cmd_logs_tail "${2:?usage: logs-tail <name> [n]}" "${3:-150}" ;;
  logs)         cmd_logs "${2:-1}" "${3:-100}" ;;
  validate)         cmd_validate ;;
  build-image)      cmd_build_image ;;
  build-async)      cmd_build_async ;;
  build-status)     cmd_build_status ;;
  farm-log)         cmd_farm_log ;;
  prune-cache)      cmd_prune_cache ;;
  autoscale-daemon) autoscale_daemon ;;
  autoscale-tick)   autoscale_tick ;;
  autoscale-start)  autoscale_start ;;
  autoscale-stop)   autoscale_stop ;;
  autoscale-status) autoscale_status ;;
  imageupdate-daemon) imageupdate_daemon ;;
  imageupdate-tick)   imageupdate_tick ;;
  imageupdate-start)  imageupdate_start ;;
  imageupdate-stop)   imageupdate_stop ;;
  imageupdate-status) imageupdate_status ;;
  *) echo "usage: $0 {start|boot-autostart|stop|restart|scale N|status|status-json|logs i|validate|build-image|prune-cache|autoscale-tick|autoscale-start|autoscale-stop|autoscale-status|imageupdate-tick|imageupdate-start|imageupdate-stop|imageupdate-status}"; exit 1 ;;
esac
