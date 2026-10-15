#!/usr/bin/env bash
# GitHub invokes this synchronously after the assigned job's steps finish.
# Keep stable warm caches unless explicitly opted into pressure eviction.
# Job-scoped state is disposable; Docker arbitrates non-forced removal.
set -uo pipefail

# Preserve the image's original hook, including its job-failing exit status.
# GitHub invokes shell hooks with bash -e and PowerShell hooks with pwsh.
image_status=0
if [ -z "${1:-}" ] && [ -n "${CRF_IMAGE_JOB_COMPLETED_HOOK:-}" ]; then
  case "$CRF_IMAGE_JOB_COMPLETED_HOOK" in
    "$0"|/opt/ci-runner-farm/job-completed.sh) exit 1 ;;
    /*.sh) bash -e "$CRF_IMAGE_JOB_COMPLETED_HOOK" || image_status=$? ;;
    /*.ps1) pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Unrestricted -File "$CRF_IMAGE_JOB_COMPLETED_HOOK" || image_status=$? ;;
    *) exit 1 ;;
  esac
fi

[ "${CRF_JOB_CLEANUP_DIND:-}" = 1 ] && [ "${GITHUB_ACTIONS:-}" = true ] || exit "$image_status"
[[ "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]] && [[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] || exit "$image_status"

case "${1:-}" in
  --cleanup|--prune) ;;
  *)
    # Hook failure must not fail a completed build. Bound both the whole pass
    # and each Docker call; unknown cleanup stays visible in the job log.
    if ! timeout -k 2 30 bash "$0" --cleanup; then
      echo '[ci-runner-farm] job cache cleanup incomplete; retained uncertain caches' >&2
    fi
    if ! timeout -k 2 120 bash "$0" --prune; then
      echo '[ci-runner-farm] job Docker prune incomplete; retained unpruned state' >&2
    fi
    exit "$image_status"
    ;;
esac

# A workflow's remote Docker context must never redirect host maintenance.
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
local_docker() { timeout -k 1 5 docker --host unix:///var/run/docker.sock "$@"; }
[ "$(local_docker info --format '{{.DockerRootDir}}')" = /var/lib/docker ] || exit 1

minimum="${CRF_DOCKER_CACHE_MIN_FREE_PERCENT:-15}"
[[ "$minimum" =~ ^(0|[1-9][0-9]?|100)$ ]] || exit 1
cache_pressure() {
  local filesystem usage total available
  filesystem="$(timeout -k 1 3 df -Pk /var/lib/docker)" || return 2
  usage="$(printf '%s\n' "$filesystem" | awk 'NR==2 {print $2 "|" $4}')"
  IFS='|' read -r total available <<< "$usage"
  [[ "$total" =~ ^[1-9][0-9]{0,14}$ && "$available" =~ ^(0|[1-9][0-9]{0,14})$ ]] || return 2
  [ "$available" -le "$total" ] || return 2
  [ "$((available * 100 / total))" -lt "$minimum" ]
}

if [ "$1" = --prune ]; then
  # A persistent DinD store outlives every job, so anything a job leaves behind
  # accumulates until the pool fills. The runner takes no job until this hook
  # returns, so nothing else uses this daemon now. Reclaim state no later job
  # can name; under storage pressure also drop every image no container uses.
  # Stopped buildx builders are kept so their warm state and image survive.
  prune_docker() { timeout -k 2 60 docker --host unix:///var/run/docker.sock "$@" >/dev/null; }
  api="$(local_docker version --format '{{.Server.APIVersion}}')" || exit 1
  [[ "$api" =~ ^1\.([1-9][0-9]{0,2})$ ]] || exit 1
  api_minor="${BASH_REMATCH[1]}"
  stopped="$(local_docker ps -a --no-trunc --filter status=exited --filter status=created --filter status=dead --format '{{.ID}} {{.Names}}')" || exit 1
  count=0 incomplete=0
  while read -r id name; do
    [[ "$id" =~ ^[0-9a-f]{64}$ ]] || continue
    case "$name" in buildx_buildkit_*) continue ;; esac
    count=$((count + 1)); [ "$count" -le 64 ] || break
    # Never force removal: a container restarted meanwhile stays, reported
    # as incomplete after the remaining best-effort pruning.
    local_docker rm -v "$id" >/dev/null || incomplete=1
  done <<< "$stopped"
  # Since API 1.42 volume prune removes only anonymous volumes. Older daemons
  # would also remove unused named volumes, which may be deliberate caches.
  if [ "$api_minor" -ge 42 ]; then
    prune_docker volume prune -f || exit 1
  fi
  prune_docker image prune -f || exit 1
  prune_docker builder prune -f || exit 1
  if cache_pressure; then
    prune_docker image prune -a -f || exit 1
    echo '[ci-runner-farm] removed unused job images under storage pressure'
  else
    [ "$?" -eq 1 ] || exit 1
  fi
  exit "$incomplete"
fi
volumes="$(local_docker volume ls --format '{{.Name}}')" || exit 1
count=0
while IFS= read -r name; do
  [[ "$name" =~ ^buildx_buildkit_[A-Za-z0-9][A-Za-z0-9_.-]*-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}0_state$ ]] || continue
  count=$((count + 1)); [ "$count" -le 32 ] || break
  metadata="$(local_docker volume inspect --format '{{.Name}}|{{.Driver}}|{{.Scope}}|{{json .Options}}|{{json .Labels}}|{{.Mountpoint}}' "$name")" || exit 1
  case "$metadata" in
    "$name|local|local|null|null|/var/lib/docker/volumes/$name/_data"|\
    "$name|local|local|{}|null|/var/lib/docker/volumes/$name/_data"|\
    "$name|local|local|null|{}|/var/lib/docker/volumes/$name/_data"|\
    "$name|local|local|{}|{}|/var/lib/docker/volumes/$name/_data") ;;
    *) continue ;;
  esac
  references="$(local_docker ps -aq --no-trunc --filter "volume=$name")" || exit 1
  [ -z "$references" ] || continue
  # Never force removal: a concurrent container reference wins inside Docker.
  local_docker volume rm "$name" >/dev/null || exit 1
  printf '[ci-runner-farm] removed completed job cache %s\n' "$name"
done <<< "$volumes"

# Reusable builders are an explicit operator opt-in. Their cache remains warm
# normally; under shared filesystem pressure, reclaim at most one unused cache
# after this job. Never infer that arbitrary named volumes are disposable.
builders="${CRF_DOCKER_CACHE_BUILDERS:-}"
[ -n "$builders" ] || exit 0
[ "${#builders}" -le 1024 ] && [[ "$builders" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}(,[A-Za-z0-9][A-Za-z0-9_.-]{0,63})*$ ]] || exit 1
[ "$minimum" -gt 0 ] || exit 0
IFS=, read -r -a builder_names <<< "$builders"
[ "${#builder_names[@]}" -le 32 ] || exit 1

if cache_pressure; then :; else
  result=$?; [ "$result" -eq 1 ] && exit 0; exit 1
fi
daemon="$(local_docker info --format '{{.ID}}')" || exit 1
[[ "$daemon" =~ ^[A-Za-z0-9:-]{8,128}$ ]] || exit 1
for builder in "${builder_names[@]}"; do
  name="buildx_buildkit_${builder}0_state"
  printf '%s\n' "$volumes" | grep -Fxq -- "$name" || continue
  metadata="$(local_docker volume inspect --format '{{.Name}}|{{.Driver}}|{{.Scope}}|{{json .Options}}|{{json .Labels}}|{{.Mountpoint}}' "$name")" || exit 1
  case "$metadata" in
    "$name|local|local|null|null|/var/lib/docker/volumes/$name/_data"|\
    "$name|local|local|{}|null|/var/lib/docker/volumes/$name/_data"|\
    "$name|local|local|null|{}|/var/lib/docker/volumes/$name/_data"|\
    "$name|local|local|{}|{}|/var/lib/docker/volumes/$name/_data") ;;
    *) continue ;;
  esac
  references="$(local_docker ps -aq --no-trunc --filter "volume=$name")" || exit 1
  [ -z "$references" ] || continue
  [ "$(local_docker info --format '{{.ID}}')" = "$daemon" ] || exit 1
  if cache_pressure; then :; else
    result=$?; [ "$result" -eq 1 ] && exit 0; exit 1
  fi
  # Docker rejects a newly acquired reference; no forced removal or raw paths.
  local_docker volume rm "$name" >/dev/null || exit 1
  printf '[ci-runner-farm] reclaimed opted-in unused builder cache under storage pressure: %s\n' "$name"
  break
done
