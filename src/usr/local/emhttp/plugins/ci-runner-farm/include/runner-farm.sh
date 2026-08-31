#!/bin/bash
###############################################################################
# CI Runner Farm - manage GitHub Actions or GitLab CI runners as Docker
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
#   validate         dry-provision the selected provider to prove its generated
#                    config, mounts, limits, and image, then remove it
#   prune-cache      clear the shared cache root
###############################################################################
set -uo pipefail

PLUGIN="ci-runner-farm"
CFGDIR="${CRF_CFGDIR:-/boot/config/plugins/${PLUGIN}}"
# Ephemeral runtime caches/locks live on tmpfs, not the USB flash (they are
# rewritten every 60-300s while a settings tab is open — a flash-wear antipattern).
RUNDIR="${CRF_RUNDIR:-/var/local/emhttp/${PLUGIN}}"
mkdir -p "$RUNDIR" 2>/dev/null || RUNDIR="$CFGDIR"
HOST_DOCKER_CONFIG="$RUNDIR/docker-auth"
CFG="${CFGDIR}/${PLUGIN}.cfg"
TOKEN_FILE="${CFGDIR}/token"
GITLAB_RUNNER_TOKEN_FILE="${CFGDIR}/gitlab-runner-token"
GITLAB_API_TOKEN_FILE="${CFGDIR}/gitlab-api-token"
GITLAB_CA_FILE="${CFGDIR}/gitlab-ca.crt"
REGISTRY_TOKEN_FILE="${CFGDIR}/registry-token"
MANAGED_LABEL="net.unraid.ci-runner-farm.managed=true"
NAME_PREFIX="ci-runner"

# ---- defaults (overridden by ci-runner-farm.cfg) ---------------------------
CI_PROVIDER="github"                  # github | gitlab (one active provider per farm)
GH_SCOPE="repo"                       # repo | org
GH_OWNER="unraid"
GH_REPOS="unraid/repo-a unraid/repo-b"
RUNNER_GROUP=""
GITLAB_URL="https://gitlab.com"       # GitLab.com or a self-managed base URL
GITLAB_RUNNER_IMAGE="gitlab/gitlab-runner:alpine" # official persistent manager image
GITLAB_PROJECTS=""                    # optional space-separated paths for advisory API telemetry
GITLAB_SHUTDOWN_TIMEOUT="7200"        # graceful SIGQUIT drain before Docker force-stops a manager
GITLAB_ALLOWED_IMAGES=""              # optional space-separated Docker image patterns; empty = GitLab default (all)
GITLAB_ALLOWED_SERVICES=""            # optional space-separated service-image patterns; empty = GitLab default (all)
GITLAB_PULL_POLICY="auto"             # auto | always | if-not-present; auto preserves built-in/remote behavior
GITLAB_SHM_SIZE="0"                   # job/service /dev/shm size in bytes; 0 = Docker default
GITLAB_DIND_IMAGE="docker:27-dind"    # private executor daemon; deliberately not user-configurable yet
RUNNER_COUNT=4
RUNNER_LABELS="self-hosted,unraid,build"
RUNNER_MODE="single"                  # single | pools (provider-neutral classic pools)
RUNNER_POOLS=""                       # semicolon-separated validated V3 pool records
RUNNER_CPUS=""                        # per-runner CPU cap; empty = uncapped (CFS time-shares fairly)
RUNNER_MEMORY="16g"                   # per-runner memory cap (kept: memory isn't time-shared like CPU)
CACHE_ROOT="/mnt/cache/github-runner" # must be a dedicated SUBDIR under a pool/disk, never a bare mount root (see crf_safe_cache_root)
WORK_TMPFS_SIZE="8g"                  # empty => bind workdir to pool instead of RAM
IMAGE_SOURCE="builtin"                # builtin = run the locally-built image; remote = pull IMAGE from a registry
BUILTIN_IMAGE="ci-runner-farm-runner:latest"  # legacy/GitHub tag produced by build-image
GITLAB_BUILTIN_IMAGE="ci-runner-farm-gitlab-job:latest" # GitLab default job-image tag
IMAGE=""                              # remote image ref, used when IMAGE_SOURCE=remote (e.g. ghcr.io/org/img:tag)
EPHEMERAL="false"                     # true => runner deregisters after each job
RUN_AS_ROOT="false"                   # false => jobs run as non-root 'runner' (sudo+docker groups), like
                                      # GitHub-hosted runners. true => jobs run as root (legacy).
ACCESS_TOKEN=""                       # GitHub PAT (repo scope; +admin:org for org; +read:packages if reused for private GHCR). Stays host-side:
                                      # runners get a short-lived registration token, never the PAT itself.
GITLAB_RUNNER_TOKEN=""                # reusable glrt- auth token; written into mode-0600 per-slot config.toml
GITLAB_API_TOKEN=""                   # optional read_api token, host-side telemetry only
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
# ---- autoscaling (live runner state; provider API queue is display-only) -----
AUTOSCALE="false"                     # true => a daemon grows/shrinks the fleet by demand
AUTOSCALE_MIN="2"                     # never go below this many runners
AUTOSCALE_MAX="16"                    # never go above this many
AUTOSCALE_MIN_IDLE="2"                # keep at least this many idle (warm) runners as headroom
AUTOSCALE_STEP="2"                    # add/remove this many per adjustment
AUTOSCALE_INTERVAL="30"              # seconds between checks
AUTOSCALE_IDLE_GRACE="5"             # consecutive over-idle checks before scaling down (anti-flap)
# ---- build-poison self-heal (see heal_poisoned_runners) ----------------------
# Internal cadence/bounds, deliberately not web-settable. The CRF_* environment
# overrides exist for the test harness, not for operators.
POISON_SCAN_INTERVAL="${CRF_POISON_SCAN_INTERVAL:-300}"           # min seconds between failed-job log scans
POISON_SCAN_LOOKBACK="${CRF_POISON_SCAN_LOOKBACK:-1800}"          # only consider workflow runs created this recently
POISON_HEAL_MIN_INTERVAL="${CRF_POISON_HEAL_MIN_INTERVAL:-3600}"  # at most one buildkit reset per slot per hour
# ---- image auto-update: keep the runner image current, roll the fleet --------
IMAGE_AUTOUPDATE="false"             # true => a daemon periodically pulls the runner image and,
                                     # when the digest moves, recreates runners on the new image.
IMAGE_AUTOUPDATE_INTERVAL="1800"     # seconds between update checks (default 30 min)
IMAGE_DRAIN_TIMEOUT="3600"           # max seconds to wait for a busy runner to finish its job
                                     # before leaving it on the old image this cycle (0 = wait forever)
# shellcheck disable=SC2034  # consumed only by RunnerFarmDashboard.page's Cond, never inside this script
DASHBOARD_WIDGET_ENABLE="true"       # show the Main->Dashboard status tile (read only by RunnerFarmDashboard.page's Cond)
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh
. "$SCRIPT_DIR/runner-pools.sh"

# Allowlist of keys the settings page may set. load_cfg only ever assigns these.
CFG_KEYS="CI_PROVIDER GH_SCOPE GH_OWNER GH_REPOS RUNNER_GROUP GITLAB_URL GITLAB_RUNNER_IMAGE GITLAB_PROJECTS GITLAB_SHUTDOWN_TIMEOUT \
GITLAB_ALLOWED_IMAGES GITLAB_ALLOWED_SERVICES GITLAB_PULL_POLICY GITLAB_SHM_SIZE \
RUNNER_COUNT RUNNER_LABELS RUNNER_MODE RUNNER_POOLS \
RUNNER_CPUS RUNNER_MEMORY CACHE_ROOT WORK_TMPFS_SIZE IMAGE_SOURCE IMAGE EPHEMERAL \
RUN_AS_ROOT REGISTRY_SERVER REGISTRY_USERNAME CACHE_MOUNTS SHARE_DOCKER_SOCK DIND \
SHARED_IMAGE_CACHE NETWORK_ISOLATION RUNNER_NETWORK MIRROR_PORT AUTOSCALE AUTOSCALE_MIN \
AUTOSCALE_MAX AUTOSCALE_MIN_IDLE AUTOSCALE_STEP AUTOSCALE_INTERVAL \
AUTOSCALE_IDLE_GRACE IMAGE_AUTOUPDATE IMAGE_AUTOUPDATE_INTERVAL IMAGE_DRAIN_TIMEOUT \
DASHBOARD_WIDGET_ENABLE"

# The subset of the allowlist whose values reach arithmetic contexts ($(( )), seq,
# sleep, integer tests). Bash EVALUATES the contents of a variable used inside
# $(( )), so a cfg value like 'a[$(cmd)]' would not merely be wrong there — it
# would run. Shape-check these at parse time so nothing else has to. Keys whose
# values are legitimately non-integer stay off this list: RUNNER_CPUS (decimal),
# RUNNER_MEMORY and WORK_TMPFS_SIZE (unit-suffixed).
CFG_NUMERIC_KEYS="RUNNER_COUNT MIRROR_PORT AUTOSCALE_MIN AUTOSCALE_MAX AUTOSCALE_MIN_IDLE \
AUTOSCALE_STEP AUTOSCALE_INTERVAL AUTOSCALE_IDLE_GRACE IMAGE_AUTOUPDATE_INTERVAL \
IMAGE_DRAIN_TIMEOUT GITLAB_SHUTDOWN_TIMEOUT GITLAB_SHM_SIZE"

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
    case " $CFG_NUMERIC_KEYS " in *" $key "*)
      case "$val" in
        # A rejected key keeps its built-in default. log() is defined below and
        # load_cfg already runs at source time, so it is not callable here; the
        # key is named but the value is never echoed back.
        ''|*[!0-9]*|0[0-9]*) printf '%s\n' "load_cfg: ignoring non-numeric $key" >&2; continue ;;
      esac ;;
    esac
    printf -v "$key" '%s' "$val"
  done < "$CFG"
}

load_cfg
[ "$CI_PROVIDER" = "gitlab" ] || CI_PROVIDER="github"

validate_runner_mode() {
  pool_config_validate "$RUNNER_MODE" "$RUNNER_POOLS" "$GH_SCOPE" "$CI_PROVIDER" || return 1
  if pool_mode_enabled; then
    [ "$AUTOSCALE" != true ] || { pool_error "Runner pools currently use each pool's fixed capacity; disable global autoscaling."; return 1; }
    [ "$IMAGE_AUTOUPDATE" != true ] || { pool_error "Runner pools require explicit image updates per pool; disable global image auto-update."; return 1; }
  fi
}
read_secret_file() {
  [ -f "$1" ] && cat "$1" 2>/dev/null || true
}
reload_secret_files() {
  # A successful GitLab verification is reusable only within one immutable
  # locked snapshot. Any explicit reload invalidates that process-local cache.
  GITLAB_TOKEN_PROBE_VALIDATED_TARGET=""
  ACCESS_TOKEN="$(read_secret_file "$TOKEN_FILE")"
  GITLAB_RUNNER_TOKEN="$(read_secret_file "$GITLAB_RUNNER_TOKEN_FILE")"
  GITLAB_API_TOKEN="$(read_secret_file "$GITLAB_API_TOKEN_FILE")"
  REGISTRY_TOKEN="$(read_secret_file "$REGISTRY_TOKEN_FILE")"
  # Treat the CA fingerprint as part of the same runtime snapshot. confgen must
  # never combine locked token/config values with a second, live read of a CA
  # file that may have been atomically replaced after fleet.lock was acquired.
  GITLAB_CA_PRESENT=false
  GITLAB_CA_CONTENT=""
  GITLAB_CA_FINGERPRINT="_"
  if [ -f "$GITLAB_CA_FILE" ]; then
    GITLAB_CA_CONTENT="$(cat "$GITLAB_CA_FILE" 2>/dev/null)" \
      || { GITLAB_CA_FINGERPRINT="!"; return 1; }
    GITLAB_CA_PRESENT=true
    GITLAB_CA_FINGERPRINT="$(printf '%s' "$GITLAB_CA_CONTENT" | sha256sum 2>/dev/null | cut -c1-12)"
    [ -n "$GITLAB_CA_FINGERPRINT" ] || { GITLAB_CA_FINGERPRINT="!"; return 1; }
  fi
  return 0
}
reload_secret_files

# Re-read the complete mutable runtime snapshot only after fleet.lock is held.
# Every CLI process loads cfg/secrets before dispatch, so a process queued behind
# a credential-clear action could otherwise resume with an old in-memory token
# and recreate the derived per-slot config that was just scrubbed. Normalize the
# provider on every reload too: long-running daemons re-read the web-written cfg
# repeatedly, not only through the one-time startup normalization above.
reload_locked_snapshot() {
  load_cfg
  [ "$CI_PROVIDER" = "gitlab" ] || CI_PROVIDER="github"
  reload_secret_files || { err "could not take a consistent credential/CA snapshot"; return 1; }
  if command -v pool_base_refresh >/dev/null 2>&1; then pool_base_refresh; fi
}
# PID files live on tmpfs (RUNDIR), not flash: they're pure per-boot runtime state,
# so this both spares the USB stick and means a stale PID can't survive a reboot to
# later match an unrelated reused PID that autoscale_stop would then kill.
AUTOSCALE_PID="${RUNDIR}/autoscale.pid"
IMAGEUPDATE_PID="${RUNDIR}/imageupdate.pid"
BOOT_AUTOSTART_PID="${RUNDIR}/boot-autostart.pid"
RECONCILE_PID="${RUNDIR}/reconcile.pid"
IMAGEUPDATE_PENDING="${RUNDIR}/imageupdate.pending"
SECURITY_CACHE="${RUNDIR}/security-warn.cache"   # cached public-repo warning (TTL below), so the
SECURITY_TTL="300"                               # UI's 5s status poll never hammers the GitHub API

log()  { echo "[ci-runner-farm] $*"; }
err()  { echo "[ci-runner-farm] ERROR: $*" >&2; }
host() { hostname -s; }

# Resolve the IPv4 address used by this Unraid host for its default route. The
# runner receives it under a fixed /etc/hosts alias, so colocated services can
# be reached without putting one farm's machine address into repository config.
# Strict isolation still blocks the resulting host/LAN route in the firewall.
runner_host_service_ipv4() {
  local route ip
  if [ "${CRF_SOURCE_ONLY:-0}" = 1 ]; then
    printf '192.0.2.10\n'
    return 0
  fi
  route="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1)" || return 1
  ip="$(printf '%s\n' "$route" | awk '{ for (i = 1; i <= NF; i++) if ($i == "src" && (i + 1) <= NF) { print $(i + 1); exit } }')"
  case "$ip" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  printf '%s\n' "$ip"
}

# Provider implementations live in adapters. CI_PROVIDER is normalized to the
# two allowlisted names above, so dynamic dispatch cannot resolve an arbitrary
# function. The files contain definitions only and are safe in source-only tests.
PROVIDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/providers"
for provider_file in "$PROVIDER_DIR/github.sh" "$PROVIDER_DIR/gitlab.sh"; do
  [ -r "$provider_file" ] || { err "provider adapter missing: $provider_file"; exit 1; }
  # shellcheck source=/dev/null
  . "$provider_file" || { err "could not load provider adapter: $provider_file"; exit 1; }
done
unset provider_file

provider_call() { "${CI_PROVIDER}_$1" "${@:2}"; }

# Provider helpers. Existing containers predate provider labels, so an absent
# label always means GitHub; this keeps upgrades and mixed-fleet reconciliation
# safe while new GitLab managers are introduced one idle slot at a time.
container_provider() {
  local p
  p="$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.provider" }}' "$1" 2>/dev/null)"
  [ "$p" = "gitlab" ] && echo gitlab || echo github
}

# Resolve one container name to a single immutable Docker ID and validate the
# complete ownership contract from that same inspect result. Destructive UI
# actions must never infer ownership from a ci-runner-N-shaped name: a foreign
# container can legitimately collide with that predictable namespace.
#
# Contract "runner" accepts current fully-labelled GitHub/GitLab slots. The
# managed+index-only GitHub form is the narrow upgrade path for containers made
# by releases that predate provider/role labels; the plugin-owned managed label
# is still mandatory, so an ordinary unlabeled collision is never treated as
# GitHub. Contract "github-validate" is strict because validation containers are
# created by this version and have no legacy form.
owned_container_snapshot() {
  local name="$1" expected_index="$2" contract="$3"
  local raw id managed provider role index confgen actual
  case "$name" in ''|*[!A-Za-z0-9_.-]*) err "unsafe container name: $name"; return 1 ;; esac
  raw="$(docker inspect -f '{{.Id}}|{{ index .Config.Labels "net.unraid.ci-runner-farm.managed" }}|{{ index .Config.Labels "net.unraid.ci-runner-farm.provider" }}|{{ index .Config.Labels "net.unraid.ci-runner-farm.role" }}|{{ index .Config.Labels "net.unraid.ci-runner-farm.index" }}|{{ index .Config.Labels "net.unraid.ci-runner-farm.confgen" }}|{{.Name}}' "$name" 2>/dev/null)" \
    || { err "container not found: $name"; return 1; }
  IFS='|' read -r id managed provider role index confgen actual <<< "$raw"
  [ "$managed" = "<no value>" ] && managed=""
  [ "$provider" = "<no value>" ] && provider=""
  [ "$role" = "<no value>" ] && role=""
  [ "$index" = "<no value>" ] && index=""
  [ "$confgen" = "<no value>" ] && confgen=""
  printf '%s' "$id" | grep -qE '^[0-9a-f]{64}$' \
    || { err "refusing $name: Docker returned an invalid immutable container ID"; return 1; }
  [ "$actual" = "/$name" ] \
    || { err "refusing $name: inspected container name does not match"; return 1; }
  [ "$managed" = true ] \
    || { err "refusing unowned container name collision: $name"; return 1; }
  [ "$index" = "$expected_index" ] \
    || { err "refusing $name: managed slot index label does not match its name"; return 1; }
  case "$confgen" in *[!A-Za-z0-9._-]*) err "refusing $name: invalid config-generation label"; return 1 ;; esac

  case "$contract:$provider:$role" in
    runner:github:runner|runner:gitlab:manager|github-validate:github:validate) ;;
    # Upgrade compatibility for the existing GitHub adapter, which historically
    # stamped managed+index but had no provider/role labels.
    runner::) provider=github; role=runner ;;
    *) err "refusing $name: provider/role ownership labels do not match a $contract container"; return 1 ;;
  esac
  printf '%s|%s|%s|%s|%s\n' "$id" "$provider" "$role" "$index" "$confgen"
}

managed_runner_snapshot() {
  local name="$1" index
  echo "$name" | grep -qE '^ci-runner-([0-9]+|[a-z][a-z0-9-]{0,23}-[0-9]+)$' \
    || { err "unsafe runner slot name: $name"; return 1; }
  index="${name##*-}"
  owned_container_snapshot "$name" "$index" runner
}

provider_token_ready() { provider_call token_ready; }
provider_token_name()  { provider_call token_name; }
builtin_image()        { provider_call builtin_image; }
provider_validate_settings() { provider_call validate_settings; }
provider_public_problem() { provider_call public_repo_problem; }
provider_registry_credentials() { provider_call registry_credentials; }
provider_strict_endpoint() { provider_call strict_endpoint; }
provider_imageupdate_pull() { provider_call imageupdate_pull; }
provider_remote_image_host_pull_required() { provider_call remote_image_host_pull_required; }
provider_prepare_remote_image() { provider_call prepare_remote_image "$@"; }
provider_remote_image_update_allowed() { provider_call remote_image_update_allowed; }
provider_build_poison_scan() { provider_call build_poison_scan; }

container_docker_stopping_timeout() {
  local provider
  provider="$(container_provider "$1")"
  "${provider}_docker_stopping_timeout" "$1"
}
container_docker_stopping() {
  local provider
  provider="$(container_provider "$1")"
  "${provider}_docker_stopping" "$1"
}

managed_names() {
  # Validation containers intentionally carry the managed ownership label too,
  # but they are not fleet slots and their random suffix is not a runner index.
  # Keep every lifecycle loop scoped to canonical numeric slot names.
  local listed
  listed="$(docker ps -a --filter "label=${MANAGED_LABEL}" --format '{{.Names}}')" \
    || { err "could not enumerate managed runner containers"; return 1; }
  printf '%s\n' "$listed" \
    | awk '($0 ~ /^ci-runner-[0-9]+$/ || $0 ~ /^ci-runner-[a-z][a-z0-9-]{0,23}-[0-9]+$/) {print}' \
    | sort -V
}

runner_pool() {
  local value
  if ! pool_mode_enabled; then printf 'default\n'; return 0; fi
  value="$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.pool" }}' "$1" 2>/dev/null)" || return 1
  [ "$value" = '<no value>' ] && value=""
  printf '%s\n' "${value:-default}"
}

BASE_NAME_PREFIX="$NAME_PREFIX"
BASE_RUNNER_LABELS="$RUNNER_LABELS"
BASE_RUNNER_CPUS="$RUNNER_CPUS"
BASE_RUNNER_MEMORY="$RUNNER_MEMORY"
BASE_IMAGE_SOURCE="$IMAGE_SOURCE"
BASE_IMAGE="$IMAGE"
BASE_GITLAB_RUNNER_TOKEN="$GITLAB_RUNNER_TOKEN"

pool_base_refresh() {
  BASE_NAME_PREFIX="ci-runner"
  BASE_RUNNER_LABELS="$RUNNER_LABELS"
  BASE_RUNNER_CPUS="$RUNNER_CPUS"
  BASE_RUNNER_MEMORY="$RUNNER_MEMORY"
  BASE_IMAGE_SOURCE="$IMAGE_SOURCE"
  BASE_IMAGE="$IMAGE"
  BASE_GITLAB_RUNNER_TOKEN="$GITLAB_RUNNER_TOKEN"
}

pool_activate() {
  local pool="${1:-default}" image cpus memory
  CRF_POOL_ID="$pool"
  NAME_PREFIX="$BASE_NAME_PREFIX"
  RUNNER_LABELS="$BASE_RUNNER_LABELS"
  RUNNER_CPUS="$BASE_RUNNER_CPUS"
  RUNNER_MEMORY="$BASE_RUNNER_MEMORY"
  IMAGE_SOURCE="$BASE_IMAGE_SOURCE"
  IMAGE="$BASE_IMAGE"
  GITLAB_RUNNER_TOKEN="$BASE_GITLAB_RUNNER_TOKEN"
  [ "$pool" = default ] && return 0
  pool_mode_enabled || return 1
  RUNNER_LABELS="$(pool_effective_labels "$pool")" || return 1
  cpus="$(pool_cpus "$pool")" || return 1
  memory="$(pool_memory "$pool")" || return 1
  image="$(pool_image "$pool")" || return 1
  [ "$cpus" = inherit ] || RUNNER_CPUS="$cpus"
  [ "$memory" = inherit ] || RUNNER_MEMORY="$memory"
  if [ "$image" = builtin ]; then
    IMAGE_SOURCE=builtin
    IMAGE=""
  else
    IMAGE_SOURCE=remote
    IMAGE="$image"
  fi
  NAME_PREFIX="${BASE_NAME_PREFIX}-${pool}"
  if [ "$CI_PROVIDER" = gitlab ]; then
    local token_file="${CFGDIR}/gitlab-runner-token.${pool}"
    [ -f "$token_file" ] || { err "GitLab pool $pool has no pool-specific runner token"; return 1; }
    GITLAB_RUNNER_TOKEN="$(read_secret_file "$token_file")"
    gitlab_token_ready \
      || { err "GitLab pool $pool has an invalid runner token"; return 1; }
  fi
}

expected_runner_confgen() {
  local pool
  pool="$(runner_pool "$1")" || return 1
  ( pool_activate "$pool" && crf_confgen )
}

pool_tokens_ready() {
  local rec pool
  if ! pool_mode_enabled || [ "$CI_PROVIDER" != gitlab ]; then
    provider_token_ready
    return
  fi
  while IFS= read -r rec; do
    pool="$(printf '%s' "$rec" | cut -d'|' -f2)"
    ( pool_activate "$pool" && gitlab_token_ready ) || return 1
  done < <(pool_records)
}

owned_managed_names() {
  local names c
  names="$(managed_names)" || return 1
  for c in $names; do
    managed_runner_snapshot "$c" >/dev/null || return 1
  done
  printf '%s\n' "$names"
}

current_count() {
  local names
  names="$(owned_managed_names)" || return 1
  printf '%s\n' "$names" | awk 'NF { n++ } END { print n+0 }'
}

runner_state() {
  local c="$1" provider
  provider="$(container_provider "$c")"
  "${provider}_runner_state" "$c"
}
runner_busy() { [ "$(runner_state "$1")" = busy ]; }
busy_count() {
  local b=0 c names
  names="$(managed_names)" || return 1
  for c in $names; do [ -n "$c" ] && runner_busy "$c" && b=$((b+1)); done
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
  provider_call confgen
}
# The config fingerprint a managed runner was created with ('' for runners created before
# this feature existed — they read as stale and migrate on the next reconcile).
runner_confgen() { docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.confgen" }}' "$1" 2>/dev/null; }
# How many running or stopped managed runners predate the current baked config.
# A fail-closed unregister deliberately leaves a stopped manager; it must remain
# visible to the drain instead of letting reconciliation advance through the fleet.
count_stale_runners() {
  local cur c names snapshot id provider role index gen n=0
  names="$(managed_names)" || return 1
  for c in $names; do
    [ -n "$c" ] || continue
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    cur="$(expected_runner_confgen "$c")" || { n=$((n+1)); continue; }
    [ "$gen" = "$cur" ] || n=$((n+1))
  done
  echo "$n"
}

# Effective autoscale floor: AUTOSCALE_MIN, clamped to AUTOSCALE_MAX so a floor
# misconfigured above the ceiling can never bypass the resource cap.
autoscale_floor() { local f="$AUTOSCALE_MIN"; [ "$f" -gt "$AUTOSCALE_MAX" ] && f="$AUTOSCALE_MAX"; echo "$f"; }

# remove up to $1 IDLE runners (highest index first), never below the effective
# floor (MIN clamped to MAX), never busy ones
scale_down_idle() {
  local want="$1" removed=0 c floor provider failed=0 names snapshot id role index gen count
  floor="$(autoscale_floor)"
  names="$(managed_names)" || return 1
  for c in $(printf '%s\n' "$names" | sort -rV); do
    [ "$removed" -ge "$want" ] && break
    count="$(current_count)" || return 1
    [ "$count" -le "$floor" ] && break
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    if "${provider}_scale_down_eligible" "$c"; then
      log "autoscale: removing idle $c"
      if remove_runner "$c" true "$id" "$provider"; then
        removed=$((removed+1))
      else
        err "autoscale: failed to remove idle $c; preserving later slots"
        failed=1
        break
      fi
    fi
  done
  return "$failed"
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
  local c st health provider sock side phase job_container failf failcount
  local names sidecars snapshot id role index gen failed=0
  names="$(managed_names)" || return 1
  for c in $names; do
    [ -n "$c" ] || continue
    snapshot="$(managed_runner_snapshot "$c")" || { failed=1; continue; }
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    st="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)" \
      || { err "autoscale: could not inspect state for owned runner $c"; failed=1; continue; }
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null)" \
      || { err "autoscale: could not inspect health for owned runner $c"; failed=1; continue; }
    if [ "$provider" = "gitlab" ]; then
      # A positively identified executor job always wins over manager/sidecar
      # health. Never destroy a job because its control plane or daemon probe is
      # transiently unavailable.
      if ! job_container="$(gitlab_job_container "$c")"; then
        log "autoscale: retaining $c because its GitLab executor state could not be enumerated"
        failed=1
        continue
      fi
      [ -n "$job_container" ] && { log "autoscale: retaining $c while GitLab job $job_container is active"; continue; }
      if [ "$st" = "running" ]; then
        phase="$(gitlab_runner_state "$c")"
        [ "$phase" = busy ] && { log "autoscale: retaining positively busy GitLab manager $c"; continue; }
      fi
    fi
    if [ "$provider" = "gitlab" ] && [ "$st" = "running" ]; then
      sock="$(gitlab_socket_path "$c")"
      if [ "$sock" != "/var/run/docker.sock" ]; then
        side="$(gitlab_sidecar_name "$c")"
        sidecars="$(docker ps --format '{{.Names}}')" \
          || { err "autoscale: could not enumerate GitLab sidecars for owned runner $c"; failed=1; continue; }
        if ! printf '%s\n' "$sidecars" | grep -qx "$side" \
           || ! docker --host "unix://$sock" info >/dev/null 2>&1; then
          # A single nested-daemon probe can fail during dockerd GC or host I/O.
          # Require two consecutive fleet evaluations before destructive repair;
          # positively detected jobs/busy metrics were already protected above.
          failf="$RUNDIR/gitlab-sidecar-fail.$c"; failcount=0
          [ -f "$failf" ] && read -r failcount < "$failf"
          case "$failcount" in ''|*[!0-9]*) failcount=0 ;; esac
          failcount=$((failcount+1)); printf '%s\n' "$failcount" > "$failf"
          if [ "$failcount" -lt 2 ]; then
            log "autoscale: deferring repair of $c after first private Docker daemon probe failure"
            continue
          fi
          log "autoscale: reaping GitLab manager $c because its private Docker daemon is unavailable"
          st=dead
        else
          rm -f "$RUNDIR/gitlab-sidecar-fail.$c" 2>/dev/null || true
        fi
      fi
    fi
    case "$st" in
      exited|dead)
        log "autoscale: reaping dead runner $c (state=$st)" ;;
      running)
        [ "$health" = "unhealthy" ] || continue
        log "autoscale: reaping unhealthy runner $c (disconnected; health=$health)" ;;
      *) continue ;;
    esac
    if remove_runner "$c" true "$id" "$provider"; then
      rm -f "$RUNDIR/gitlab-sidecar-fail.$c" 2>/dev/null || true
    else
      log "autoscale: failed to remove dead runner $c; will retry"
      failed=1
    fi
  done
  return "$failed"
}

# A runner whose nested dockerd crashed mid-build can be left with dangling
# buildkit lease metadata in its persistent DinD root: every later build on that
# slot fails with `failed to solve: lease "...": not found` while the container
# stays running, healthy, and registered — so it keeps taking (and failing)
# jobs, invisible to reap_dead_runners, which only sees dead containers and
# lost registrations. The provider scan classifies a slot as build-poisoned by
# that exact signature (GitHub reads recent failed-job logs, the only place the
# error is visible — the nested daemon does not log solve failures) and drops a
# poison-pending flag; this pass repairs flagged IDLE slots by stopping the
# container, clearing ONLY the buildkit/ subdir of its DinD root (the warm
# image/layer caches survive), and starting the same container again (runner
# registration persists across stop/start). Conservative by design: busy slots
# are never touched, each slot gets at most one reset attempt per
# POISON_HEAL_MIN_INTERVAL, and a flag whose container was replaced since
# detection is discarded (replacements always start with a fresh DinD root).
# Like the reaper this runs from the autoscale tick under the fleet lock; with
# autoscaling off, an operator recycle remains the repair path.
heal_poisoned_runners() {
  provider_build_poison_scan \
    || err "selfheal: build-poison scan failed; acting on existing flags only"
  local f c snapshot id provider role index gen flagged_id root now last healf failed=0
  for f in "$RUNDIR"/poison-pending.*; do
    [ -e "$f" ] || break
    c="${f##*/poison-pending.}"
    printf '%s' "$c" | grep -qE "^${NAME_PREFIX}-[0-9]+$" || { rm -f "$f"; continue; }
    flagged_id="$(head -1 "$f" 2>/dev/null)"
    if ! snapshot="$(managed_runner_snapshot "$c" 2>/dev/null)"; then
      log "selfheal: dropping poison flag for $c (slot no longer present)"
      rm -f "$f"; continue
    fi
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    [ "$provider" = github ] || { rm -f "$f"; continue; }
    if [ "$flagged_id" != "$id" ]; then
      log "selfheal: dropping poison flag for $c (container replaced since detection)"
      rm -f "$f"; continue
    fi
    healf="$RUNDIR/poison-healed.$c"; last=0
    [ -f "$healf" ] && read -r last < "$healf"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    now="$(date +%s)"
    if [ $((now - last)) -lt "$POISON_HEAL_MIN_INTERVAL" ]; then
      log "selfheal: $c flagged again after a recent buildkit reset; waiting out the per-slot bound"
      continue
    fi
    if runner_busy "$c"; then
      log "selfheal: $c is build-poisoned but busy; deferring its buildkit reset"
      continue
    fi
    root="$(crf_safe_cache_root)" \
      || { err "selfheal: refusing buildkit reset under unsafe CACHE_ROOT '$CACHE_ROOT'"; return 1; }
    # Stamp the ATTEMPT before acting: whatever fails below, this slot cannot
    # be stop/start-cycled more than once per bound interval.
    echo "$now" > "$healf"
    log "selfheal: $c is build-poisoned (dangling buildkit lease) -> stop, clear buildkit metadata, restart"
    provider_stop_owned_runner "$c" "$id" "$provider" \
      || { err "selfheal: could not stop $c for its buildkit reset"; failed=1; continue; }
    if rm -rf "$root/docker/$c/buildkit" 2>/dev/null; then
      rm -f "$f"
    else
      err "selfheal: could not clear $root/docker/$c/buildkit; restarting $c unrepaired"
      failed=1
    fi
    if docker start "$id" >/dev/null 2>&1; then
      log "selfheal: $c restarted with fresh buildkit metadata (image/layer cache preserved)"
    else
      # A slot left stopped is not lost capacity for long: the reaper removes
      # it and the floor refills it with a freshly registered runner.
      err "selfheal: could not restart $c after its buildkit reset; the reaper will replace it"
      failed=1
    fi
  done
  return "$failed"
}

# Read a provider-matching queue cache only while it is inside the same 60-second
# freshness window used by cmd_queued_json. Unknown data must not suppress the
# normal idle-headroom growth decision.
autoscale_queue_depth() {
  local now cache_provider ts count age
  [ -f "$RUNDIR/queued.cache" ] || { printf '%s\n' -1; return 0; }
  now="$(date +%s)"
  read -r cache_provider ts count < "$RUNDIR/queued.cache"
  case "$cache_provider" in
    github|gitlab) ;;
    *) count="$ts"; ts="$cache_provider"; cache_provider=github ;;
  esac
  [ "$cache_provider" = "$CI_PROVIDER" ] || { printf '%s\n' -1; return 0; }
  case "$ts" in ''|*[!0-9]*) printf '%s\n' -1; return 0 ;; esac
  case "$count" in ''|*[!0-9]*) printf '%s\n' -1; return 0 ;; esac
  age=$(( now - ts ))
  [ "$age" -ge 0 ] && [ "$age" -le 60 ] || { printf '%s\n' -1; return 0; }
  printf '%s\n' "$count"
}

# one autoscaling evaluation: keep AUTOSCALE_MIN_IDLE warm runners, within [MIN,MAX]
autoscale_tick() {
  [ "$AUTOSCALE" = "true" ] || return 0
  reap_dead_runners || return 1  # drop dead containers first so idle accounting is real
  local cur=0 busy=0 idle=0 statef over target queue_target qdepth
  # GitHub retains its original cur-busy semantics; GitLab counts only explicit
  # idle managers so disconnected/starting slots are not phantom headroom.
  provider_call autoscale_counts \
    || { err "autoscale: could not enumerate and inspect the managed fleet"; return 1; }
  case "$cur:$busy:$idle" in
    *[!0-9:]*) err "autoscale: provider returned invalid fleet counts"; return 1 ;;
  esac
  qdepth="$(autoscale_queue_depth)"
  case "$qdepth" in
    -1|[0-9]|[1-9][0-9]*) ;;
    *) qdepth=-1 ;;
  esac
  statef="${RUNDIR}/autoscale.state"; over=0
  [ -f "$statef" ] && over=$(cat "$statef" 2>/dev/null || echo 0)
  # over feeds $(( over + 1 )) below, which evaluates whatever the file held; a
  # truncated or tampered state file restarts the anti-flap counter instead.
  case "$over" in ''|*[!0-9]*|0[0-9]*) over=0 ;; esac

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
    if [ "$qdepth" -gt 0 ]; then
      queue_target=$(( cur + qdepth ))
      [ "$queue_target" -gt "$target" ] && target="$queue_target"
      [ "$target" -gt "$AUTOSCALE_MAX" ] && target=$AUTOSCALE_MAX
    fi
    log "autoscale: idle=$idle/$cur queued=$qdepth < buffer $AUTOSCALE_MIN_IDLE -> grow to $target"
    cmd_scale "$target" >/dev/null; echo 0 > "$statef"
  elif [ "$idle" -gt $(( AUTOSCALE_MIN_IDLE + AUTOSCALE_STEP )) ] && [ "$cur" -gt "$floor" ]; then
    over=$(( over + 1 )); echo "$over" > "$statef"
    if [ "$over" -ge "$AUTOSCALE_IDLE_GRACE" ]; then
      log "autoscale: idle=$idle/$cur high for $over checks -> shrink by $AUTOSCALE_STEP"
      scale_down_idle "$AUTOSCALE_STEP" || return 1
      echo 0 > "$statef"
    fi
  else
    echo 0 > "$statef"
  fi
  # Self-heal build-poisoned slots after the scale math: healing stop/starts an
  # idle container inside the tick, which would otherwise perturb the idle/busy
  # counts above. Non-fatal so a failed repair never blocks reconciliation.
  heal_poisoned_runners \
    || err "autoscale: one or more build-poisoned runners could not be repaired this tick"
  # Continuous safety net behind the Apply-triggered drain: migrate one runner still on a
  # previous baked config onto the current one (idle only). Also the path that eventually
  # picks up a direct cfg edit, or a runner whose job outlasted the Apply drain timeout.
  # Runs LAST so it never perturbs the scale math above; already under the fleet lock.
  reconcile_stale_runners
}

# long-running loop; re-reads config each tick so UI changes apply live
autoscale_daemon() {
  # Disown any inherited fleet-lock fd. This daemon is nohup'd from cmd_start, which
  # runs under `with_fleet_lock wait` (fd 8 flock HELD) — without this the child would
  # inherit that locked fd and hold the fleet lock for its entire life, so (a) its own
  # `with_fleet_lock try` ticks could never re-acquire it (autoscale silently never
  # runs) and (b) every UI start/stop/scale/recycle would block 20s then fail "fleet
  # busy". Closing fd 8 here releases the inherited lock; with_fleet_lock reopens it
  # fresh per tick. (7/9 closed too, defensively, for any future locked spawn path.)
  exec 8>&- 7>&- 9>&- 2>/dev/null || true
  log "autoscale daemon up (min=$AUTOSCALE_MIN max=$AUTOSCALE_MAX buffer=$AUTOSCALE_MIN_IDLE step=$AUTOSCALE_STEP every ${AUTOSCALE_INTERVAL}s)"
  while true; do
    load_cfg
    reload_secret_files
    [ "$AUTOSCALE" = "true" ] || { log "autoscale disabled -> daemon exit"; rm -f "$AUTOSCALE_PID"; break; }
    with_fleet_lock try autoscale_tick
    sleep "${AUTOSCALE_INTERVAL:-30}"
  done
}

autoscale_start() {
  [ "$AUTOSCALE" = "true" ] || return 0
  autoscale_stop || return 1
  nohup "$0" autoscale-daemon >>"${RUNDIR}/autoscale.log" 2>&1 &
  echo $! > "$AUTOSCALE_PID"
  log "autoscale daemon started (pid $(cat "$AUTOSCALE_PID"))"
}
stop_worker_group() {
  local label="$1" pidfile="$2" pattern="$3" pids i
  pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    # pgrep returns numeric PIDs only. Target the live command line rather than a
    # stale PID file that could have been recycled for an unrelated process.
    kill $pids 2>/dev/null || true
    for i in $(seq 1 20); do
      pgrep -f "$pattern" >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi
  rm -f "$pidfile" 2>/dev/null || {
    err "could not remove $label PID file"
    return 1
  }
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    err "$label worker is still running"
    return 1
  fi
}

autoscale_stop() {
  stop_worker_group "autoscale" "$AUTOSCALE_PID" '[r]unner-farm.sh autoscale-daemon'
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
  provider_imageupdate_pull && changed=0
  if [ "$IMAGE_SOURCE" = "remote" ] && [ -n "$IMAGE" ] \
     && provider_remote_image_host_pull_required \
     && provider_remote_image_update_allowed; then
    before="$(image_id "$img")"
    provider_prepare_remote_image "$img" >/dev/null 2>&1 \
      || { err "image-update: provider image preparation failed"; return 1; }
    after="$(image_id "$img")"
    if [ -n "$after" ] && [ "$before" != "$after" ]; then
      changed=0; log "image-update: $img ${before:-none} -> $after"
    fi
  elif [ "$IMAGE_SOURCE" != "remote" ] || [ -z "$IMAGE" ]; then
    log "image-update: image source is builtin ($img) — nothing to pull; rebuild via build-image to update"
  else
    # GitLab DinD refreshes through the slot daemon. Explicit host-socket
    # An explicit if-not-present policy likewise prohibits this scheduled host pull.
    rm -f "$HOST_DOCKER_CONFIG/config.json" 2>/dev/null || true
    log "image-update: provider job-image pull policy does not permit a scheduled host pull"
  fi
  # keep the shared pull-through mirror image current too (recreate in place if it moved)
  if [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ]; then
    before="$(image_id registry:2)"
    docker pull registry:2 >/dev/null 2>&1
    after="$(image_id registry:2)"
    if [ -n "$after" ] && [ "$before" != "$after" ]; then
      log "image-update: mirror image registry:2 changed -> recreating $MIRROR_NAME"
      mirror_remove_owned || return 1
      ensure_mirror || return 1
    fi
  fi
  return $changed
}

# Drain one runner (wait for its current job to finish), then recreate it on the
# freshly-pulled image. Never interrupts a running job. If it stays busy past
# IMAGE_DRAIN_TIMEOUT, leave it on the old image — the next cycle retries.
drain_and_recreate() {
  local c="$1" waited=0 limit all_names
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
    # Another action may have changed provider settings or removed a credential
    # while this drain deliberately released fleet.lock. Resume only from the
    # snapshot that exists after the lock was reacquired.
    reload_locked_snapshot || return 1
  done
  # Re-holding the lock here. If the runner vanished while we were unlocked (the
  # operator hit Stop/Recycle mid-drain), do NOT recreate it — never resurrect a
  # runner the operator just removed.
  all_names="$(docker ps -a --format '{{.Names}}')" \
    || { err "image-update: could not enumerate Docker containers after reacquiring the fleet lock"; return 1; }
  printf '%s\n' "$all_names" | grep -qx "$c" \
    || { log "image-update: $c no longer present — skipping recreate"; return 0; }
  log "image-update: $c idle -> validating and recycling onto the current provider image"
  if ! cmd_recycle "$c" >/dev/null; then
    log "image-update: validated recycle of $c failed; existing capacity was preserved when possible"
    return 1
  fi
}

# Roll the whole fleet onto the new image, one runner at a time so capacity stays
# up while each drains. Re-reads managed_names each loop (recreated names persist).
imageupdate_rollover() {
  local retry_only="${1:-false}" c names failed=0 pending_tmp final_count
  pending_tmp="$(mktemp "${IMAGEUPDATE_PENDING}.XXXXXX" 2>/dev/null)" \
    || { err "image-update: cannot create rollover retry state"; return 1; }
  if [ "$retry_only" = true ]; then
    names="$([ -f "$IMAGEUPDATE_PENDING" ] && cat "$IMAGEUPDATE_PENDING")"
  else
    if ! names="$(managed_names)"; then
      rm -f "$pending_tmp"
      err "image-update: could not enumerate the managed fleet before rollover"
      return 1
    fi
  fi
  for c in $names; do
    [ -n "$c" ] || continue
    # A manual Stop/Recycle may have removed a previously pending slot. Do not
    # resurrect it merely because an older image-update pass recorded its name.
    docker inspect "$c" >/dev/null 2>&1 || continue
    if [ "$failed" -ne 0 ]; then
      # Stop at the first unsafe slot. Preserve every unattempted name so this
      # pass cannot drain the rest of the fleet after one fail-closed recycle.
      printf '%s\n' "$c" >> "$pending_tmp"
      continue
    fi
    if ! drain_and_recreate "$c"; then
      printf '%s\n' "$c" >> "$pending_tmp"
      failed=1
    fi
  done
  if [ -s "$pending_tmp" ]; then
    if ! mv "$pending_tmp" "$IMAGEUPDATE_PENDING"; then
      rm -f "$pending_tmp"
      err "image-update: could not publish rollover retry state"
      return 1
    fi
    log "image-update: rollover incomplete; $(grep -c . "$IMAGEUPDATE_PENDING") slot(s) will retry next cycle"
  else
    final_count="$(current_count)" || {
      rm -f "$pending_tmp"
      err "image-update: rollover finished but the managed fleet could not be verified"
      return 1
    }
    rm -f "$pending_tmp" "$IMAGEUPDATE_PENDING"
    log "image-update: rollover complete ($final_count runner(s) on $(effective_image))"
  fi
  return "$failed"
}

# One update evaluation. A digest change starts a full roll; any slot that could
# not drain or replace is persisted by name and retried on later ticks even though
# the local image tag has already advanced and a subsequent pull is unchanged.
imageupdate_tick() {
  [ "$IMAGE_AUTOUPDATE" = "true" ] || return 0
  if imageupdate_pull; then
    log "image-update: a provider runtime/job image changed -> draining + recreating fleet"
    imageupdate_rollover false
  elif [ -s "$IMAGEUPDATE_PENDING" ]; then
    log "image-update: retrying the slots left on an older provider image"
    imageupdate_rollover true
  fi
}

# long-running loop; re-reads config each tick so UI changes apply live
imageupdate_daemon() {
  exec 8>&- 7>&- 9>&- 2>/dev/null || true   # disown inherited lock fds (see autoscale_daemon)
  log "image-update daemon up (every ${IMAGE_AUTOUPDATE_INTERVAL}s, drain-timeout ${IMAGE_DRAIN_TIMEOUT}s)"
  while true; do
    load_cfg
    reload_secret_files
    [ "$IMAGE_AUTOUPDATE" = "true" ] || { log "image auto-update disabled -> daemon exit"; rm -f "$IMAGEUPDATE_PID"; break; }
    with_fleet_lock try imageupdate_tick
    sleep "${IMAGE_AUTOUPDATE_INTERVAL:-1800}"
  done
}

imageupdate_start() {
  [ "$IMAGE_AUTOUPDATE" = "true" ] || return 0
  imageupdate_stop || return 1
  nohup "$0" imageupdate-daemon >>"${RUNDIR}/imageupdate.log" 2>&1 &
  echo $! > "$IMAGEUPDATE_PID"
  log "image-update daemon started (pid $(cat "$IMAGEUPDATE_PID"))"
}
imageupdate_stop() {
  stop_worker_group "image-update" "$IMAGEUPDATE_PID" '[r]unner-farm.sh imageupdate-daemon'
}
imageupdate_status() {
  if [ -f "$IMAGEUPDATE_PID" ] && kill -0 "$(cat "$IMAGEUPDATE_PID" 2>/dev/null)" 2>/dev/null; then
    echo "running (pid $(cat "$IMAGEUPDATE_PID"))"
  else echo "stopped"; fi
}

# Inspect CACHE_ROOT and describe any problem that would break the fleet (empty
# output = OK). Split out from check_cache_root so the settings page can surface
# the SAME problems live, before the user clicks Start. Two classes:
#   - root filesystem (rootfs/tmpfs/overlay): RAM-backed, lost on reboot.
#   - FUSE user share (/mnt/user, fuse.shfs) while DinD is on: each runner's
#     Docker data root lands here, and overlay2 cannot run on FUSE, so buildx
#     and 'services:' jobs die with "mount overlay ... invalid argument".
cache_root_problem() {
  local root probe resolved line fstype target
  # A valid cache leaf need not exist before the first Start/Validate. Resolve
  # the guarded path first, then ask df about its nearest existing ancestor.
  # Using the canonical path (and canonicalizing the ancestor again) means an
  # existing symlink cannot redirect this probe outside the safe root between
  # the shape check and df. If the configured pool is not mounted yet, the walk
  # reaches /mnt and df reports rootfs, so the existing hard failure is retained.
  root="$(crf_safe_cache_root 2>/dev/null)" || {
    echo "CACHE_ROOT ($CACHE_ROOT) is unsafe — point it at a dedicated subdirectory under /mnt/<pool>."
    return
  }
  probe="$root"
  while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
    probe="${probe%/*}"
    [ -n "$probe" ] || probe="/"
  done
  resolved="$(realpath -e -- "$probe" 2>/dev/null)" || {
    echo "CACHE_ROOT ($CACHE_ROOT) could not be resolved to a stable existing pool path."
    return
  }
  case "$root" in
    "$resolved"|"$resolved"/*) probe="$resolved" ;;
    *)
      echo "CACHE_ROOT ($CACHE_ROOT) changed while it was being checked; retry after verifying the path."
      return ;;
  esac
  line=$(df -PT -- "$probe" 2>/dev/null | awk 'NR==2')
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
# GitLab API telemetry is deliberately separate from the reusable runner
# authentication token. The optional read_api token never enters a container or
# argv: like the GitHub PAT, curl reads its header from stdin. Callers use this
# only for the operator-configured GITLAB_PROJECTS list; runner polling itself
# works without it.
# Capture both body and response headers. GitLab's pagination X-Total header is
# the only efficient way to count all pending jobs without downloading an
# arbitrary number of pages.
# RFC 3986 percent encoding for GitLab project paths. Implemented locally so
# the runtime does not depend on jq/Python/PHP being available in PATH.
urlencode() {
  local LC_ALL=C s="$1" out="" c hex
  while [ -n "$s" ]; do
    c="${s:0:1}"; s="${s:1}"
    case "$c" in
      [A-Za-z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%02X' "'$c"; out+="%$hex" ;;
    esac
  done
  printf '%s' "$out"
}

# Mint a runner registration token for a scope. $1 = "org:<name>" or
# "repo:<owner/repo>". Echoes the token (empty on failure). GitHub's
# registration-token endpoint returns {"token":"...","expires_at":"..."}.
# Deregister a runner from GitHub host-side, by name, using the PAT. This replaces
# the base image's in-container SIGTERM deregister (we disable it via
# DISABLE_AUTOMATIC_DEREGISTRATION) — that path re-mints from ACCESS_TOKEN and so
# required the PAT inside the container. Doing it here is both safer (PAT stays on
# the host) and more robust (runs even when the container is hard-killed).
# Best-effort: a busy runner can't be deleted (GitHub 422) and a leftover offline
# entry is harmless — the next Start re-registers the same name with --replace.
deregister_runner_api() {
  local c="$1" provider
  provider="$(container_provider "$c")"
  "${provider}_deregister_runner_api" "$c"
}

# Fetch one GitHub REST endpoint for EVERY repo in GH_REPOS concurrently, writing each
# repo's raw response body to "$outdir/<n>" (n = 1-based position of the non-empty repo
# in GH_REPOS). The three background refreshers (queued, stats, public-repo) each sweep
# every target repo; doing it serially made refresh latency scale with repo count
# (N x per-call round-trip). Fan-out is chunked — drain every $maxpar — so a large repo
# list can't spawn hundreds of simultaneous curls or trip GitHub's concurrent-request
# secondary limit. Callers re-walk GH_REPOS with the SAME skip-empty rule so file <n>
# lines up with the right repo. Requires $ACCESS_TOKEN in scope.
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
security_cache_get() {
  [ -f "$SECURITY_CACHE" ] || return 1
  local age first
  age=$(( $(date +%s) - $(stat -c %Y "$SECURITY_CACHE" 2>/dev/null || echo 0) ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$SECURITY_TTL" ] || return 1
  first="$(head -1 "$SECURITY_CACHE" 2>/dev/null)"
  case "$first" in
    github|gitlab) [ "$first" = "$CI_PROVIDER" ] || return 1; tail -n +2 "$SECURITY_CACHE" ;;
    *) [ "$CI_PROVIDER" = github ] || return 1; cat "$SECURITY_CACHE" ;; # pre-provider cache
  esac
}

security_cache_put() {
  { printf '%s\n' "$CI_PROVIDER"; printf '%s' "$1"; } > "$SECURITY_CACHE" 2>/dev/null || true
}

public_repo_problem() {
  provider_public_problem
}

# docker login on the HOST so it can pull a private runner IMAGE (e.g. a private
# GHCR image). No-op unless server+username+token are all configured.
registry_login() {
  if [ "$IMAGE_SOURCE" != remote ] || [ -z "$REGISTRY_SERVER" ]; then
    rm -f "$HOST_DOCKER_CONFIG/config.json" 2>/dev/null || true
    return 0
  fi
  local user="$REGISTRY_USERNAME" pass="$REGISTRY_TOKEN"
  provider_registry_credentials
  mkdir -p "$HOST_DOCKER_CONFIG" || return 1
  chmod 700 "$HOST_DOCKER_CONFIG" 2>/dev/null || true
  if [ -z "$user" ] || [ -z "$pass" ]; then
    rm -f "$HOST_DOCKER_CONFIG/config.json" 2>/dev/null || true
    return 0
  fi
  if printf '%s' "$pass" | docker --config "$HOST_DOCKER_CONFIG" login -u "$user" --password-stdin -- "$REGISTRY_SERVER" >/dev/null 2>&1; then
    chmod 600 "$HOST_DOCKER_CONFIG/config.json" 2>/dev/null || true
    log "registry: logged in to $REGISTRY_SERVER as $user"
  else
    # Never retain the previously working credential after a failed rotation;
    # later pulls must fail closed instead of silently using stale cached auth.
    rm -f "$HOST_DOCKER_CONFIG/config.json" 2>/dev/null || true
    err "registry: docker login to $REGISTRY_SERVER failed (check server/username/token; GHCR needs read:packages on the PAT)"
    return 1
  fi
}

host_docker_pull() {
  mkdir -p "$HOST_DOCKER_CONFIG" || return 1
  chmod 700 "$HOST_DOCKER_CONFIG" 2>/dev/null || true
  docker --config "$HOST_DOCKER_CONFIG" pull -- "$1"
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
network_owned() {
  [ "$(docker network inspect -f '{{ index .Labels "net.unraid.ci-runner-farm" }}' "$1" 2>/dev/null)" = 1 ]
}

ensure_network() {
  [ "$NETWORK_ISOLATION" = "off" ] && return 0
  if docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1; then
    if network_owned "$RUNNER_NETWORK"; then
      return 0
    fi
    if [ "$NETWORK_ISOLATION" = strict ]; then
      err "strict isolation refuses unowned pre-existing network $RUNNER_NETWORK; remove/rename the collision or select an owned runner network"
      return 1
    fi
    log "warning: using pre-existing unowned network $RUNNER_NETWORK; it will be preserved on Stop"
    return 0
  fi
  log "creating isolated runner network $RUNNER_NETWORK"
  # Label our networks so they're identifiable as plugin-created. (RUNNER_NETWORK
  # defaults to the plugin-specific 'ci-runner-net'; a foreign network deliberately
  # pointed at by a hand-edited RUNNER_NETWORK is not verified here to preserve
  # upgrade compatibility with pre-label networks — see docs on isolation caveats.)
  docker network create --driver bridge --label net.unraid.ci-runner-farm=1 "$RUNNER_NETWORK" >/dev/null \
    || { err "could not create network $RUNNER_NETWORK"; return 1; }
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
mirror_labelled_id() {
  local id="$1"
  [ -n "$id" ] \
    && [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.resource" }}' "$id" 2>/dev/null)" = true ] \
    && [ "$(docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.role" }}' "$id" 2>/dev/null)" = mirror ]
}

# v1.8 and earlier created this plugin-specific mirror without ownership labels.
# Keep upgrades working, but recognize that legacy object only by a complete
# immutable provenance tuple: exact name, official image/config, and the exact
# plugin cache bind source. A merely colliding name never authorizes deletion.
mirror_legacy_owned_id() {
  local id="$1" name image source expected env
  [ -n "$id" ] || return 1
  name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null)" || return 1
  image="$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null)" || return 1
  source="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Source}}{{end}}{{end}}' "$id" 2>/dev/null)" || return 1
  env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null)" || return 1
  expected="$CACHE_ROOT/registry-mirror"
  [ "$name" = "/$MIRROR_NAME" ] \
    && [ "$image" = registry:2 ] \
    && [ "$source" = "$expected" ] \
    && printf '%s\n' "$env" | grep -qx 'REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io'
}

mirror_owned_id() {
  mirror_labelled_id "$1" || mirror_legacy_owned_id "$1"
}

mirror_resolve_owned_id() {
  local id
  id="$(docker inspect -f '{{.Id}}' "$MIRROR_NAME" 2>/dev/null)" || return 1
  mirror_owned_id "$id" || {
    err "refusing fixed-name collision: $MIRROR_NAME is not owned by CI Runner Farm"
    return 1
  }
  if ! mirror_labelled_id "$id"; then
    log "recognized legacy CI Runner Farm mirror by its exact image/cache provenance; it will be recreated with ownership labels on the next mirror refresh" >&2
  fi
  printf '%s\n' "$id"
}

# Delete the immutable object we inspected, never a name that another actor could
# reuse between the ownership check and Docker rm.
mirror_remove_owned() {
  local id
  if ! docker inspect "$MIRROR_NAME" >/dev/null 2>&1; then return 0; fi
  id="$(mirror_resolve_owned_id)" || return 1
  docker rm -f "$id" >/dev/null 2>&1 \
    || { err "could not remove owned shared image cache $MIRROR_NAME"; return 1; }
  if docker inspect "$id" >/dev/null 2>&1; then
    err "owned shared image cache $MIRROR_NAME still exists after removal"
    return 1
  fi
}

ensure_mirror() {
  [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ] || return 0
  mkdir -p "$CACHE_ROOT/registry-mirror" \
    || { err "could not create shared image cache directory under $CACHE_ROOT"; return 1; }
  local existing_id=""
  if docker inspect "$MIRROR_NAME" >/dev/null 2>&1; then
    existing_id="$(mirror_resolve_owned_id)" || return 1
  fi
  # If the mirror is up but on the wrong network for the current mode (operator
  # switched NETWORK_ISOLATION without a full Stop/Start), drop it so it's recreated
  # below on the right network — otherwise runners can't reach it by name and strict's
  # firewall keys off its stale IP. Its cache is on the pool volume, so this is cheap.
  if [ -n "$existing_id" ] && ! on_expected_network "$existing_id"; then
    log "network mode changed -> recreating shared image cache ($MIRROR_NAME)"
    mirror_remove_owned || return 1
    existing_id=""
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    if [ -n "$existing_id" ]; then
      mirror_remove_owned || return 1
      existing_id=""
    fi
    local netargs=()
    if [ "$NETWORK_ISOLATION" != "off" ]; then
      ensure_network || return 1
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
        --label net.unraid.ci-runner-farm.resource=true \
        --label net.unraid.ci-runner-farm.role=mirror \
        "${netargs[@]}" \
        -v "$CACHE_ROOT/registry-mirror:/var/lib/registry" \
        -e REGISTRY_PROXY_REMOTEURL="https://registry-1.docker.io" \
        registry:2 2>&1)"; then
      err "could not start $MIRROR_NAME: ${mout##*: }"
      # A failed run can leave a Created residue. The labels above make that
      # residue safe to clear through the same immutable-ID ownership check.
      mirror_remove_owned >/dev/null 2>&1 || true
      return 1
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
# nothing else on the box is affected. Strict means fail closed: inability to
# inspect or install any required rule aborts Start/reconcile before a manager is
# allowed to accept work.

# Remove every rule we previously added (matched by our comment tag), highest line
# number first so deletes don't renumber out from under us. Covers BOTH chains we
# touch: DOCKER-USER (forwarded traffic) and INPUT (traffic to the host's own IPs).
# Idempotent.
firewall_clear() {
  command -v iptables >/dev/null 2>&1 || return 0
  local chain n listing failed=0
  for chain in DOCKER-USER INPUT; do
    if ! listing="$(iptables -w -L "$chain" --line-numbers -n 2>/dev/null)"; then
      err "could not enumerate $chain while removing CI Runner Farm firewall rules"
      failed=1
      continue
    fi
    for n in $(printf '%s\n' "$listing" \
               | awk -v t="$FW_TAG" 'index($0,t){print $1}' | sort -rn); do
      if ! iptables -w -D "$chain" "$n" 2>/dev/null; then
        err "could not remove CI Runner Farm firewall rule $chain line $n"
        failed=1
      fi
    done
  done
  return "$failed"
}

# Idempotently add one rule at the head of a chain. `iptables -C` distinguishes
# an already-present rule from one that needs insertion; a failed insertion is a
# hard error in strict mode even if a later rule would happen to succeed.
firewall_ensure_rule() {
  local chain="$1"; shift
  if iptables -w -C "$chain" "$@" >/dev/null 2>&1; then
    return 0
  fi
  if ! iptables -w -I "$chain" 1 "$@" >/dev/null 2>&1; then
    err "strict isolation: could not install required $chain firewall rule"
    return 1
  fi
}

firewall_delete_exact_rule() {
  local chain="$1"; shift
  if ! iptables -w -D "$chain" "$@" >/dev/null 2>&1; then
    err "strict isolation: could not retire temporary $chain fail-closed guard"
    return 1
  fi
}

# Insert an ordered rule while building an authoritative policy from scratch.
firewall_insert_rule() {
  local chain="$1" position="$2"; shift 2
  if ! iptables -w -I "$chain" "$position" "$@" >/dev/null 2>&1; then
    err "strict isolation: could not install required $chain firewall rule at position $position"
    return 1
  fi
}

# Resolve the two explicitly configured control-plane endpoints that may
# legitimately live on a private/LAN address. Strict mode otherwise drops every
# RFC1918/CGNAT destination. Output is "IPv4 port label" and is consumed only as
# validated iptables arguments; arbitrary URLs never reach the shell command.
configured_strict_endpoints() {
  local kind spec hostport host port ip
  for kind in provider registry; do
    if [ "$kind" = provider ]; then
      spec="$(provider_strict_endpoint)"; [ -n "$spec" ] || continue
      spec="${spec#https://}"; port=443; kind="$CI_PROVIDER"
    else
      # GitLab jobs/services may override a built-in default image, so their
      # explicitly configured registry still needs its narrow LAN exception.
      # Preserve GitHub's historical remote-default-only registry behavior.
      [ -n "$REGISTRY_SERVER" ] \
        && { [ "$CI_PROVIDER" = gitlab ] || [ "$IMAGE_SOURCE" = remote ]; } \
        || continue
      spec="$REGISTRY_SERVER"
      case "$spec" in http://*) port=80 ;; *) port=443 ;; esac
      spec="${spec#https://}"; spec="${spec#http://}"
    fi
    hostport="${spec%%/*}"; host="$hostport"
    # IPv4/hostname endpoints cover Unraid's iptables-based strict mode. IPv6
    # destinations are outside this plugin's existing IPv4 firewall contract.
    case "$hostport" in
      *:*:*) continue ;;
      *:*) host="${hostport%:*}"; port="${hostport##*:}" ;;
    esac
    printf '%s' "$host" | grep -qE '^[A-Za-z0-9][A-Za-z0-9.-]*$' || continue
    case "$port" in ''|*[!0-9]*) continue ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || continue
    {
      getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}'
      getent hosts "$host" 2>/dev/null | awk '{print $1}'
    } | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u | while read -r ip; do
      [ -n "$ip" ] && printf '%s %s %s\n' "$ip" "$port" "$kind"
    done
  done
}

# Add the COMPLETE policy for the current runner subnet without deleting tagged
# rules for an old subnet or endpoint.  This is used while a mixed/stale fleet is
# draining: a runner still attached to the old network must remain protected and
# able to reach its old control plane, while its replacement needs the current
# network, mirror and endpoint policy immediately.  All allows are inserted after
# the drops below, so they finish above both the new and any pre-existing drops.
# Exact -C checks make the operation idempotent across repeated Start/reconcile
# cycles.
firewall_allow_current_policy() {
  [ "$NETWORK_ISOLATION" = strict ] || return 0
  command -v iptables >/dev/null 2>&1 \
    || { err "strict isolation needs iptables — egress NOT restricted"; return 1; }
  docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1 \
    || { err "strict isolation: $RUNNER_NETWORK missing — egress NOT restricted"; return 1; }
  local s gw mip host_service_ip epip epport eplabel
  s="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  gw="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  [ -n "$s" ] || { err "strict isolation: could not resolve $RUNNER_NETWORK subnet — egress NOT restricted"; return 1; }
  mip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MIRROR_NAME" 2>/dev/null)"
  host_service_ip="$(runner_host_service_ipv4)" \
    || { err "strict isolation: could not resolve the local runner-farm service address"; return 1; }

  # Install a broad temporary egress guard before touching a live subnet. If any
  # later insert fails, the guard remains and the operation fails closed (jobs
  # lose egress instead of gaining LAN/host access). Exact current allows are
  # inserted at the head and the guard is retired only after the whole policy is
  # present. INPUT's broad drop is itself the final host-protection rule.
  firewall_ensure_rule DOCKER-USER -s "$s" -j DROP -m comment --comment "$FW_TAG:install-guard" || return 1
  firewall_ensure_rule INPUT -s "$s" -j DROP -m comment --comment "$FW_TAG:in-drop" || return 1

  # Specific drops first. Later -I 1 allows are guaranteed to precede them.
  firewall_ensure_rule DOCKER-USER -s "$s" -d 100.64.0.0/10 -j DROP -m comment --comment "$FW_TAG:cgnat" || return 1
  firewall_ensure_rule DOCKER-USER -s "$s" -d 192.168.0.0/16 -j DROP -m comment --comment "$FW_TAG:lan192" || return 1
  firewall_ensure_rule DOCKER-USER -s "$s" -d 172.16.0.0/12 -j DROP -m comment --comment "$FW_TAG:lan172" || return 1
  firewall_ensure_rule DOCKER-USER -s "$s" -d 10.0.0.0/8 -j DROP -m comment --comment "$FW_TAG:lan10" || return 1
  if [ -n "$gw" ]; then
    firewall_ensure_rule DOCKER-USER -s "$s" -d "$gw" -j DROP -m comment --comment "$FW_TAG:host" || return 1
  fi
  # Reach only the SSH transport for the QA VM provider colocated on this farm.
  # No other host or LAN service is opened by this exception.
  firewall_ensure_rule DOCKER-USER -s "$s" -d "$host_service_ip" -p tcp --dport 22 \
    -j RETURN -m comment --comment "$FW_TAG:local-qavm" || return 1
  firewall_ensure_rule INPUT -s "$s" -d "$host_service_ip" -p tcp --dport 22 \
    -j RETURN -m comment --comment "$FW_TAG:in-local-qavm" || return 1
  while read -r epip epport eplabel; do
    [ -n "$epip" ] || continue
    firewall_ensure_rule DOCKER-USER -s "$s" -d "$epip" -p tcp --dport "$epport" \
      -j RETURN -m comment --comment "$FW_TAG:$eplabel" || return 1
    firewall_ensure_rule INPUT -s "$s" -d "$epip" -p tcp --dport "$epport" \
      -j RETURN -m comment --comment "$FW_TAG:in-$eplabel" || return 1
  done <<< "$(configured_strict_endpoints)"
  firewall_ensure_rule DOCKER-USER -d "$s" -m conntrack --ctstate ESTABLISHED,RELATED \
    -j RETURN -m comment --comment "$FW_TAG:estab" || return 1
  if [ -n "$mip" ]; then
    firewall_ensure_rule DOCKER-USER -s "$s" -d "$mip" -p tcp --dport 5000 \
      -j RETURN -m comment --comment "$FW_TAG:mirror" || return 1
  fi
  firewall_ensure_rule INPUT -s "$s" -m conntrack --ctstate ESTABLISHED,RELATED \
    -j RETURN -m comment --comment "$FW_TAG:in-estab" || return 1
  firewall_delete_exact_rule DOCKER-USER -s "$s" -j DROP -m comment --comment "$FW_TAG:install-guard"
}

# Replacements avoid a fleet-wide clear/reapply gap. If no tagged policy exists,
# firewall_apply decides whether an authoritative empty-fleet build is safe or a
# fail-closed additive live-fleet install is required. Otherwise add the complete
# current policy alongside old rules still protecting stale managers.
firewall_prepare_replacement() {
  [ "$NETWORK_ISOLATION" = strict ] || return 0
  command -v iptables >/dev/null 2>&1 \
    || { err "strict isolation needs iptables — egress NOT restricted"; return 1; }
  local rules
  if ! rules="$(iptables -w -L DOCKER-USER -n 2>/dev/null)"; then
    err "strict isolation: could not inspect DOCKER-USER before replacement"
    return 1
  fi
  if ! printf '%s' "$rules" | grep -qF "$FW_TAG"; then
    log "strict isolation: installing initial firewall policy"
    firewall_apply
  else
    firewall_allow_current_policy
  fi
}

# Apply firewall state without ever clearing rules underneath a managed runner.
# A live fleet receives only the additive fail-closed policy above; obsolete
# tagged rules are intentionally retained until Stop leaves the fleet empty.
# With no managed runner, an authoritative clear/rebuild is safe (and removes old
# strict rules when the selected mode is now off/isolate).
firewall_apply() {
  local live
  live="$(managed_names)" \
    || { err "could not verify the managed fleet before applying firewall state"; return 1; }
  if [ -n "$live" ]; then
    if [ "$NETWORK_ISOLATION" = strict ]; then
      firewall_allow_current_policy
    else
      log "preserving tagged strict firewall rules until the remaining managed fleet is stopped"
    fi
    return
  fi

  firewall_clear || return 1
  [ "$NETWORK_ISOLATION" = "strict" ] || return 0
  command -v iptables >/dev/null 2>&1 || { err "strict isolation needs iptables — egress NOT restricted"; return 1; }
  docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1 || { err "strict isolation: $RUNNER_NETWORK missing — egress NOT restricted"; return 1; }
  local s gw mip host_service_ip i=1 epip epport eplabel ini=2
  s="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  gw="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  [ -n "$s" ] || { err "strict isolation: could not resolve $RUNNER_NETWORK subnet — egress NOT restricted"; return 1; }
  mip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MIRROR_NAME" 2>/dev/null)"
  host_service_ip="$(runner_host_service_ipv4)" \
    || { err "strict isolation: could not resolve the local runner-farm service address"; return 1; }
  # Order matters (top-down): allow mirror + established replies, THEN drop host +
  # every private range. Inserting at increasing indices keeps them in this order
  # ahead of Docker's trailing RETURN.
  if [ -n "$mip" ]; then
    firewall_insert_rule DOCKER-USER "$i" -s "$s" -d "$mip" -p tcp --dport 5000 -j RETURN -m comment --comment "$FW_TAG:mirror" || return 1
    i=$((i+1))
  fi
  firewall_insert_rule DOCKER-USER "$i" -d "$s" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN -m comment --comment "$FW_TAG:estab" || return 1
  i=$((i+1))
  firewall_insert_rule DOCKER-USER "$i" -s "$s" -d "$host_service_ip" -p tcp --dport 22 -j RETURN -m comment --comment "$FW_TAG:local-qavm" || return 1
  i=$((i+1))
  # Narrow exceptions for an explicitly configured self-managed GitLab and/or
  # private job-image registry. These precede the LAN drops and match only the
  # resolved IPv4 plus the endpoint's configured TCP port.
  while read -r epip epport eplabel; do
    [ -n "$epip" ] || continue
    firewall_insert_rule DOCKER-USER "$i" -s "$s" -d "$epip" -p tcp --dport "$epport" -j RETURN -m comment --comment "$FW_TAG:$eplabel" || return 1
    i=$((i+1))
  done <<< "$(configured_strict_endpoints)"
  if [ -n "$gw" ]; then
    firewall_insert_rule DOCKER-USER "$i" -s "$s" -d "$gw" -j DROP -m comment --comment "$FW_TAG:host" || return 1
    i=$((i+1))
  fi
  firewall_insert_rule DOCKER-USER "$i" -s "$s" -d 10.0.0.0/8 -j DROP -m comment --comment "$FW_TAG:lan10" || return 1; i=$((i+1))
  firewall_insert_rule DOCKER-USER "$i" -s "$s" -d 172.16.0.0/12 -j DROP -m comment --comment "$FW_TAG:lan172" || return 1; i=$((i+1))
  firewall_insert_rule DOCKER-USER "$i" -s "$s" -d 192.168.0.0/16 -j DROP -m comment --comment "$FW_TAG:lan192" || return 1; i=$((i+1))
  firewall_insert_rule DOCKER-USER "$i" -s "$s" -d 100.64.0.0/10 -j DROP -m comment --comment "$FW_TAG:cgnat" || return 1; i=$((i+1))
  # DOCKER-USER is in the FORWARD path only. A runner reaching the Unraid host's OWN
  # ip (e.g. the webGUI on the LAN address, or the host's tailscale ip) is delivered
  # locally via INPUT and never forwarded, so the rules above miss it — that leaves
  # the management UI reachable. Drop new traffic from the runner subnet to the host
  # here too; the runner needs nothing that originates host-side (the mirror is a
  # container = forwarded, DNS is Docker's embedded resolver inside the netns).
  firewall_insert_rule INPUT 1 -s "$s" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN -m comment --comment "$FW_TAG:in-estab" || return 1
  firewall_insert_rule INPUT "$ini" -s "$s" -d "$host_service_ip" -p tcp --dport 22 -j RETURN -m comment --comment "$FW_TAG:in-local-qavm" || return 1
  ini=$((ini+1))
  while read -r epip epport eplabel; do
    [ -n "$epip" ] || continue
    firewall_insert_rule INPUT "$ini" -s "$s" -d "$epip" -p tcp --dport "$epport" -j RETURN -m comment --comment "$FW_TAG:in-$eplabel" || return 1
    ini=$((ini+1))
  done <<< "$(configured_strict_endpoints)"
  firewall_insert_rule INPUT "$ini" -s "$s" -j DROP -m comment --comment "$FW_TAG:in-drop" || return 1
  log "strict isolation: egress locked to internet+mirror+configured CI endpoints+local QA VM MCP for $s (other host/LAN access blocked)"
}

# Resolve the provider's executable/default-job image: the locally built tag or
# a remote ref. GitLab's manager image is deliberately separate.
image_ref_is_safe() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_./:@-]*$'
}

effective_image() {
  local image="$IMAGE"
  if [ "$IMAGE_SOURCE" = "remote" ] && [ -n "$image" ]; then
    image_ref_is_safe "$image" \
      || { err "IMAGE is not a safe Docker image reference"; return 1; }
    printf '%s\n' "$image"
  else
    builtin_image
  fi
}

# Verify a recycle replacement without pulling a GitLab DinD job image through
# the wrong daemon. Remote images belong to the provider-selected daemon;
# locally built images must already exist in the host store.
recycle_image_preflight() {
  local image="$1"
  if [ "$IMAGE_SOURCE" = remote ]; then
    provider_prepare_remote_image "$image" >/dev/null 2>&1
  else
    docker image inspect "$image" >/dev/null 2>&1
  fi
}

# Provider adapters own the complete docker argv contract.
build_args() { provider_call build_args "$@"; }

# An adapter may stage secret material for its argv (a mode-0600 --env-file, so a
# credential never reaches /proc/<pid>/cmdline) and publish that directory as
# ARGS_TMPDIR. ARGS outlives the adapter call and has more than one consumer, so
# the engine retires the directory once the run it was built for is dispatched.
# Like every other destructive path here the target is validated first: realpath -m
# collapses ../ . and trailing slashes lexically so the guard checks the REAL
# location, and only a path strictly under RUNDIR — never an empty value — may be
# removed, so a stale or misdirected ARGS_TMPDIR cannot delete anything else.
clear_args_tmpdir() {
  local dir="${ARGS_TMPDIR:-}" resolved root
  ARGS_TMPDIR=""
  [ -n "$dir" ] || return 0
  resolved="$(realpath -m -- "$dir" 2>/dev/null)"
  root="$(realpath -m -- "$RUNDIR" 2>/dev/null)"
  [ -n "$resolved" ] && [ -n "$root" ] \
    || { err "refusing to remove unresolvable temporary argv dir '$dir'"; return 1; }
  case "$resolved" in
    "$root"/?*) ;;
    *) err "refusing to remove temporary argv dir '$dir' outside $RUNDIR"; return 1 ;;
  esac
  rm -rf "${resolved:?}" 2>/dev/null \
    || { err "could not remove temporary argv dir '$dir'"; return 1; }
}

start_one() {
  local idx="$1" name="${NAME_PREFIX}-$1" snapshot
  if docker inspect "$name" >/dev/null 2>&1; then
    snapshot="$(managed_runner_snapshot "$name")" \
      || { err "refusing fixed-name collision while starting $name"; return 1; }
    log "owned runner $name already exists; skipping"
    return 0
  fi
  provider_call start_one "$idx" "$name"
}

start_configured_capacity() {
  local startn="$RUNNER_COUNT" i rec pool failed=0
  if pool_mode_enabled; then
    while IFS= read -r rec; do
      pool="$(printf '%s' "$rec" | cut -d'|' -f2)"
      pool_activate "$pool" || { failed=1; continue; }
      startn="$(pool_fixed "$pool")" || { failed=1; continue; }
      if [ "$IMAGE_SOURCE" = remote ] && provider_remote_image_host_pull_required; then
        registry_login || { failed=1; continue; }
        provider_prepare_remote_image "$(effective_image)" >/dev/null \
          || { err "could not prepare image $(effective_image) for pool $pool"; failed=1; continue; }
      fi
      for i in $(seq 1 "$startn"); do start_one "$i" || failed=1; done
    done < <(pool_records)
  else
    [ "$AUTOSCALE" = true ] && startn="$AUTOSCALE_MIN"
    pool_activate default
    for i in $(seq 1 "$startn"); do start_one "$i" || failed=1; done
  fi
  return "$failed"
}

# Recreate a stopped managed runner when its provider/config requires it. GitHub
# needs a fresh short-lived registration token; a stale/provider-switched GitLab
# manager must unregister its old persisted identity before replacement.
recreate_stopped_runner() {
  local c="$1" supplied_snapshot="${2:-}" snapshot id provider role idx gen pool
  snapshot="$supplied_snapshot"
  [ -n "$snapshot" ] || snapshot="$(managed_runner_snapshot "$c")" || return 1
  IFS='|' read -r id provider role idx gen <<< "$snapshot"
  pool="$(runner_pool "$c")" || return 1
  remove_runner "$c" false "$id" "$provider" || return 1
  pool_activate "$pool" || { err "runner $c belongs to unknown pool $pool"; return 1; }
  start_one "$idx"
}

# Bring back managed containers after an array/Docker restart. GitHub slots are
# recreated with fresh registration tokens. An unchanged GitLab manager instead
# starts in place with its persisted config/system ID; unregistering it during a
# routine outage would create needless remote churn and make recovery depend on
# GitLab availability.
start_stopped_managed() {
  local c st provider idx names snapshot id role gen
  names="$(managed_names)" || return 1
  for c in $names; do
    [ -n "$c" ] || continue
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role idx gen <<< "$snapshot"
    st="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" \
      || { err "could not inspect stopped/running state for owned runner $c"; return 1; }
    [ "$st" = "true" ] && continue
    if [ "$provider" = gitlab ] && [ "$CI_PROVIDER" = gitlab ] \
      && [ "$gen" = "$(crf_confgen)" ]; then
      log "restarting stopped GitLab manager $c with its persisted system ID"
      gitlab_start_stopped "$c" "$idx" "$id" || return 1
    else
      log "recreating stopped runner $c with current provider credentials"
      recreate_stopped_runner "$c" "$snapshot" || return 1
    fi
  done
}

# Cache/network provisioning shared by cmd_start and the Fleet recycle path before
# they run start_one: validate the cache root (hard guard — aborts on FUSE for
# DIND, etc.), create the cache dirs / isolated network / image-cache mirror, and
# prepare remote-registry access in the daemon that owns job containers. GitHub
# and GitLab host-socket mode login/pull on the host here; GitLab DinD defers to
# the per-slot auth, CA trust, and pull in gitlab_ensure_job_image. Returns
# non-zero (problem already logged) when the
# cache-root guard OR a real registry login fails, so callers can bail before
# provisioning (registry_login is a no-op returning 0 for the built-in image or
# when no remote registry/creds are set, so it only bites an actually-failed remote
# auth). Firewall handling is deliberately NOT here: the strict-mode egress rules
# are keyed on the runner subnet, not per container, so a replacement rejoining
# that subnet is already covered by the fleet's existing rules. cmd_start uses
# authoritative preflight for a fresh/non-strict fleet and additive preparation
# for an existing strict fleet; recycle must NOT clear+reapply rules mid-drain,
# which would briefly drop egress protection for every strict runner.
# (cmd_scale runs its own lighter inline subset and is intentionally not a caller.)
provision_base() {
  check_cache_root || return 1
  ensure_dirs || return 1
  ensure_network || return 1
  ensure_mirror || return 1
  if provider_remote_image_host_pull_required; then
    if [ "$IMAGE_SOURCE" = remote ] && [ -n "$IMAGE" ]; then
      provider_prepare_remote_image "$(effective_image)" >/dev/null \
        || { err "could not prepare configured job/runner image $(effective_image) under the selected pull policy"; return 1; }
    fi
  else
    # A stale host-side login must not survive a switch to GitLab DinD. The
    # adapter writes per-slot auth and the nested daemon performs the pull.
    rm -f "$HOST_DOCKER_CONFIG/config.json" 2>/dev/null || true
  fi
}

# Full Start preflight: shared provisioning followed by safe firewall transition.
# firewall_apply clears authoritatively only for an empty fleet; otherwise it is
# additive (strict) or preserves old tagged protection until Stop (off/isolate).
provision_preflight() {
  provision_base || return 1
  firewall_apply
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
    ( flock -n 8 || exit 0; reload_locked_snapshot || exit 1; "$@" ) 8>"$RUNDIR/fleet.lock"
  else
    ( flock -w 20 8 || { err "fleet busy (another start/stop/scale/recycle or a daemon tick is running) — try again"; exit 1; }; reload_locked_snapshot || exit 1; "$@" ) 8>"$RUNDIR/fleet.lock"
  fi
}
cmd_restart() { cmd_stop || return 1; reload_locked_snapshot || return 1; cmd_start; }

# Operator convenience: (re)start the shared image cache + regenerate the runner DinD
# config to match — WITHOUT a full fleet Start/Restart (useful after changing
# SHARED_IMAGE_CACHE / MIRROR_PORT, or to clear a failed mirror). The mirror is a
# separate container so this doesn't disrupt runners; already-running runners pick up
# the new mirror endpoint only when they are next recreated.
cmd_mirror_up() {
  ensure_mirror || return 1
  write_dind_config || return 1
  if docker ps --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    log "shared image cache ($MIRROR_NAME) is up"
  elif [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ]; then
    err "shared image cache is not running — see the error above"
  fi
}

# ── Drain-aware config reconciliation ────────────────────────────────────────
# Recycle AT MOST ONE managed runner that predates the current baked config onto the new
# one, while it is IDLE or in an ERROR state — a busy runner keeps its in-flight job and is
# caught on a later pass once it finishes, so a settings change never kills a job. One-per-pass so
# the fleet migrates gradually and never drops all its capacity at once. Lock-free: the
# CALLER must hold the fleet lock (cmd_recycle, which this calls, assumes the dispatch or
# caller already locked). A failed recycle returns non-zero so a drain stops at
# the first unsafe slot rather than walking through and quiescing the whole fleet.
reconcile_stale_runners() {
  # Re-read settings and secret files only after the caller holds fleet.lock.
  # Otherwise a drain waiting for the lock can recreate per-slot files from a
  # token that was cleared/rotated while it waited.
  reload_locked_snapshot || return 1
  local cur c gen names snapshot id provider role index
  names="$(managed_names)" || return 1
  for c in $names; do
    [ -n "$c" ] || continue
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    cur="$(expected_runner_confgen "$c")" || return 1
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
      return 1
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
  # Disown an inherited fleet-lock fd (this can be nohup'd from cmd_start, which holds
  # fd 8) so our own `with_fleet_lock wait` below isn't self-blocked. Keep fd 7 — the
  # dispatch wrapper holds it as this drain's own reconcile.lock. See autoscale_daemon.
  exec 8>&- 9>&- 2>/dev/null || true
  trap 'rm -f "$RECONCILE_PID" 2>/dev/null || true' EXIT
  trap 'rm -f "$RECONCILE_PID" 2>/dev/null || true; exit 0' HUP INT TERM
  local deadline announced=0 lost paused=0 stale=-1
  rm -f "$RUNDIR/reconcile.shrink"                  # fresh tally of runners lost this drain (see reconcile_stale_runners)
  deadline=$(( $(date +%s) + ${IMAGE_DRAIN_TIMEOUT:-3600} ))
  while :; do
    load_cfg
    [ "$CI_PROVIDER" = gitlab ] || CI_PROVIDER=github
    reload_secret_files
    if ! stale="$(count_stale_runners)"; then
      paused=1
      log "reconcile: could not enumerate/inspect the managed fleet; migration stopped fail-closed"
      break
    fi
    [ "$stale" -eq 0 ] && break
    [ "$announced" = 0 ] && { log "reconcile: config changed — migrating runners onto it as they go idle"; announced=1; }
    if ! with_fleet_lock wait reconcile_stale_runners; then
      paused=1
      log "reconcile: migration paused after a slot failed; no additional runners will be drained until a later retry"
      break
    fi
    if ! stale="$(count_stale_runners)"; then
      paused=1
      log "reconcile: could not verify remaining stale runners; migration stopped fail-closed"
      break
    fi
    [ "$stale" -eq 0 ] && break
    # IMAGE_DRAIN_TIMEOUT=0 means "wait forever" (per the settings help), so only enforce
    # the deadline when it's positive — matching drain_and_recreate's `limit -gt 0` guard.
    [ "${IMAGE_DRAIN_TIMEOUT:-3600}" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ] && { log "reconcile: $stale runner(s) still on the old config after the drain timeout (finishing jobs or wedged in startup) — they'll migrate on their next idle, or Restart the fleet to force it now"; break; }
    sleep 15
  done
  lost="$([ -f "$RUNDIR/reconcile.shrink" ] && grep -c . "$RUNDIR/reconcile.shrink" 2>/dev/null || echo 0)"
  stale="$(count_stale_runners)" || stale=-1
  if [ "$announced" = 1 ]; then
    if [ "${lost:-0}" -gt 0 ]; then
      if [ "$stale" -eq 0 ]; then
        log "reconcile: migration finished but $lost runner(s) were removed without a replacement — Start/Restart the fleet to restore capacity"
      else
        log "reconcile: migration incomplete, and $lost runner(s) were also removed without a replacement — Start/Restart the fleet to restore capacity"
      fi
    elif [ "$stale" -eq 0 ]; then
      log "reconcile: fleet is now on the current config"
    elif [ "$paused" = 1 ]; then
      if [ "$stale" -ge 0 ]; then
        log "reconcile: $stale stale runner(s) remain after the fail-closed pause; fix the logged lifecycle error and Apply again"
      else
        log "reconcile: remaining stale runners could not be verified after the fail-closed pause; fix Docker/ownership inspection and Apply again"
      fi
    fi
  fi
  rm -f "$RUNDIR/reconcile.shrink"
}

# Kick off the drain detached so the Settings Apply returns immediately (recycling is
# slow). Safe no-op when nothing is stale (the drain exits on the first count). Output
# shows in the Apply progress frame — human text, not JSON.
cmd_reconcile_config() {
  validate_runner_mode || { err "cannot reconcile: $POOL_CONFIG_ERROR"; return 1; }
  if pool_mode_enabled; then
    echo "Named-pool configuration saved. Restart the fleet to apply exact pool membership, images, labels/tags, and resource limits; running jobs are not interrupted by this Apply action."
    return 0
  fi
  local managed
  managed="$(managed_names)" \
    || { err "cannot reconcile: could not enumerate the managed fleet"; return 1; }
  # Saving an empty farm must remain possible before credentials are entered.
  # Once a manager exists, however, Apply can launch a provider-switch drain;
  # require the destination credential before that worker is allowed to start.
  if [ -n "$managed" ]; then
    provider_token_ready \
      || { err "cannot reconcile an existing fleet without a valid $(provider_token_name)"; return 1; }
  fi
  provider_validate_settings \
    || { err "cannot reconcile: invalid $CI_PROVIDER provider settings"; return 1; }
  reconcile_start || { err "could not start configuration reconcile worker"; return 1; }
  local msg="Configuration saved. Any runner on a previous config will migrate as it goes idle (busy jobs finish first)."
  # A NETWORK_ISOLATION change applies per-runner only as each recycles — so running
  # jobs keep their OLD network until they finish. Say so plainly: a gradual, background
  # migration of a security-isolation setting can otherwise read as immediate enforcement.
  [ "$NETWORK_ISOLATION" != off ] && msg="$msg  NOTE: network isolation ($NETWORK_ISOLATION) takes effect on each runner only as it recycles — running jobs keep their current network until they finish. Restart the fleet to enforce it on every runner immediately."
  echo "$msg"
}

reconcile_start() {
  reconcile_stop || return 1
  nohup "$0" reconcile-drain >>"$RUNDIR/autoscale.log" 2>&1 &
  ( umask 077; printf '%s\n' "$!" > "$RECONCILE_PID" ) \
    || { err "could not publish reconcile worker PID"; return 1; }
}

reconcile_stop() {
  stop_worker_group "reconcile" "$RECONCILE_PID" '[r]unner-farm.sh reconcile-drain'
}

cmd_start() {
  validate_runner_mode || { err "$POOL_CONFIG_ERROR"; return 1; }
  local start_failed=0
  pool_tokens_ready || { err "one or more required $(provider_token_name) credentials are missing or invalid"; return 1; }
  if [ "$CI_PROVIDER" = gitlab ] && ! pool_mode_enabled; then gitlab_validate_settings || return 1; fi
  rm -f "$SECURITY_CACHE"                       # force a fresh public-repo check on an explicit Start
  local secp; secp="$(public_repo_problem)"
  [ -n "$secp" ] && err "SECURITY: $secp"       # warn, do not block (operator's call)
  gitlab_assert_no_orphan_manager_configs || return 1
  # An existing strict fleet may contain busy runners on the previous network or
  # endpoint configuration.  Provision the new base resources, then add its full
  # policy alongside the old one until reconcile drains every stale slot.  Empty
  # fleets and non-strict modes retain the authoritative preflight (including the
  # strict -> off/isolate cleanup of old tagged rules).
  local existing_managed
  existing_managed="$(managed_names)" \
    || { err "could not enumerate the existing managed fleet"; return 1; }
  if [ "$NETWORK_ISOLATION" = strict ] && [ -n "$existing_managed" ]; then
    provision_base || return 1
    firewall_prepare_replacement || return 1
  else
    provision_preflight || return 1
  fi
  gitlab_cleanup_orphan_sidecars || { err "could not safely clean orphaned GitLab sidecars"; return 1; }
  # If NETWORK_ISOLATION changed while the fleet was up, existing runners are still
  # on the old network — they must be recreated so the new mode actually applies (a
  # half-isolated fleet is a false sense of security). Do this in the BACKGROUND: a
  # network change bumps the confgen fingerprint, so the detached reconcile drain
  # migrates each stale runner onto the new network as it goes idle (running jobs
  # finish first), exactly like a Settings Apply. Draining inline here would block
  # this synchronous Start request under the fleet lock for up to IMAGE_DRAIN_TIMEOUT
  # (hours) while a busy runner finishes. Runners already on the right network match
  # and are left untouched, so a normal Start migrates nothing.
  local c need_migrate=0 snapshot
  existing_managed="$(managed_names)" || return 1
  for c in $existing_managed; do
    [ -n "$c" ] || continue
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    ! on_expected_network "$c" && { need_migrate=1; break; }
  done
  [ "$need_migrate" = 1 ] && {
    log "network mode changed -> migrating runners onto the new network in the background as they go idle"
    reconcile_start || start_failed=1
  }
  # bring back any runners Unraid/Docker left exited (array stop, daemon restart)
  start_stopped_managed || start_failed=1
  # Only after stopped slots have been restored should genuinely dead/unhealthy
  # running slots be reaped. This preserves every preexisting autoscale slot
  # across a Docker/array restart instead of collapsing straight to MIN.
  reap_dead_runners || start_failed=1
  # with autoscaling on, start the floor (MIN) and let the daemon grow to demand
  start_configured_capacity || start_failed=1
  local final_count
  final_count="$(current_count)" || start_failed=1
  log "fleet up: ${final_count:-unknown} runner(s)"
  if [ "$AUTOSCALE" = "true" ]; then autoscale_start || start_failed=1; fi
  if [ "$IMAGE_AUTOUPDATE" = "true" ]; then imageupdate_start || start_failed=1; fi
  if [ "$start_failed" -ne 0 ]; then
    err "fleet start completed with one or more slots unavailable; see the preceding errors"
    return 1
  fi
  return 0
}

# Tear down a runner: graceful stop, remove the container, and drop its DinD
# data root (the per-runner /var/lib/docker bind dir created in build_args) so
# the pool is reclaimed instead of leaking a tree per retired runner.
provider_stop_container() {
  local slot="$1" c="$1" provider timeout=30
  # remove_runner can bind an immutable ID to the stable slot name through
  # dynamically scoped locals. Provider adapters continue receiving the slot
  # name for GitHub API identity and GitLab config/system-ID paths, while the
  # actual Docker stop/remove cannot be redirected by a name-reuse race.
  if [ -n "${CRF_REMOVE_ID:-}" ] && [ "$slot" = "${CRF_REMOVE_SLOT:-}" ]; then
    c="$CRF_REMOVE_ID"
    provider="$CRF_REMOVE_PROVIDER"
  else
    provider="$(container_provider "$c")"
  fi
  if [ "$provider" = gitlab ]; then
    # Official Runner images already declare STOPSIGNAL SIGQUIT, but make the
    # contract explicit so a pinned compatible image cannot turn an operator
    # Stop into a forceful SIGTERM. The persisted timeout also covers Docker and
    # Unraid array shutdown paths that stop the container directly.
    timeout="$(gitlab_shutdown_timeout)"
  fi
  if [ "$provider" = gitlab ]; then
    docker stop --signal SIGQUIT --timeout "$timeout" "$c"
  else
    # Keep GitHub's existing stop signal while avoiding an empty-array expansion,
    # which is an unbound variable under the macOS Bash 3 test environment.
    docker stop --timeout "$timeout" "$c"
  fi >/dev/null 2>&1 || {
    docker inspect "$c" >/dev/null 2>&1 && { err "could not stop $slot"; return 1; }
  }
}

provider_remove_container() {
  local slot="$1" c="$1"
  if [ -n "${CRF_REMOVE_ID:-}" ] && [ "$slot" = "${CRF_REMOVE_SLOT:-}" ]; then
    c="$CRF_REMOVE_ID"
  fi
  docker rm "$c" >/dev/null 2>&1 || {
    docker inspect "$c" >/dev/null 2>&1 && { err "could not remove $slot"; return 1; }
  }
}

provider_stop_remove_container() {
  provider_stop_container "$1" && provider_remove_container "$1"
}

provider_stop_owned_runner() {
  local slot="$1" immutable_id="$2" provider="$3"
  local CRF_REMOVE_SLOT="$slot" CRF_REMOVE_ID="$immutable_id" CRF_REMOVE_PROVIDER="$provider"
  printf '%s' "$immutable_id" | grep -qE '^[0-9a-f]{64}$' \
    || { err "refusing to stop $slot with an invalid immutable container ID"; return 1; }
  case "$provider" in github|gitlab) ;; *) err "refusing to stop $slot without a validated provider"; return 1 ;; esac
  provider_stop_container "$slot"
}

remove_runner() {
  local c="$1" purge="${2:-true}" immutable_id="${3:-}" provider="${4:-}"
  local snapshot snapshot_id snapshot_provider role index gen
  local CRF_REMOVE_SLOT="" CRF_REMOVE_ID="" CRF_REMOVE_PROVIDER=""
  [ -n "$c" ] || return 0
  snapshot="$(managed_runner_snapshot "$c")" || return 1
  IFS='|' read -r snapshot_id snapshot_provider role index gen <<< "$snapshot"
  if [ -n "$immutable_id" ] \
     && { [ "$immutable_id" != "$snapshot_id" ] || [ "$provider" != "$snapshot_provider" ]; }; then
    err "refusing removal of $c because its immutable ownership changed"
    return 1
  fi
  immutable_id="$snapshot_id"
  provider="$snapshot_provider"
  CRF_REMOVE_SLOT="$c"
  CRF_REMOVE_ID="$immutable_id"
  CRF_REMOVE_PROVIDER="$provider"
  "${provider}_remove_runner" "$c" "$purge"
}

# Stop every running GitLab manager concurrently before a full fleet teardown.
# Signalling them all first prevents later slots from accepting fresh jobs while
# Stop waits for an earlier slot's graceful timeout, and bounds the fleet-wide
# drain by one configured timeout instead of one timeout per manager.
quiesce_gitlab_managers_for_stop() {
  local c pids="" pid failed=0 count=0 names snapshot id provider role index gen
  names="$(managed_names)" || return 1
  for c in $names; do
    [ -n "$c" ] || continue
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    [ "$provider" = gitlab ] || continue
    if ! docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null | grep -qx true; then
      docker inspect "$id" >/dev/null 2>&1 \
        || { err "could not inspect owned GitLab manager $c before quiescing"; return 1; }
      continue
    fi
    count=$((count+1))
    log "stopping $c accepting new GitLab work; draining its active job"
    provider_stop_owned_runner "$c" "$id" "$provider" &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || failed=1; done
  [ "$failed" -eq 0 ] \
    || { err "one or more GitLab managers could not be quiesced; preserving the fleet for retry"; return 1; }
  [ "$count" -eq 0 ] || log "$count GitLab manager(s) drained in parallel"
}

cleanup_orphan_github_validations() {
  local names c snapshot id provider role index gen failed=0
  names="$(docker ps -a \
    --filter 'label=net.unraid.ci-runner-farm.managed=true' \
    --filter 'label=net.unraid.ci-runner-farm.provider=github' \
    --filter 'label=net.unraid.ci-runner-farm.role=validate' \
    --format '{{.Names}}')" \
    || { err "could not enumerate orphaned GitHub validation containers"; return 1; }
  for c in $names; do
    printf '%s' "$c" | grep -qE "^${NAME_PREFIX}-validate-[0-9a-f]{12}$" \
      || { err "refusing unexpected GitHub validation container name: $c"; failed=1; continue; }
    snapshot="$(owned_container_snapshot "$c" 99 github-validate)" \
      || { failed=1; continue; }
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    log "removing orphaned GitHub validation container $c"
    if ! docker rm -f "$id" >/dev/null 2>&1 \
       && docker inspect "$id" >/dev/null 2>&1; then
      err "could not remove owned GitHub validation container $c"
      failed=1
    fi
  done
  return "$failed"
}

# Full teardown: daemons, runner containers, and the shared pull-through mirror.
# Reached from the UI Stop button AND from plugin uninstall (the .plg remove step
# calls 'stop'), so it must leave nothing running. The mirror's on-pool cache dir
# ($CACHE_ROOT/registry-mirror) is intentionally left behind — like the config and
# token — so a later Start rebuilds the container with its cache warm; only the
# container is removed here, not the cached layers.
cmd_stop() {
  # Cancel every process that can create fleet resources before examining the
  # current Docker state. In particular, a sleeping boot worker must not wake
  # after Stop/uninstall and recreate the farm from retained credentials.
  boot_autostart_stop || return 1
  autoscale_stop || return 1
  imageupdate_stop || return 1
  reconcile_stop || return 1
  quiesce_gitlab_managers_for_stop || return 1
  local names c remaining remaining_managers stop_failed=0
  names="$(managed_names)" \
    || { err "could not enumerate managed runners before stop"; return 1; }
  if [ -z "$names" ]; then
    log "no managed runners running"
  else
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      log "stopping $c (graceful deregister)"
      remove_runner "$c" || stop_failed=1
    done <<< "$names"
  fi
  # A provider removal that failed closed can intentionally leave a manager and
  # its active job/sidecar intact. Do not then perform global cleanup underneath
  # that workload: host-socket job cleanup, mirror removal, and firewall/network
  # teardown would defeat the preservation guarantee and weaken strict egress.
  if ! remaining_managers="$(managed_names)"; then
    err "could not verify that all runner managers stopped"
    return 1
  fi
  if [ -n "$remaining_managers" ]; then
    err "runner managers remain after stop: $(printf '%s' "$remaining_managers" | tr '\n' ' ')"
    return 1
  fi
  # A manager deleted manually outside this transaction can leave the only
  # reusable token/system-ID pair capable of exact manager-only unregister.
  # Preserve that retry material and require the explicit break-glass action;
  # never make an invisible remote orphan by treating an empty Docker list as a
  # complete retirement.
  gitlab_assert_no_orphan_manager_configs || return 1
  # Host-socket executor jobs outlive a manager unless explicitly removed.
  gitlab_stop_cleanup || stop_failed=1
  # A manager can be manually removed or crash before cleanup. Remove only
  # ownership-verified orphans; a single spoofed label must never authorize a
  # force-removal of an unrelated fixed-name container.
  gitlab_cleanup_orphan_sidecars || stop_failed=1
  # Fixed-label verification is the final safety barrier for token clearing: a
  # caller must see a non-zero status if any manager or attributed job survives
  # and could retain credentials or continue executing after files are scrubbed.
  if ! remaining="$(docker ps -a --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' --format '{{.Names}}' 2>/dev/null)"; then
    err "could not verify GitLab job/sidecar cleanup"
    return 1
  fi
  if [ -n "$remaining" ]; then
    err "GitLab containers remain after stop: $(printf '%s' "$remaining" | tr '\n' ' ')"
    return 1
  fi
  # A killed Validate request can leave its detached GitHub test container after
  # the fleet itself is gone. It carries a distinct role and random name, so the
  # numeric-slot loops intentionally ignore it; clean it only through the full
  # immutable validation ownership contract before shared network/cache teardown.
  cleanup_orphan_github_validations || return 1
  # drop the shared image-cache container so uninstall/Stop don't orphan it
  if docker inspect "$MIRROR_NAME" >/dev/null 2>&1; then
    log "removing shared image cache ($MIRROR_NAME)"
    mirror_remove_owned || stop_failed=1
  fi
  # tear down the strict-mode egress rules and the now-empty dedicated network
  if ! firewall_clear; then
    stop_failed=1
  elif [ "$NETWORK_ISOLATION" != "off" ] && docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1; then
    if network_owned "$RUNNER_NETWORK"; then
      local network_id
      network_id="$(docker network inspect -f '{{.Id}}' "$RUNNER_NETWORK" 2>/dev/null)"
      if [ -z "$network_id" ]; then
        err "could not resolve owned isolated network $RUNNER_NETWORK"
        stop_failed=1
      else
        log "removing owned isolated runner network ($RUNNER_NETWORK)"
        if ! docker network rm "$network_id" >/dev/null 2>&1 \
           || docker network inspect "$network_id" >/dev/null 2>&1; then
          err "could not remove owned isolated runner network $RUNNER_NETWORK"
          stop_failed=1
        fi
      fi
    else
      log "preserving unowned pre-existing network $RUNNER_NETWORK"
    fi
  fi
  return "$stop_failed"
}

# ---- credential removal transactions --------------------------------------
# PHP owns validation and atomic writes, but credential removal also has to
# invalidate files derived by fleet mutations. Keep that whole operation behind
# fleet.lock: a queued Start/Recycle then reloads the now-empty secret snapshot
# instead of recreating an auth/config file from values loaded before it waited.
remove_plugin_file() {
  local file="$1"
  [ -e "$file" ] || [ -L "$file" ] || return 0
  rm -f "$file" 2>/dev/null || return 1
  [ ! -e "$file" ] && [ ! -L "$file" ]
}

scrub_host_registry_auth_locked() {
  local file failed=0
  # HOST_DOCKER_CONFIG normally lives on tmpfs. CFGDIR/docker-auth is its rare
  # fallback when the runtime directory cannot be created during early boot.
  for file in \
    "$HOST_DOCKER_CONFIG/config.json" \
    "$CFGDIR/docker-auth/config.json"; do
    remove_plugin_file "$file" || failed=1
  done
  return "$failed"
}

scrub_gitlab_runner_configs_locked() {
  local file failed=0
  # Remove only the token-bearing generated TOML. The stable system ID is the
  # manager identity and deliberately survives a token rotation/re-registration.
  for file in \
    "$CFGDIR"/gitlab-runners/*/config.toml \
    "$CFGDIR"/gitlab-runners/*/config.toml.tmp \
    "$CFGDIR"/gitlab-token-probe/config.toml \
    "$CFGDIR"/gitlab-token-probe/config.toml.tmp; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    remove_plugin_file "$file" || failed=1
  done
  return "$failed"
}

scrub_gitlab_registry_auth_locked() {
  local file failed=0
  for file in \
    "$CFGDIR"/gitlab-runners/*/docker/config.json \
    "$CFGDIR"/gitlab-runners/*/docker/config.json.tmp; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    remove_plugin_file "$file" || failed=1
  done
  return "$failed"
}

cmd_credential_clear_github_token() {
  local token_removed=false host_auth_removed=false ok=false error=""

  # Preserve the endpoint's historical partial-success contract: attempt the
  # independent host-auth scrub even if flash refuses the token unlink, and
  # report each result so the UI changes its token indicator only when warranted.
  if remove_plugin_file "$TOKEN_FILE"; then
    token_removed=true
    ACCESS_TOKEN=""
  fi
  scrub_host_registry_auth_locked && host_auth_removed=true

  if [ "$token_removed" = true ] && [ "$host_auth_removed" = true ]; then
    ok=true
  elif [ "$token_removed" != true ]; then
    error="could not remove token"
  else
    error="could not remove plugin host-pull Docker auth"
  fi

  if [ "$ok" = true ]; then
    printf '{"ok":true,"action":"clear-token","error":null,"token_removed":true,"host_auth_removed":true}\n'
    return 0
  fi
  printf '{"ok":false,"action":"clear-token","error":%s,"token_removed":%s,"host_auth_removed":%s}\n' \
    "$(printf '%s' "$error" | json_string)" "$token_removed" "$host_auth_removed"
  return 1
}

cmd_credential_clear_gitlab_runner() {
  local confirmed="${1:-0}" active=false token_removed=false
  local fleet_stop_requested=false fleet_stopped=false slot_configs_removed=false
  local stop_log="" remaining="" docker_checked=true failed=0 error=""
  [ "$CI_PROVIDER" = gitlab ] && active=true

  # This is intentionally repeated inside fleet.lock. PHP's fast pre-check is
  # only a UI convenience; Settings Apply may have changed the active provider
  # while this action waited for another lifecycle operation.
  if [ "$active" = true ] && [ "$confirmed" != 1 ]; then
    printf '{"ok":false,"action":"clear-gitlab-runner-token","confirmation_required":true,"error":%s,"token_removed":false,"fleet_stop_requested":true,"fleet_stopped":false,"slot_configs_removed":false,"log":""}\n' \
      "$(printf 'Clearing the active GitLab runner token gracefully drains each manager for up to %s seconds, then stops and unregisters it. Jobs still running after that timeout are forced to stop.' "$(gitlab_shutdown_timeout)" | json_string)"
    return 0
  fi

  # GitLab verification creates a disposable manager row. If its response or
  # immediate manager-only unregister was interrupted, the protected probe
  # config is the only exact cleanup credential. Never remove the bootstrap
  # token or report success until that saved transaction is complete.
  if ! gitlab_recover_pending_probe; then
    printf '{"ok":false,"action":"clear-gitlab-runner-token","error":%s,"token_removed":false,"fleet_stop_requested":false,"fleet_stopped":false,"slot_configs_removed":false,"log":""}\n' \
      "$(printf '%s' 'could not complete pending GitLab token-probe manager cleanup; retry before clearing the token' | json_string)"
    return 1
  fi

  # Remove the bootstrap copy first. If flash is read-only, keep managers and
  # their mounted config intact so a failed request cannot destroy a working farm.
  if ! remove_plugin_file "$GITLAB_RUNNER_TOKEN_FILE"; then
    printf '{"ok":false,"action":"clear-gitlab-runner-token","error":%s,"token_removed":false,"fleet_stop_requested":%s,"fleet_stopped":false,"slot_configs_removed":false,"log":""}\n' \
      "$(printf '%s' 'could not remove gitlab-runner-token' | json_string)" "$active"
    return 1
  fi
  token_removed=true
  GITLAB_RUNNER_TOKEN=""

  if [ "$active" = true ]; then
    fleet_stop_requested=true
    if stop_log="$(cmd_stop 2>&1)"; then
      fleet_stopped=true
    else
      failed=1
      error="could not completely stop and unregister the GitLab fleet"
    fi
    # An unregister warning represents a partial operation even if every local
    # container was subsequently removed; surface the lingering GitLab record.
    case "$stop_log" in
      *"could not unregister GitLab manager"*)
        fleet_stopped=false; failed=1
        error="one or more GitLab managers could not be unregistered" ;;
    esac
  fi

  if ! remaining="$(docker ps -a --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' --format '{{.Names}}' 2>/dev/null)"; then
    docker_checked=false; fleet_stopped=false; failed=1
    error="could not verify that GitLab containers were stopped"
  elif [ -n "$remaining" ]; then
    fleet_stopped=false; failed=1
    if [ "$active" = true ]; then
      error="GitLab containers remain after the stop request"
    else
      # Never stop a GitHub farm (or unexpected GitLab leftovers) from an
      # inactive-provider clear that the operator was not asked to confirm.
      error="GitLab containers remain while GitHub is active; stop them before removing per-slot runner configs"
    fi
  else
    if ! gitlab_assert_no_orphan_manager_configs; then
      failed=1
      fleet_stopped=false
      error="one or more missing GitLab managers still need unregister cleanup or an explicit local Force forget"
    elif [ "$active" = true ] && [ "$failed" = 0 ]; then
      fleet_stopped=true
    fi
  fi

  # A live manager can retain its bind-mounted config even after the host path
  # is unlinked. Only scrub once Docker positively reports no GitLab containers.
  if [ "$failed" = 0 ] && [ "$docker_checked" = true ] && [ -z "$remaining" ]; then
    if scrub_gitlab_runner_configs_locked; then
      slot_configs_removed=true
    else
      failed=1
      [ -n "$error" ] || error="could not remove one or more per-slot GitLab runner configs"
    fi
  fi

  if [ "$failed" = 0 ] && [ "$slot_configs_removed" = true ]; then
    printf '{"ok":true,"action":"clear-gitlab-runner-token","error":null,"token_removed":true,"fleet_stop_requested":%s,"fleet_stopped":%s,"slot_configs_removed":true,"log":%s}\n' \
      "$fleet_stop_requested" "$fleet_stopped" "$(printf '%s' "$stop_log" | json_string)"
    return 0
  fi
  [ -n "$error" ] || error="GitLab runner token was removed, but cleanup was incomplete"
  printf '{"ok":false,"action":"clear-gitlab-runner-token","error":%s,"token_removed":%s,"fleet_stop_requested":%s,"fleet_stopped":%s,"slot_configs_removed":%s,"log":%s}\n' \
    "$(printf '%s' "$error" | json_string)" "$token_removed" "$fleet_stop_requested" \
    "$fleet_stopped" "$slot_configs_removed" "$(printf '%s' "$stop_log" | json_string)"
  return 1
}

cmd_credential_clear_registry_token() {
  local token_removed=false slot_auth_removed=false host_auth_removed=false ok=false
  local reconcile_requested=false reconcile_started=false reconcile_error="" reconcile_log=""
  local warning="" error=""

  # Do not scrub derived files when the source credential could not be removed:
  # a later locked mutation would legitimately repopulate them from that source.
  if ! remove_plugin_file "$REGISTRY_TOKEN_FILE"; then
    printf '{"ok":false,"action":"clear-registry-token","error":%s,"token_removed":false,"slot_auth_removed":false,"host_auth_removed":false,"reconcile_requested":false,"reconcile_started":false,"warning":null}\n' \
      "$(printf '%s' 'could not remove registry-token' | json_string)"
    return 1
  fi
  token_removed=true
  REGISTRY_TOKEN=""

  scrub_gitlab_registry_auth_locked && slot_auth_removed=true
  scrub_host_registry_auth_locked && host_auth_removed=true

  if [ "$CI_PROVIDER" = gitlab ]; then
    reconcile_requested=true
    if reconcile_log="$(cmd_reconcile_config 2>&1)"; then
      reconcile_started=true
    else
      reconcile_error="${reconcile_log:-could not start reconcile}"
    fi
  fi

  if [ "$slot_auth_removed" = true ] && [ "$host_auth_removed" = true ]; then
    ok=true
    if [ "$CI_PROVIDER" = gitlab ]; then
      warning="Per-slot auth files were removed immediately. An image pull that already authenticated may still finish; queued slot reconciliation removes the credential from replacement managers."
    fi
  elif [ "$slot_auth_removed" != true ] && [ "$host_auth_removed" != true ]; then
    error="could not remove per-slot or plugin host-pull Docker auth"
  elif [ "$slot_auth_removed" != true ]; then
    error="could not remove one or more per-slot Docker auth files"
  else
    error="could not remove plugin host-pull Docker auth"
  fi

  printf '{"ok":%s,"action":"clear-registry-token","error":%s,"token_removed":%s,"slot_auth_removed":%s,"host_auth_removed":%s,"reconcile_requested":%s,"reconcile_started":%s' \
    "$ok" "$([ "$ok" = true ] && printf null || printf '%s' "$error" | json_string)" \
    "$token_removed" "$slot_auth_removed" "$host_auth_removed" "$reconcile_requested" "$reconcile_started"
  if [ "$reconcile_requested" = true ] && [ "$reconcile_started" != true ]; then
    printf ',"reconcile_error":%s' "$(printf '%s' "$reconcile_error" | json_string)"
  fi
  if [ -n "$warning" ]; then
    printf ',"warning":%s' "$(printf '%s' "$warning" | json_string)"
  else
    printf ',"warning":null'
  fi
  printf '}\n'
  [ "$ok" = true ]
}

cmd_scale() {
  local target="$1" failed=0
  pool_mode_enabled && { err "manual scale is not available in named-pool mode; edit each pool's fixed capacity and restart the fleet"; return 1; }
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
  local current
  current="$(current_count)" \
    || { err "could not count managed runners before scaling"; return 1; }
  if [ "$target" -gt "$current" ]; then
    provider_token_ready || { err "no valid $(provider_token_name) configured"; return 1; }
    [ "$CI_PROVIDER" = "gitlab" ] && gitlab_validate_settings || { [ "$CI_PROVIDER" != "gitlab" ] || return 1; }
    gitlab_assert_no_orphan_manager_configs || return 1
    # Growing an active fleet must not clear and rebuild the entire strict
    # firewall. Provision shared resources, then add only newly configured
    # endpoint exceptions (or repair genuinely missing base rules).
    provision_base || return 1
    firewall_prepare_replacement || return 1
    gitlab_cleanup_orphan_sidecars || { err "could not safely clean orphaned GitLab sidecars"; return 1; }
    # Slot numbers are identities, not a dense array. Failed replacements and
    # manually removed containers can leave holes, so fill only as many free
    # indices as needed to reach the requested count.
    local i=1 name all_names
    while :; do
      current="$(current_count)" \
        || { err "could not recount managed runners while scaling up"; return 1; }
      [ "$current" -lt "$target" ] && [ "$i" -le "$HARD_MAX" ] || break
      name="${NAME_PREFIX}-${i}"
      all_names="$(docker ps -a --format '{{.Names}}')" \
        || { err "could not enumerate Docker containers while selecting a free runner slot"; return 1; }
      if ! printf '%s\n' "$all_names" | grep -qx "$name"; then
        if ! start_one "$i"; then failed=1; break; fi
      fi
      i=$((i+1))
    done
  elif [ "$target" -lt "$current" ]; then
    # Remove actual highest-numbered slots; count-derived names are wrong when
    # the fleet contains holes (for example {1,4}).
    local c names snapshot id provider role index gen
    names="$(managed_names)" || return 1
    for c in $(printf '%s\n' "$names" | sort -rV); do
      current="$(current_count)" || return 1
      [ "$current" -le "$target" ] && break
      snapshot="$(managed_runner_snapshot "$c")" || { failed=1; break; }
      IFS='|' read -r id provider role index gen <<< "$snapshot"
      if remove_runner "$c" true "$id" "$provider"; then
        log "removed $c"
      else
        failed=1
        break
      fi
    done
  fi
  current="$(current_count)" \
    || { err "could not count managed runners after scaling"; return 1; }
  log "scaled to $current runner(s)"
  if [ "$current" -ne "$target" ] || [ "$failed" -ne 0 ]; then
    err "scale requested $target runner(s), but the fleet has $current after one or more lifecycle failures"
    return 1
  fi
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
    local image
    image="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)"
    printf "%-22s %-10s %-8s %-10s %s\n" "$c" "$st" "$(runner_state "$c")" "$((cpus/1000000000))c/$((mem/1024/1024/1024))g" "$image"
  done
}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }

# Runner and Docker diagnostics are not a trusted redaction boundary. Filter
# both the currently loaded secrets and recognizable CI-token shapes before any
# container/farm/build log reaches the UI or CLI. Quoted Bash substitution keeps
# arbitrary registry-password punctuation literal and out of subprocess argv.
redact_log_stream() {
  local line secret
  while IFS= read -r line || [ -n "$line" ]; do
    for secret in "$ACCESS_TOKEN" "$GITLAB_RUNNER_TOKEN" "$GITLAB_API_TOKEN" "$REGISTRY_TOKEN"; do
      [ "${#secret}" -ge 4 ] && line="${line//"$secret"/[REDACTED]}"
    done
    printf '%s\n' "$line"
  done | sed -E \
    -e 's/([A-Za-z0-9_.@-]{1,64}-)?glrt(r)?-[A-Za-z0-9_.-]{10,507}/[REDACTED_GITLAB_TOKEN]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{10,}/[REDACTED_GITHUB_TOKEN]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9_]{10,}/[REDACTED_GITHUB_TOKEN]/g' \
    -e 's/glpat-[A-Za-z0-9_-]{8,}/[REDACTED_GITLAB_TOKEN]/g'
}
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
  local img c sock inspect_sock=""; img="$(effective_image)"
  local id; id="$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)"
  # A remote GitLab DinD image intentionally never enters Unraid's host image
  # store. Inspect a live slot daemon before declaring it absent; if no slot has
  # pulled it yet, the source-aware UI still reports it as remotely configured
  # instead of telling the operator to build an unrelated local image.
  if [ -z "$id" ] && [ "$CI_PROVIDER" = gitlab ] && [ "$IMAGE_SOURCE" = remote ]; then
    for c in $(managed_names); do
      [ "$(container_provider "$c")" = gitlab ] || continue
      sock="$(gitlab_socket_path "$c")"
      [ "$sock" != /var/run/docker.sock ] || continue
      id="$(docker --host "unix://$sock" image inspect -f '{{.Id}}' "$img" 2>/dev/null)"
      if [ -n "$id" ]; then inspect_sock="$sock"; break; fi
    done
  fi
  if [ -z "$id" ]; then
    echo "{\"exists\":false,\"provider\":\"$CI_PROVIDER\",\"image\":\"$(echo "$img"|json_escape)\",\"source\":\"$(echo "$IMAGE_SOURCE"|json_escape)\"}"
    return 0
  fi
  local created size
  if [ -n "$inspect_sock" ]; then
    created="$(docker --host "unix://$inspect_sock" image inspect -f '{{.Created}}' "$img")"
    size="$(docker --host "unix://$inspect_sock" image inspect -f '{{.Size}}' "$img")"
  else
    created="$(docker image inspect -f '{{.Created}}' "$img")"
    size="$(docker image inspect -f '{{.Size}}' "$img")"
  fi
  local df="$CFGDIR/Dockerfile.$CI_PROVIDER"
  [ "$CI_PROVIDER" = github ] && [ ! -f "$df" ] && [ -f "$CFGDIR/Dockerfile" ] && df="$CFGDIR/Dockerfile"
  [ -f "$df" ] || df="/usr/local/emhttp/plugins/$PLUGIN/default.$CI_PROVIDER.Dockerfile"
  local base; base="$(grep -m1 '^FROM ' "$df" 2>/dev/null | awk '{print $2}')"
  local inuse=0 cid configured
  for c in $(managed_names); do
    [ "$(container_provider "$c")" = "$CI_PROVIDER" ] || continue
    if [ "$CI_PROVIDER" = gitlab ]; then
      configured="$(grep -m1 '^[[:space:]]*image[[:space:]]*=' "$(gitlab_slot_config_dir "$c")/config.toml" 2>/dev/null | sed 's/^[^=]*=[[:space:]]*"\([^"]*\)".*/\1/')"
      [ "$configured" = "$img" ] || continue
      sock="$(gitlab_socket_path "$c")"
      if [ "$sock" != /var/run/docker.sock ]; then
        cid="$(docker --host "unix://$sock" image inspect -f '{{.Id}}' "$img" 2>/dev/null)"
        [ "$cid" = "$id" ] || continue
      fi
      inuse=$((inuse+1))
    else
      cid="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
      [ "$cid" = "$id" ] && inuse=$((inuse+1))
    fi
  done
  echo "{\"exists\":true,\"provider\":\"$CI_PROVIDER\",\"image\":\"$(echo "$img"|json_escape)\",\"id\":\"$(echo "$id" | cut -c8-19)\",\"created\":\"$created\",\"size_mb\":$(( ${size:-0}/1024/1024 )),\"base\":\"$(echo "$base"|json_escape)\",\"in_use\":$inuse,\"dockerfile\":\"$(echo "$df"|json_escape)\",\"source\":\"$(echo "$IMAGE_SOURCE"|json_escape)\"}"
}

# "1.5GiB" / "512MiB" / "900kB" -> integer MiB (docker stats human units)
to_mib() {
  echo "$1" | awk '{
    v=$0; sub(/[A-Za-z]+$/,"",v); u=$0; sub(/^[0-9.]+/,"",u);
    if (u ~ /^G/) v*=1024; else if (u ~ /^k/ || u ~ /^K/) v/=1024; else if (u ~ /^B/) v/=1048576;
    printf "%d", v }'
}

memory_limit_bytes() {
  printf '%s' "$1" | awk '
    BEGIN { IGNORECASE=1 }
    {
      if (!match($0, /^[0-9]+([.][0-9]+)?[kmgt]?$/)) { print 0; exit }
      v=$0; u=tolower(substr(v,length(v),1));
      if (u ~ /[kmgt]/) v=substr(v,1,length(v)-1); else u="";
      if (u=="k") v*=1024; else if (u=="m") v*=1048576;
      else if (u=="g") v*=1073741824; else if (u=="t") v*=1099511627776;
      printf "%.0f", v
    }'
}

cmd_queued_refresh() {
  provider_call queued_refresh
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
  provider_call stats_refresh
}

cmd_stats_json() {
  local now cache_provider ts ok fail cancel other total age=999999 first
  now=$(date +%s)
  if [ -f "$RUNDIR/stats.cache" ]; then
    read -r first ts ok fail cancel other total < "$RUNDIR/stats.cache"
    case "$first" in
      github|gitlab) cache_provider="$first" ;;
      *) cache_provider=github; total="$other"; other="$cancel"; cancel="$fail"; fail="$ok"; ok="$ts"; ts="$first" ;;
    esac
    [ "$cache_provider" = "$CI_PROVIDER" ] && age=$(( now - ${ts:-0} )) || { age=999999; ok=0; fail=0; cancel=0; other=0; total=-1; }
  fi
  if [ "$age" -gt 300 ]; then
    ( flock -n 9 || exit 0; "$0" stats-refresh ) 9>"$RUNDIR/stats.lock" >/dev/null 2>&1 &
  fi
  echo "{\"provider\":\"$CI_PROVIDER\",\"ok\":${ok:-0},\"fail\":${fail:-0},\"cancel\":${cancel:-0},\"other\":${other:-0},\"total\":${total:--1},\"age\":$age}"
}

cmd_queued_json() {
  local now cache_provider ts count age=999999 first
  now=$(date +%s)
  if [ -f "$RUNDIR/queued.cache" ]; then
    read -r first ts count < "$RUNDIR/queued.cache"
    case "$first" in github|gitlab) cache_provider="$first" ;; *) cache_provider=github; count="$ts"; ts="$first" ;; esac
    [ "$cache_provider" = "$CI_PROVIDER" ] && age=$(( now - ${ts:-0} )) || { age=999999; count=-1; }
  fi
  # flock, not a plain lock file: the advisory lock is released by the kernel
  # even on SIGKILL/reboot, so a killed refresh can never wedge future refreshes.
  if [ "$age" -gt 60 ]; then
    ( flock -n 9 || exit 0; "$0" queued-refresh ) 9>"$RUNDIR/queued.lock" >/dev/null 2>&1 &
  fi
  echo "{\"provider\":\"$CI_PROVIDER\",\"queued\":${count:--1},\"age\":$age}"
}

cmd_recycle() {
  # Replace one slot without purging its Docker/cache roots. The old provider
  # owns removal ordering; the selected provider owns replacement startup.
  local name="$1" idx old_provider old_gen cur_gen image pool
  local snapshot target_id target_role current_id current_name
  local was_stale=false
  echo "$name" | grep -qE '^ci-runner-([0-9]+|[a-z][a-z0-9-]{0,23}-[0-9]+)$' \
    || { echo '{"ok":false,"error":"bad name"}'; return 1; }
  snapshot="$(managed_runner_snapshot "$name")" \
    || { echo '{"ok":false,"error":"runner is not an owned managed slot"}'; return 1; }
  IFS='|' read -r target_id old_provider target_role idx old_gen <<< "$snapshot"
  pool="$(runner_pool "$name")" \
    || { echo '{"ok":false,"error":"runner pool identity is unavailable"}'; return 1; }
  pool_activate "$pool" \
    || { echo '{"ok":false,"error":"runner belongs to an unavailable pool"}'; return 1; }
  cur_gen="$(crf_confgen)"
  if [ "$old_provider" != "$CI_PROVIDER" ] || [ "$old_gen" != "$cur_gen" ]; then was_stale=true; fi

  local other other_names other_snapshot stale_count
  other_names="$(managed_names)" \
    || { echo '{"ok":false,"error":"could not enumerate managed runners before recycle"}'; return 1; }
  for other in $other_names; do
    [ -n "$other" ] && [ "$other" != "$name" ] || continue
    other_snapshot="$(managed_runner_snapshot "$other")" \
      || { echo '{"ok":false,"error":"another runner failed its ownership check"}'; return 1; }
    on_expected_network "$other" || {
      log "recycle: WARNING — $other is still on a previous network; this slot will join the current one while the drain continues"
      break
    }
  done

  provider_token_ready \
    || { echo "{\"ok\":false,\"error\":\"no valid $(provider_token_name | json_escape) configured\"}"; return 1; }
  provider_validate_settings \
    || { echo '{"ok":false,"error":"invalid provider settings"}'; return 1; }
  provision_base \
    || { echo '{"ok":false,"error":"provisioning preflight failed (see log)"}'; return 1; }
  if [ "$NETWORK_ISOLATION" != off ] \
     && ! docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1; then
    echo '{"ok":false,"error":"runner network unavailable"}'; return 1
  fi

  # Add the new GitLab/registry endpoint ahead of the private-range drops while
  # retaining old endpoint rules for busy stale managers.
  firewall_prepare_replacement || {
    echo '{"ok":false,"error":"strict firewall preparation failed"}'; return 1
  }
  gitlab_assert_no_orphan_manager_configs || {
    echo '{"ok":false,"error":"missing GitLab manager identity requires cleanup before recycle"}'; return 1
  }
  gitlab_cleanup_orphan_sidecars || {
    echo '{"ok":false,"error":"could not safely clean orphaned GitLab sidecars"}'; return 1
  }

  # Validate replacement images before touching the old manager. GitHub can
  # safely pre-mint its short registration token. GitLab must defer config.toml
  # generation until the old manager has unregistered against its old config.
  if [ "$CI_PROVIDER" = gitlab ]; then
    docker image inspect "$GITLAB_RUNNER_IMAGE" >/dev/null 2>&1 \
      || host_docker_pull "$GITLAB_RUNNER_IMAGE" >/dev/null 2>&1 \
      || { echo '{"ok":false,"error":"cannot pull GitLab manager image"}'; return 1; }
    # Exercise a temporary target-equivalent Docker endpoint, generated TOML,
    # registry auth/CA, pull policy, and inert job before touching the old slot.
    # This is intentionally stronger than a host-side image inspection because
    # GitLab DinD owns its own image store and trust configuration.
    gitlab_validate \
      || { echo '{"ok":false,"error":"GitLab replacement validation failed; existing slot was preserved"}'; return 1; }
    gitlab_verify_manager_token "$name" \
      || { echo '{"ok":false,"error":"GitLab rejected the replacement runner token/system ID; existing slot was preserved"}'; return 1; }
    image="$(effective_image)"
  else
    # A GitLab manager may drain for up to 24 hours, while a GitHub runner
    # registration token expires after one hour. Prove the PAT permission now,
    # but mint the token used by Docker only after the old slot is gone.
    github_replacement_preflight "$idx" \
      || { echo '{"ok":false,"error":"cannot verify GitHub replacement permission"}'; return 1; }
    image="$(effective_image)"
  fi
  if ! recycle_image_preflight "$image"; then
    if [ "$IMAGE_SOURCE" = remote ]; then
      echo '{"ok":false,"error":"cannot pull replacement image"}'
    else
      echo '{"ok":false,"error":"built-in replacement image is unavailable"}'
    fi
    return 1
  fi

  # Replacement preflight may take minutes. Re-resolve both directions without
  # trusting the mutable name before crossing the destructive boundary. Labels
  # themselves are immutable for a container ID and were validated above.
  current_id="$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null || true)"
  current_name="$(docker inspect -f '{{.Name}}' "$target_id" 2>/dev/null || true)"
  if [ "$current_id" != "$target_id" ] || [ "$current_name" != "/$name" ]; then
    echo '{"ok":false,"error":"runner changed during replacement preflight; retry"}'
    return 1
  fi

  if ! remove_runner "$name" false "$target_id" "$old_provider"; then
    echo '{"ok":false,"error":"remove or provider cleanup failed; replacement was not started"}'
    return 1
  fi

  # Never start a replacement over a name that an external Docker client claimed
  # while the old immutable ID was draining or unregistering.
  if docker inspect "$target_id" >/dev/null 2>&1; then
    echo '{"ok":false,"error":"remove returned but the original runner still exists"}'; return 1
  fi
  current_id="$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null || true)"
  if [ -n "$current_id" ]; then
    echo '{"ok":false,"error":"runner name was claimed during replacement; refusing to overwrite it"}'; return 1
  fi

  log "recycling $name (provider $old_provider -> $CI_PROVIDER)"
  if [ "$CI_PROVIDER" = gitlab ]; then
    if ! start_one "$idx"; then
      echo '{"ok":false,"error":"removed but GitLab replacement failed to start"}'; return 1
    fi
  else
    if ! build_args "$idx"; then
      echo '{"ok":false,"error":"removed but a fresh GitHub registration token could not be minted"}'; return 1
    fi
    # Capture the real docker error (don't swallow it): an image-pull failure,
    # a port collision, or a rejected resource limit was otherwise lost behind
    # the generic message below, with the old runner already removed. Keep it in
    # a variable rather than a temp file so a full RUNDIR cannot stop the
    # replacement from being attempted at all. Docker diagnostics are untrusted,
    # so the detail is redacted on the way to the log.
    local rout
    if ! rout="$(docker run "${ARGS[@]}" 2>&1 >/dev/null)"; then
      err "recycle: docker run failed:"
      printf '%s\n' "$rout" | redact_log_stream >&2
      clear_args_tmpdir
      echo '{"ok":false,"error":"removed but not recreated"}'; return 1
    fi
    clear_args_tmpdir
  fi

  # Verify final state without converting a failed Docker inspect into zero.
  # A live fleet is finalized additively; obsolete tagged rules are retired only
  # after Stop leaves no managed runner, so this call can never open a clear/readd
  # gap underneath the replacement that just started.
  if [ "$was_stale" = true ] && [ "$NETWORK_ISOLATION" = strict ]; then
    stale_count="$(count_stale_runners)" \
      || { echo '{"ok":false,"error":"replacement started, but stale-runner verification failed"}'; return 1; }
    if [ "$stale_count" -eq 0 ] && ! firewall_apply; then
      echo '{"ok":false,"error":"replacement started, but strict firewall finalization failed"}'
      return 1
    fi
  fi
  echo '{"ok":true}'
}

cmd_force_forget_gitlab() {
  local name="$1"
  # Validate the target before changing fleet-wide daemon state. A stale UI
  # request or fixed-name collision must be a side-effect-free failure.
  gitlab_force_forget_target_ready "$name" || return 1
  boot_autostart_stop || return 1
  autoscale_stop || return 1
  imageupdate_stop || return 1
  reconcile_stop || return 1
  gitlab_force_forget_local "$name" || return 1
  log "WARNING: locally forgot $name without contacting GitLab; remove any lingering offline manager from the GitLab UI"
}


cmd_logs_tail() {
  local name="$1" count="${2:-150}" snapshot id rc
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$count" -ge 1 ] 2>/dev/null && [ "$count" -le 2000 ] 2>/dev/null || return 1
  snapshot="$(managed_runner_snapshot "$name")" || return 1
  id="${snapshot%%|*}"
  docker logs --tail "$count" "$id" 2>&1 | redact_log_stream
  rc="${PIPESTATUS[0]}"
  return "$rc"
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
  # Line (all free-form values are base64):
  # name cpu mem phase job started provider project job_id job_url ref ref_url
  # repo pr branch run_id. The final four GitHub fields remain for UI/API
  # compatibility while the provider-neutral fields work for both adapters.
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
  local statsraw stats_targets="" c provider stat_target
  : > "$RUNDIR/usage.targets.tmp"
  # GitHub work runs in the managed container itself. In isolated GitLab mode,
  # work runs under the outer DinD sidecar cgroup, so sidecar stats represent
  # the aggregate job+services+daemon slot. Host-socket jobs cannot be safely
  # attributed among managers and intentionally report usage unavailable.
  for c in $names; do
    provider="$(container_provider "$c")"
    stat_target="$("${provider}_usage_stat_target" "$c")"
    printf '%s %s %s\n' "$c" "$provider" "$stat_target" >> "$RUNDIR/usage.targets.tmp"
    [ "$stat_target" != _ ] && stats_targets="$stats_targets $stat_target"
  done
  # shellcheck disable=SC2086  # stats_targets is a validated container-name list assembled above
  [ -n "$stats_targets" ] && statsraw="$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' $stats_targets 2>/dev/null)"
  : > "$RUNDIR/usage.cache.tmp"
  for c in $names; do
    [ -z "$c" ] && continue
    local srow cpu="-1" mem_mib=-1 targetrow phase
    targetrow="$(grep -m1 -- "^${c} " "$RUNDIR/usage.targets.tmp")"
    read -r _ provider stat_target <<< "$targetrow"
    if [ "$stat_target" != _ ]; then
      srow="$(printf '%s\n' "$statsraw" | grep -m1 -- "^${stat_target}|")"
      cpu="$(printf '%s' "$srow" | cut -d'|' -f2 | tr -d '%' | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1)"; cpu="${cpu:--1}"
      [ -n "$srow" ] && mem_mib="$(to_mib "$(printf '%s' "$srow" | cut -d'|' -f3 | awk -F' / ' '{print $1}')")"
    fi
    phase="$(runner_state "$c")"
    local job="" jstarted="_" project="" job_id="_" job_url="" ref="" ref_url=""
    local jrepo="" jpr="_" jbranch="" jrun="_"
    if [ "$phase" = "busy" ]; then
      "${provider}_usage_context" "$c"
    fi
    printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
      "$c" "${cpu:-0}" "${mem_mib:-0}" "$phase" "$(_b64 "$job")" "$jstarted" "$provider" \
      "$(_b64 "$project")" "$job_id" "$(_b64 "$job_url")" "$(_b64 "$ref")" "$(_b64 "$ref_url")" \
      "$(_b64 "$jrepo")" "$jpr" "$(_b64 "$jbranch")" "$jrun" >> "$RUNDIR/usage.cache.tmp"
  done
  mv "$RUNDIR/usage.cache.tmp" "$RUNDIR/usage.cache" 2>/dev/null
  rm -f "$RUNDIR/usage.targets.tmp"
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
  local inspraw="" cur_gen stalec=0 side_names inspect_names
  cur_gen="$(crf_confgen)"
  side_names="$(docker ps -a --filter 'label=net.unraid.ci-runner-farm.sidecar=true' --format '{{.Names}}' 2>/dev/null)"
  inspect_names="$names $side_names"
  # shellcheck disable=SC2086  # $names is intentionally word-split into one arg per runner
  [ -n "$names" ] && inspraw="$(docker inspect -f '{{.Name}}|{{.State.Status}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.Memory}}|{{index .Config.Labels "net.unraid.ci-runner-farm.confgen"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.provider"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.pool"}}' $inspect_names 2>/dev/null)"
  local out="["; local first=1
  for c in $names; do
    [ -z "$c" ] && continue
    local irow st cpus mem cgen row_provider row_pool expected_gen stale=false
    # {{.Name}} carries a leading '/', so field 1 is "/name"; split the pipe-delimited
    # inspect row with one read builtin instead of three cut subshells per runner.
    irow="$(printf '%s\n' "$inspraw" | grep -m1 -E "^/?${c}\|")"
    IFS='|' read -r _ st cpus mem cgen row_provider row_pool <<< "$irow"
    [ "$row_provider" = gitlab ] || row_provider=github
    [ "$row_pool" = '<no value>' ] && row_pool=""
    row_pool="${row_pool:-default}"
    "${row_provider}_status_resources" "$c" "$inspraw"
    # Any managed runner whose baked-config fingerprint differs from the current
    # cfg predates a change. Include stopped fail-closed managers: hiding them
    # would make the UI claim migration is complete while unregister/retry work
    # is still outstanding.
    expected_gen="$(expected_runner_confgen "$c" 2>/dev/null || true)"
    [ -n "$expected_gen" ] || expected_gen="$cur_gen"
    [ "$cgen" != "$expected_gen" ] && { stale=true; stalec=$((stalec+1)); }
    # phase + cpu/mem usage + job context: all from the background cache line
    # New cache rows contain provider-neutral metadata followed by the legacy
    # GitHub fields; pre-provider cache rows are accepted for a seamless upgrade.
    local urow live_provider="$row_provider" phase="starting" cpu_pct=-1 mem_used_mib=-1
    local job="" jstarted="" project="" job_id="" job_url="" ref="" ref_url=""
    local jrepo="" jpr="" jbranch="" jrun=""
    urow="$(printf '%s\n' "$usage" | grep -m1 -- "^${c} ")"
    if [ -n "$urow" ]; then
      # shellcheck disable=SC2086  # deliberate positional split of the fixed cache line
      set -- $urow
      if { [ "${7:-}" = github ] || [ "${7:-}" = gitlab ]; } \
         && [ "$#" -ge 16 ] && [ "$7" = "$live_provider" ]; then
        cpu_pct="$2"; mem_used_mib="$3"; phase="$4"; job="$(_d64 "$5" | json_escape)"; jstarted="$(_uu "$6")"
        project="$(_d64 "$8" | json_escape)"; job_id="$(_uu "$9")"
        job_url="$(_d64 "${10}" | json_escape)"; ref="$(_d64 "${11}" | json_escape)"; ref_url="$(_d64 "${12}" | json_escape)"
        jrepo="$(_d64 "${13}" | json_escape)"; jpr="$(_uu "${14}")"
        jbranch="$(_d64 "${15}" | json_escape)"; jrun="$(_uu "${16}")"
      elif [ "${7:-}" != github ] && [ "${7:-}" != gitlab ] \
           && [ "$live_provider" = github ] && [ "$#" -ge 10 ]; then
        # Pre-provider cache rows are valid only for live GitHub containers.
        # Derive the provider-neutral URLs so compatibility consumers receive
        # the same fields as newly refreshed rows.
        cpu_pct="$2"; mem_used_mib="$3"; phase="$4"; job="$(_d64 "$5" | json_escape)"; jstarted="$(_uu "$6")"
        jrepo="$(_d64 "$7" | json_escape)"; jpr="$(_uu "$8")"
        jbranch="$(_d64 "$9" | json_escape)"; jrun="$(_uu "${10}")"
        project="$jrepo"; job_id="$jrun"
        [ -n "$jrepo" ] && [ "$jrun" != _ ] && job_url="https://github.com/$jrepo/actions/runs/$jrun"
        if [ "$jpr" != _ ] && [ -n "$jpr" ]; then
          ref="PR #$jpr"; ref_url="https://github.com/$jrepo/pull/$jpr"
        else
          ref="$jbranch"
          [ -n "$jrepo" ] && [ -n "$jbranch" ] && ref_url="https://github.com/$jrepo/tree/$(urlencode "$jbranch")"
        fi
      fi
    fi
    case "$cpu_pct" in ''|*[!0-9.-]*) cpu_pct=-1 ;; esac
    case "$mem_used_mib" in ''|*[!0-9-]*) mem_used_mib=-1 ;; esac
    case "$jpr" in *[!0-9]*) jpr="" ;; esac
    case "$jrun" in *[!0-9]*) jrun="" ;; esac
    case "$job_id" in *[!0-9]*) job_id="" ;; esac
    [ $first -eq 0 ] && out+=","
    out+="{\"name\":\"$(echo "$c"|json_escape)\",\"provider\":\"$row_provider\",\"pool\":\"$(printf '%s' "$row_pool"|json_escape)\",\"state\":\"${st:-unknown}\",\"phase\":\"$phase\",\"job\":\"${job}\",\"job_started\":\"${jstarted}\",\"project\":\"${project}\",\"job_id\":\"${job_id}\",\"job_url\":\"${job_url}\",\"ref\":\"${ref}\",\"ref_url\":\"${ref_url}\",\"repo\":\"${jrepo}\",\"pr\":\"${jpr}\",\"branch\":\"${jbranch}\",\"run_id\":\"${jrun}\",\"cpus\":$(( ${cpus:-0}/1000000000 )),\"mem_gb\":$(( ${mem:-0}/1024/1024/1024 )),\"cpu_pct\":${cpu_pct:-0},\"mem_used_mib\":${mem_used_mib:-0},\"stale\":${stale}}"
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
  local configured="$RUNNER_COUNT" pools='[]' rec pool pfirst=1 pcount labels pimage pjson='['
  if pool_mode_enabled && pool_config_validate "$RUNNER_MODE" "$RUNNER_POOLS" "$GH_SCOPE" "$CI_PROVIDER"; then
    configured=0
    while IFS= read -r rec; do
      pool="$(printf '%s' "$rec" | cut -d'|' -f2)"; pcount="$(pool_fixed "$pool")"
      labels="$(pool_effective_labels "$pool")"; pimage="$(pool_image "$pool")"
      configured=$((configured+pcount))
      [ "$pfirst" -eq 0 ] && pjson+=','
      pjson+="{\"id\":\"$(printf '%s' "$pool"|json_escape)\",\"labels\":\"$(printf '%s' "$labels"|json_escape)\",\"configured\":${pcount},\"image\":\"$(printf '%s' "$pimage"|json_escape)\"}"
      pfirst=0
    done < <(pool_records)
    pools="${pjson}]"
  fi
  echo "{\"provider\":\"$CI_PROVIDER\",\"mode\":\"$RUNNER_MODE\",\"count\":$(echo "$names" | grep -c . ),\"configured\":${configured},\"token\":$(pool_tokens_ready 2>/dev/null && echo true || echo false),\"autoscale\":\"${as} [${AUTOSCALE_MIN}-${AUTOSCALE_MAX}, buffer ${AUTOSCALE_MIN_IDLE}]\",\"image_autoupdate\":\"$(echo "$iu" | json_escape)\",\"warning\":\"${warn}\",\"security\":\"${sec}\",\"stale\":${stalec},\"pools\":${pools},\"runners\":${out}}"
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

cmd_logs() {
  local index="${1:-1}" count="${2:-100}" name snapshot id rc
  case "$index:$count" in *[!0-9:]*) return 1 ;; esac
  [ "$index" -ge 1 ] 2>/dev/null && [ "$count" -ge 1 ] 2>/dev/null \
    && [ "$count" -le 2000 ] 2>/dev/null || return 1
  name="${NAME_PREFIX}-${index}"
  snapshot="$(managed_runner_snapshot "$name")" || return 1
  id="${snapshot%%|*}"
  docker logs --tail "$count" -f "$id" 2>&1 | redact_log_stream
  rc="${PIPESTATUS[0]}"
  return "$rc"
}

cmd_validate() {
  validate_runner_mode || { err "$POOL_CONFIG_ERROR"; return 1; }
  local rec pool failed=0
  if pool_mode_enabled; then
    while IFS= read -r rec; do
      pool="$(printf '%s' "$rec" | cut -d'|' -f2)"
      pool_activate "$pool" || { failed=1; continue; }
      log "validating provider contract for pool $pool with image $(effective_image)"
      provider_call validate || failed=1
    done < <(pool_records)
    return "$failed"
  fi
  pool_activate default
  provider_call validate
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
  local root d m dirs removed=0 active
  active="$(docker ps -a --filter 'label=net.unraid.ci-runner-farm.managed=true' --format '{{.Names}}' 2>/dev/null)" \
    || { err "cannot verify managed runners before pruning cache"; return 1; }
  [ -z "$active" ] \
    || { err "refusing to prune cache while runner/validation containers exist; Stop the fleet and finish Validate first"; return 1; }
  active="$(docker ps -a --filter 'label=net.unraid.ci-runner-farm.sidecar=true' --format '{{.Names}}' 2>/dev/null)" \
    || { err "cannot verify GitLab sidecars before pruning cache"; return 1; }
  [ -z "$active" ] \
    || { err "refusing to prune cache while GitLab sidecars exist; complete Stop/Force forget first"; return 1; }
  active="$(docker ps -a --filter 'label=com.gitlab.gitlab-runner.managed=true' --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' --format '{{.Names}}' 2>/dev/null)" \
    || { err "cannot verify host-socket GitLab executor containers before pruning cache"; return 1; }
  [ -z "$active" ] \
    || { err "refusing to prune cache while GitLab executor containers exist"; return 1; }
  root="$(crf_safe_cache_root)" || { err "refusing to prune-cache: CACHE_ROOT='$CACHE_ROOT' is unsafe (system dir, share/pool root, or unresolvable — point it at /mnt/<pool>/<subdir>)"; return 1; }
  dirs="docker work dind-logs gitlab-cache gitlab-sockets registry-mirror $CACHE_PKG_DIRS"
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
  txt="$([ -f "$log" ] && tail -n 120 "$log" | redact_log_stream)"
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
  txt="$([ -f "$src" ] && tail -n 150 "$src" | grep -v 'swap limit capabilities' | tail -n 60 | redact_log_stream)"
  printf '{"ok":true,"log":%s}\n' "$(printf '%s' "$txt" | json_string)"
}

cmd_build_image() {
  # Build the runner image from the editable Dockerfile. Uses a CLEAN temp
  # context (only the Dockerfile) so the token/config never enter the build.
  local df="$CFGDIR/Dockerfile.$CI_PROVIDER" tag
  # Upgrade compatibility: an existing unsuffixed Dockerfile remains the GitHub
  # editor source until build-plg.sh migrates it to Dockerfile.github.
  [ "$CI_PROVIDER" = github ] && [ ! -f "$df" ] && [ -f "$CFGDIR/Dockerfile" ] && df="$CFGDIR/Dockerfile"
  [ -f "$df" ] || df="/usr/local/emhttp/plugins/$PLUGIN/default.$CI_PROVIDER.Dockerfile"
  [ -f "$df" ] || { err "no Dockerfile found"; return 1; }
  tag="$(builtin_image)"
  local ctx; ctx="$(mktemp -d)"
  cp "$df" "$ctx/Dockerfile"
  log "building $CI_PROVIDER image '$tag' from $df"
  docker build -t "$tag" "$ctx"; local rc=$?
  rm -rf "$ctx"
  if [ $rc -eq 0 ]; then
    log "build complete: $tag — set Image source to Built-in and restart/reconcile the $CI_PROVIDER fleet to use it"
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
  ( umask 077; printf '%s\n' "$$" > "$BOOT_AUTOSTART_PID" ) \
    || { err "boot-autostart: could not publish worker PID"; return 1; }
  trap 'rm -f "$BOOT_AUTOSTART_PID" 2>/dev/null || true' EXIT
  trap 'rm -f "$BOOT_AUTOSTART_PID" 2>/dev/null || true; exit 0' HUP INT TERM
  provider_token_ready || { log "boot-autostart: no valid $(provider_token_name) configured yet — skipping"; return 0; }
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

boot_autostart_stop() {
  stop_worker_group "boot-autostart" "$BOOT_AUTOSTART_PID" '[r]unner-farm.sh boot-autostart'
}

# Unraid invokes event/stopping_docker before it stops the Docker service. A
# GitLab manager's SIGQUIT drain is useful only while its per-slot DinD daemon
# is still alive: once that privileged sidecar disappears, the active job and
# helper containers disappear with it. Stop every running GitLab manager in
# parallel here so all of them stop accepting work immediately and can finish
# against their still-live sidecars. Leave managers, sidecars, config.toml, and
# system IDs in place; docker_started restarts the same identities afterward.
# GitHub containers are deliberately untouched, preserving their existing
# Docker-service event behavior.
cmd_docker_stopping_locked() {
  local c timeout pids="" pid failed=0 count=0 names snapshot id provider role index gen
  names="$(managed_names)" || return 1
  for c in $names; do
    [ -n "$c" ] || continue
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    timeout="$("${provider}_docker_stopping_timeout" "$id")"
    case "$timeout" in ''|*[!0-9]*) timeout=0 ;; esac
    [ "$timeout" -gt 0 ] || continue
    if ! docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null | grep -qx true; then
      docker inspect "$id" >/dev/null 2>&1 \
        || { err "docker shutdown: could not inspect owned manager $c"; return 1; }
      continue
    fi
    count=$((count+1))
    log "docker shutdown: gracefully quiescing $provider manager $c"
    provider_stop_owned_runner "$c" "$id" "$provider" &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || failed=1; done
  if [ "$failed" -ne 0 ]; then
    err "docker shutdown: one or more GitLab managers could not be quiesced"
    return 1
  fi
  [ "$count" -eq 0 ] || log "docker shutdown: $count GitLab manager(s) quiesced; preserving their local identities for restart"
}

cmd_docker_stopping() {
  boot_autostart_stop || return 1
  autoscale_stop || return 1
  imageupdate_stop || return 1
  reconcile_stop || return 1

  # Avoid changing the legacy GitHub-only event path beyond stopping its two
  # host daemons. During a provider transition, however, a stale GitLab manager
  # still needs the pre-stop drain even when CI_PROVIDER already says github.
  local c timeout lock_wait=0 names snapshot id provider role index gen
  names="$(managed_names)" || return 1
  for c in $names; do
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role index gen <<< "$snapshot"
    timeout="$("${provider}_docker_stopping_timeout" "$id")"
    case "$timeout" in ''|*[!0-9]*) timeout=0 ;; esac
    [ "$timeout" -gt "$lock_wait" ] && lock_wait="$timeout"
  done

  # Always acquire the fleet lock, even when the first snapshot is GitHub-only.
  # A concurrent Start may be holding it and can spawn a GitLab manager/worker
  # after the pre-lock stop calls. Re-stop every creator under the lock, then
  # enumerate the authoritative post-lock fleet through immutable snapshots.
  lock_wait=$((lock_wait + 60))
  ( flock -w "$lock_wait" 8 || {
      err "docker shutdown: fleet mutation did not release its lock in time"
      exit 1
    }
    reload_locked_snapshot || exit 1
    boot_autostart_stop || exit 1
    autoscale_stop || exit 1
    imageupdate_stop || exit 1
    reconcile_stop || exit 1
    cmd_docker_stopping_locked
  ) 8>"$RUNDIR/fleet.lock"
}

# Test harnesses may source the engine to exercise adapter functions with
# mocked Docker/curl endpoints. Production execution never sets this flag.
if [ "${CRF_SOURCE_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

case "${1:-status}" in
  start)        with_fleet_lock wait cmd_start ;;
  boot-autostart)   cmd_boot_autostart ;;
  docker-stopping)  cmd_docker_stopping ;;
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
  force-forget-gitlab) with_fleet_lock wait cmd_force_forget_gitlab "${2:?usage: force-forget-gitlab <name>}" ;;
  reconcile-config) with_fleet_lock wait cmd_reconcile_config ;;
  reconcile-drain)  ( flock -w 5 7 || { echo "reconcile: a drain is already running (it re-reads the cfg each pass and will pick up this change) — skipping duplicate" >>"$RUNDIR/autoscale.log"; exit 0; }; cmd_reconcile_drain ) 7>"$RUNDIR/reconcile.lock" ;;
  logs-tail)    cmd_logs_tail "${2:?usage: logs-tail <name> [n]}" "${3:-150}" ;;
  logs)         cmd_logs "${2:-1}" "${3:-100}" ;;
  validate)         with_fleet_lock wait cmd_validate ;;
  build-image)      cmd_build_image ;;
  build-async)      cmd_build_async ;;
  build-status)     cmd_build_status ;;
  farm-log)         cmd_farm_log ;;
  prune-cache)      with_fleet_lock wait cmd_prune_cache ;;
  autoscale-daemon) autoscale_daemon ;;
  autoscale-tick)   with_fleet_lock wait autoscale_tick ;;
  autoscale-start)  autoscale_start ;;
  autoscale-stop)   autoscale_stop ;;
  autoscale-status) autoscale_status ;;
  imageupdate-daemon) imageupdate_daemon ;;
  imageupdate-tick)   with_fleet_lock wait imageupdate_tick ;;
  imageupdate-start)  imageupdate_start ;;
  imageupdate-stop)   imageupdate_stop ;;
  imageupdate-status) imageupdate_status ;;
  credential-clear-github-token) with_fleet_lock wait cmd_credential_clear_github_token ;;
  credential-clear-gitlab-runner) with_fleet_lock wait cmd_credential_clear_gitlab_runner "${2:-0}" ;;
  credential-clear-registry-token) with_fleet_lock wait cmd_credential_clear_registry_token ;;
  *) echo "usage: $0 {start|boot-autostart|docker-stopping|stop|restart|scale N|recycle NAME|force-forget-gitlab NAME|status|status-json|logs i|validate|build-image|prune-cache|autoscale-tick|autoscale-start|autoscale-stop|autoscale-status|imageupdate-tick|imageupdate-start|imageupdate-stop|imageupdate-status}"; exit 1 ;;
esac
