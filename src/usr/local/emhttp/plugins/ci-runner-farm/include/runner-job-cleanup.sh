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
  --cleanup|--prune|--workspace|--budget) ;;
  *)
    # Hook failure must not fail a completed build. Bound both the whole pass
    # and each Docker call; unknown cleanup stays visible in the job log.
    if ! timeout -k 2 30 bash "$0" --cleanup; then
      echo '[ci-runner-farm] job cache cleanup incomplete; retained uncertain caches' >&2
    fi
    # An opt-in per-slot budget bounds the inner store between jobs. The slot
    # takes no job until this hook returns, so the pass is time-bounded.
    if [[ "${CRF_DOCKER_STORE_BUDGET_BYTES:-0}" =~ ^[1-9][0-9]{0,15}$ ]]; then
      if ! timeout -k 2 240 bash "$0" --budget; then
        echo '[ci-runner-farm] Docker store budget pass incomplete; retained remaining state' >&2
      fi
    fi
    # Pruning removes state a later job could reuse, so it is opt-in.
    if [ "${CRF_JOB_PRUNE:-}" = 1 ]; then
      if ! timeout -k 2 120 bash "$0" --prune; then
        echo '[ci-runner-farm] job Docker prune incomplete; retained unpruned state' >&2
      fi
      if ! timeout -k 2 120 bash "$0" --workspace; then
        echo '[ci-runner-farm] job workspace cleanup incomplete; retained remaining checkouts' >&2
      fi
    fi
    exit "$image_status"
    ;;
esac

minimum="${CRF_DOCKER_CACHE_MIN_FREE_PERCENT:-15}"
[[ "$minimum" =~ ^(0|[1-9][0-9]?|100)$ ]] || exit 1
cache_pressure() {
  local filesystem usage total available
  filesystem="$(timeout -k 1 3 df -Pk "${1:-/var/lib/docker}")" || return 2
  usage="$(printf '%s\n' "$filesystem" | awk 'NR==2 {print $2 "|" $4}')"
  IFS='|' read -r total available <<< "$usage"
  [[ "$total" =~ ^[1-9][0-9]{0,14}$ && "$available" =~ ^(0|[1-9][0-9]{0,14})$ ]] || return 2
  [ "$available" -le "$total" ] || return 2
  [ "$((available * 100 / total))" -lt "$minimum" ]
}

if [ "$1" = --workspace ]; then
  # Persistent runners keep a checkout of every repository they have served.
  # Under storage pressure keep only this job's repository; the next job of
  # any other repository checks it out again. Each tree is first renamed out
  # of the runner's namespace, so an interrupted removal never leaves a partial
  # checkout behind; later passes finish removing renamed trees.
  work="${RUNNER_WORKDIR:-}"
  [[ "$work" =~ ^/[A-Za-z0-9_./-]+$ && "$work" != / && "$work" != *..* ]] || exit 1
  [ -d "$work" ] && [ ! -L "$work" ] || exit 1
  current="${GITHUB_WORKSPACE:-}"
  case "$current" in "$work"/?*) current="${current#"$work"/}"; current="${current%%/*}" ;; *) current='' ;; esac
  incomplete=0
  if [ -n "$current" ]; then
    if cache_pressure "$work"; then
      for tree in "$work"/*; do
        name="${tree##*/}"
        [ -d "$tree" ] && [ ! -L "$tree" ] || continue
        # Runner-owned state (_actions, _temp, _tool, ...) is never a checkout.
        case "$name" in _*|"$current") continue ;; esac
        mv -- "$tree" "$work/_crf-trash-$$-$RANDOM-$name" || incomplete=1
      done
    else
      [ "$?" -eq 1 ] || incomplete=1
    fi
  fi
  for tree in "$work"/_crf-trash-*; do
    [ -d "$tree" ] && [ ! -L "$tree" ] || continue
    rm -rf --one-file-system -- "$tree" || incomplete=1
    [ ! -e "$tree" ] && printf '[ci-runner-farm] removed idle workspace checkout under storage pressure\n'
  done
  exit "$incomplete"
fi

# A workflow's remote Docker context must never redirect host maintenance.
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
local_docker() { timeout -k 1 5 docker --host unix:///var/run/docker.sock "$@"; }
[ "$(local_docker info --format '{{.DockerRootDir}}')" = /var/lib/docker ] || exit 1

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
if [ "$1" = --budget ]; then
  # Bound this slot's persistent store between jobs. Docker arbitrates every
  # removal: nothing is forced, so an image a container still uses stays.
  budget="${CRF_DOCKER_STORE_BUDGET_BYTES:-0}"
  [[ "$budget" =~ ^[1-9][0-9]{0,15}$ ]] || exit 1
  run_docker() { timeout -k 2 60 docker --host unix:///var/run/docker.sock "$@"; }
  # docker system df reports decimal units from daemon metadata; no file walk.
  store_bytes() {
    local rows
    rows="$(run_docker system df --format '{{.Type}}|{{.Size}}')" || return 1
    awk -F'|' '
      { if (NF != 2 || $2 !~ /^[0-9]+(\.[0-9]+)?(B|kB|MB|GB|TB|PB)$/) { bad = 1; exit }
        n = $2; unit = $2; sub(/[kMGTP]?B$/, "", n); sub(/^[0-9.]+/, "", unit)
        m = (unit == "kB") ? 1e3 : (unit == "MB") ? 1e6 : (unit == "GB") ? 1e9 : (unit == "TB") ? 1e12 : (unit == "PB") ? 1e15 : 1
        total += n * m; rows++ }
      END { if (bad || rows == 0) exit 1; printf "%.0f\n", total }' <<< "$rows"
  }
  before="$(store_bytes)" || exit 1
  # Disposable job state first: stopped job containers (warm builders kept),
  # anonymous volumes and dangling images.
  stopped="$(local_docker ps -a --no-trunc --filter status=exited --filter status=created --filter status=dead --format '{{.ID}} {{.Names}}')" || exit 1
  count=0
  while read -r id name; do
    [[ "$id" =~ ^[0-9a-f]{64}$ ]] || continue
    case "$name" in buildx_buildkit_*) continue ;; esac
    count=$((count + 1)); [ "$count" -le 64 ] || break
    local_docker rm -v "$id" >/dev/null 2>&1 || true
  done <<< "$stopped"
  api="$(local_docker version --format '{{.Server.APIVersion}}')" || exit 1
  [[ "$api" =~ ^1\.([1-9][0-9]{0,2})$ ]] || exit 1
  [ "${BASH_REMATCH[1]}" -lt 42 ] || run_docker volume prune -f >/dev/null || exit 1
  run_docker image prune -f >/dev/null || exit 1
  size="$(store_bytes)" || exit 1
  evicted=0 skipped=0 cache_pruned=false complete=true
  if [ "$size" -gt "$budget" ]; then
    # Build cache older than a week is the cheapest state to rebuild.
    run_docker builder prune -f --filter until=168h >/dev/null || exit 1
    cache_pruned=true
    size="$(store_bytes)" || exit 1
  fi
  if [ "$size" -gt "$budget" ]; then
    # Unused images, least recently pulled or tagged first.
    used="$(local_docker ps -aq --no-trunc)" || exit 1
    in_use=""
    if [ -n "$used" ]; then
      # shellcheck disable=SC2086  # IDs are validated hex, one argument each
      in_use="$(local_docker inspect --format '{{.Image}}' $used)" || exit 1
    fi
    ids="$(local_docker image ls -q --no-trunc | sort -u)" || exit 1
    candidates=""
    if [ -n "$ids" ]; then
      # shellcheck disable=SC2086
      candidates="$(run_docker image inspect --format '{{.Id}}|{{.Metadata.LastTagTime}}|{{.Created}}|{{.Size}}|{{join .RepoTags " "}}' $ids)" || exit 1
    fi
    order="$(while IFS='|' read -r id tagged created bytes tags; do
        [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] && [[ "$bytes" =~ ^[0-9]{1,16}$ ]] || continue
        grep -Fxq -- "$id" <<< "$in_use" && continue
        when="$tagged"; case "$when" in 0001-01-01*|'') when="$created" ;; esac
        printf '%s|%s|%s|%s\n' "$when" "$id" "$bytes" "$tags"
      done <<< "$candidates" | LC_ALL=C sort)"
    estimate="$size"
    while IFS='|' read -r _ id bytes tags; do
      [ -n "$id" ] || continue
      [ "$evicted" -lt 40 ] || { complete=false; break; }
      ok=true
      for tag in $tags; do
        [ "$tag" = '<none>:<none>' ] && continue
        run_docker image rm "$tag" >/dev/null 2>&1 || { ok=false; break; }
      done
      if [ "$ok" = true ] && local_docker image inspect "$id" >/dev/null 2>&1; then
        run_docker image rm "$id" >/dev/null 2>&1 || ok=false
      fi
      if [ "$ok" = true ]; then evicted=$((evicted + 1)); estimate=$((estimate - 10#$bytes)); else skipped=$((skipped + 1)); fi
      # An image's size counts layers it shares, so the estimate falls faster
      # than the store. Re-measure only once it says the budget is met.
      if [ "$estimate" -le "$budget" ]; then
        size="$(store_bytes)" || exit 1
        [ "$size" -gt "$budget" ] || break
        estimate="$size"
      fi
    done <<< "$order"
    size="$(store_bytes)" || exit 1
  fi
  if [ "$size" -gt "$budget" ]; then
    run_docker builder prune -a -f >/dev/null || exit 1
    cache_pruned=true
    size="$(store_bytes)" || exit 1
  fi
  over=false; [ "$size" -le "$budget" ] || over=true
  state=/var/log/dind/store-budget
  previous=0
  if [ -f "$state/state.json" ] && [ ! -L "$state/state.json" ] \
     && [[ "$(head -c 1024 "$state/state.json")" =~ \"evicted_images_total\":([0-9]{1,9})[,}] ]]; then
    previous="${BASH_REMATCH[1]}"
  fi
  total=$((10#$previous + evicted)); [ "$total" -le 999999999 ] || total=999999999
  if [ -d "$state" ] && [ ! -L "$state" ] && [ -w "$state" ]; then
    printf '{"schema":1,"at":%s,"budget_bytes":%s,"before_bytes":%s,"after_bytes":%s,"evicted_images":%s,"evicted_images_total":%s,"skipped_in_use":%s,"build_cache_pruned":%s,"over_budget":%s,"complete":%s}\n' \
      "$(date +%s)" "$budget" "$before" "$size" "$evicted" "$total" "$skipped" "$cache_pruned" "$over" "$complete" > "$state/.state.$$" \
      && mv -f -- "$state/.state.$$" "$state/state.json"
  fi
  [ "$evicted" -eq 0 ] || printf '[ci-runner-farm] Docker store budget: removed %s unused image(s); store %s -> %s bytes (budget %s)\n' "$evicted" "$before" "$size" "$budget"
  [ "$over" = false ]
  exit
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
  grep -Fxq -- "$name" <<< "$volumes" || continue
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
