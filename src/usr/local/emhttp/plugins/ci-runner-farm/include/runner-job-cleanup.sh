#!/usr/bin/env bash
# GitHub invokes this synchronously after the assigned job's steps finish.
# Keep stable warm caches. Only run/attempt-scoped, unreferenced Buildx state
# belongs to this completed job; Docker arbitrates the final non-forced removal.
set -uo pipefail

# Preserve the image's original hook, including its job-failing exit status.
# GitHub invokes shell hooks with bash -e and PowerShell hooks with pwsh.
image_status=0
if [ "${1:-}" != --cleanup ] && [ -n "${CRF_IMAGE_JOB_COMPLETED_HOOK:-}" ]; then
  case "$CRF_IMAGE_JOB_COMPLETED_HOOK" in
    "$0"|/opt/ci-runner-farm/job-completed.sh) exit 1 ;;
    /*.sh) bash -e "$CRF_IMAGE_JOB_COMPLETED_HOOK" || image_status=$? ;;
    /*.ps1) pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Unrestricted -File "$CRF_IMAGE_JOB_COMPLETED_HOOK" || image_status=$? ;;
    *) exit 1 ;;
  esac
fi

[ "${CRF_JOB_CLEANUP_DIND:-}" = 1 ] && [ "${GITHUB_ACTIONS:-}" = true ] || exit "$image_status"
[[ "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]] && [[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] || exit "$image_status"

if [ "${1:-}" != --cleanup ]; then
  # Hook failure must not fail a completed build. Bound both the whole pass
  # and each Docker call; unknown cleanup stays visible in the job log.
  if ! timeout -k 2 30 bash "$0" --cleanup; then
    echo '[ci-runner-farm] job cache cleanup incomplete; retained uncertain caches' >&2
  fi
  exit "$image_status"
fi

# A workflow's remote Docker context must never redirect host maintenance.
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
local_docker() { timeout -k 1 5 docker --host unix:///var/run/docker.sock "$@"; }
[ "$(local_docker info --format '{{.DockerRootDir}}')" = /var/lib/docker ] || exit 1
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
