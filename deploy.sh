#!/bin/bash
# Deploy the complete plugin runtime to a disposable Unraid host with a staged,
# rollback-protected tree replacement.
#
# This is a development shortcut, not an installer. The source tree is uploaded
# to a staging directory, validated, assigned the same ownership/modes as the
# packaged plugin, and only then swapped into place. A failed upload therefore
# leaves the currently installed runtime untouched.
set -euo pipefail

HOST="${1:-}"
if [ -z "$HOST" ] || [ "$HOST" = "-h" ] || [ "$HOST" = "--help" ]; then
  echo "usage: ./deploy.sh root@unraid-host" >&2
  exit 2
fi
case "$HOST" in
  -*) echo "deploy: host must not begin with '-': $HOST" >&2; exit 2 ;;
esac

NAME="ci-runner-farm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/src/usr/local/emhttp/plugins/$NAME"
DEST="/usr/local/emhttp/plugins/$NAME"

# These sentinels catch a wrong checkout/path before anything is sent. The tar
# stream below contains everything else too, including all .page, event, nchan,
# Dockerfile, and include files; new runtime files need no deploy-script update.
for required in \
  RunnerFarm.page RunnerFarmDashboard.page RunnerFarmFleet.page RunnerFarmImage.page RunnerFarmSettings.page \
  default.cfg default.Dockerfile default.github.Dockerfile default.gitlab.Dockerfile \
  include/runner-farm.sh include/exec.php include/crf-core.php include/providers/github.sh include/providers/gitlab.sh \
  event/docker_started event/stopping_docker \
  nchan/ci_runner_farm README.md
do
  if [ ! -f "$SRC/$required" ]; then
    echo "deploy: required runtime file is missing: $SRC/$required" >&2
    exit 1
  fi
done

echo "[deploy] staging complete runtime tree for $HOST:$DEST"
REMOTE_STAGE="$(ssh -- "$HOST" "umask 022; mktemp -d '${DEST}.deploy.XXXXXX'")"
case "$REMOTE_STAGE" in
  "$DEST".deploy.*) ;;
  *) echo "deploy: remote host returned an unsafe staging path: $REMOTE_STAGE" >&2; exit 1 ;;
esac

cleanup_stage() {
  ssh -- "$HOST" "rm -rf -- '$REMOTE_STAGE'" >/dev/null 2>&1 || true
}
trap cleanup_stage EXIT HUP INT TERM

# A tar stream is available on stock Unraid and preserves the full directory
# layout without relying on shell globs (which previously omitted pages/events).
# macOS otherwise synthesizes AppleDouble `._*` members for local extended
# attributes; those are not runtime files and must never reach the Unraid tree.
COPYFILE_DISABLE=1 tar --no-xattrs -C "$SRC" -cf - . | ssh -- "$HOST" "tar -xf - -C '$REMOTE_STAGE'"

# Validate and permission the staging tree, then swap it in. The previous tree
# is retained until the new one is installed so an interrupted deploy rolls back.
ssh -- "$HOST" /bin/bash -s -- "$DEST" "$REMOTE_STAGE" <<'REMOTE'
set -euo pipefail
dest="$1"
stage="$2"

if [ "$dest" != "/usr/local/emhttp/plugins/ci-runner-farm" ]; then
  echo "deploy: refusing unexpected destination: $dest" >&2
  exit 1
fi
case "$stage" in
  "$dest".deploy.*) ;;
  *) echo "deploy: refusing unexpected staging path: $stage" >&2; exit 1 ;;
esac

for required in \
  RunnerFarm.page RunnerFarmDashboard.page RunnerFarmFleet.page RunnerFarmImage.page RunnerFarmSettings.page \
  default.cfg default.Dockerfile default.github.Dockerfile default.gitlab.Dockerfile \
  include/runner-farm.sh include/exec.php include/crf-core.php include/providers/github.sh include/providers/gitlab.sh \
  event/docker_started event/stopping_docker \
  nchan/ci_runner_farm README.md
do
  [ -f "$stage/$required" ] || {
    echo "deploy: staged runtime is incomplete: $required" >&2
    exit 1
  }
done

appledouble_files="$(find "$stage" -name '._*' -print)" || {
  echo "deploy: cannot inspect the staged runtime for macOS metadata" >&2
  exit 1
}
if [ -n "$appledouble_files" ]; then
  echo "deploy: staged runtime contains unexpected macOS AppleDouble metadata" >&2
  printf '%s\n' "$appledouble_files" >&2
  exit 1
fi

chown -R root:root "$stage"
find "$stage" -type d -exec chmod 0755 {} +
find "$stage" -type f -exec chmod 0644 {} +
chmod 0755 "$stage/include/runner-farm.sh"
find "$stage/nchan" -type f -exec chmod 0755 {} + 2>/dev/null || true
find "$stage/event" -type f -exec chmod 0755 {} + 2>/dev/null || true

# Use the exact runtime lock location/fallback used by the installed engine. Hold
# it from the final inactive-state snapshot through the tree swap, preventing a
# concurrent Start/Scale/Recycle or daemon tick from passing the check on the old
# code and mutating the fleet while the replacement is installed.
cfgdir="/boot/config/plugins/ci-runner-farm"
rundir="/var/local/emhttp/ci-runner-farm"
if ! mkdir -p "$rundir" 2>/dev/null; then
  rundir="$cfgdir"
  mkdir -p "$rundir" || {
    echo "deploy: cannot create the installed runtime lock directory" >&2
    exit 1
  }
fi
command -v flock >/dev/null 2>&1 || {
  echo "deploy: flock is unavailable; refusing an unlocked runtime replacement" >&2
  exit 1
}
exec 8>"$rundir/fleet.lock" || {
  echo "deploy: cannot open the installed CI Runner Farm fleet lock" >&2
  exit 1
}
flock -w 20 8 || {
  echo "deploy: CI Runner Farm is busy; Stop it and retry deployment" >&2
  exit 1
}

# A daemon keeps the old script inode open after an atomic swap, while new web
# requests execute the replacement. Refuse that mixed-version state instead of
# implicitly stopping jobs on a development host. Query every Docker ownership
# contract emitted by the runtime, not only running managers: stopped managers,
# GitHub validations, persistent DinD sidecars, GitLab host-socket workloads,
# GitLab validation jobs, and the shared registry mirror all retain state made by
# the old code. The resource and validation queries use their complete
# class-specific label intersections, so an unrelated Docker object cannot block
# deployment merely because it carries one generic-looking label. Any inability
# to query Docker/pgrep fails closed.
command -v docker >/dev/null 2>&1 || {
  echo "deploy: Docker CLI is unavailable; cannot prove the fleet is inactive" >&2
  exit 1
}
owned_managers="$(docker ps -a \
  --filter 'label=net.unraid.ci-runner-farm.managed=true' \
  --format '{{.Names}}' 2>/dev/null)" || {
  echo "deploy: cannot enumerate CI Runner Farm managers; refusing deployment" >&2
  exit 1
}
owned_sidecars="$(docker ps -a \
  --filter 'label=net.unraid.ci-runner-farm.sidecar=true' \
  --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
  --filter 'label=net.unraid.ci-runner-farm.role=dind' \
  --format '{{.Names}}' 2>/dev/null)" || {
  echo "deploy: cannot enumerate GitLab DinD sidecars; refusing deployment" >&2
  exit 1
}
owned_host_jobs="$(docker ps -a \
  --filter 'label=com.gitlab.gitlab-runner.managed=true' \
  --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
  --filter 'label=net.unraid.ci-runner-farm.slot' \
  --format '{{.Names}}' 2>/dev/null)" || {
  echo "deploy: cannot enumerate GitLab host-socket jobs/helpers/services; refusing deployment" >&2
  exit 1
}
owned_mirrors="$(docker ps -a \
  --filter 'label=net.unraid.ci-runner-farm.resource=true' \
  --filter 'label=net.unraid.ci-runner-farm.role=mirror' \
  --format '{{.Names}}' 2>/dev/null)" || {
  echo "deploy: cannot enumerate shared registry mirrors; refusing deployment" >&2
  exit 1
}
# Releases before mirror ownership labels used the same fixed name. Recognize
# that one upgrade object only by the engine's complete legacy provenance tuple;
# an unrelated container named ci-runner-mirror must not block deployment.
all_container_names="$(docker ps -a --format '{{.Names}}' 2>/dev/null)" || {
  echo "deploy: cannot enumerate Docker names for legacy mirror verification; refusing deployment" >&2
  exit 1
}
owned_legacy_mirrors=""
if [ -z "$owned_mirrors" ] \
   && printf '%s\n' "$all_container_names" | grep -qxF 'ci-runner-mirror'; then
  legacy_cache_root="/mnt/cache/github-runner"
  cfg="$cfgdir/ci-runner-farm.cfg"
  if [ -e "$cfg" ]; then
    [ -r "$cfg" ] || {
      echo "deploy: cannot read plugin config for legacy mirror verification; refusing deployment" >&2
      exit 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      [ "${line#*=}" = "$line" ] && continue
      key="${line%%=*}"; value="${line#*=}"
      key="${key//[[:space:]]/}"
      [ "$key" = CACHE_ROOT ] || continue
      value="${value%\"}"; value="${value#\"}"
      value="${value%\'}"; value="${value#\'}"
      legacy_cache_root="$value"
    done < "$cfg"
  fi
  legacy_name="$(docker inspect -f '{{.Name}}' ci-runner-mirror 2>/dev/null)" \
    && legacy_image="$(docker inspect -f '{{.Config.Image}}' ci-runner-mirror 2>/dev/null)" \
    && legacy_source="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Source}}{{end}}{{end}}' ci-runner-mirror 2>/dev/null)" \
    && legacy_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ci-runner-mirror 2>/dev/null)" \
    || {
      echo "deploy: cannot verify fixed-name registry mirror provenance; refusing deployment" >&2
      exit 1
    }
  if [ "$legacy_name" = /ci-runner-mirror ] \
     && [ "$legacy_image" = registry:2 ] \
     && [ "$legacy_source" = "$legacy_cache_root/registry-mirror" ] \
     && printf '%s\n' "$legacy_env" | grep -qx 'REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io'; then
    owned_legacy_mirrors=ci-runner-mirror
  fi
fi
owned_github_validations="$(docker ps -a \
  --filter 'label=net.unraid.ci-runner-farm.managed=true' \
  --filter 'label=net.unraid.ci-runner-farm.provider=github' \
  --filter 'label=net.unraid.ci-runner-farm.role=validate' \
  --format '{{.Names}}' 2>/dev/null)" || {
  echo "deploy: cannot enumerate GitHub validation containers; refusing deployment" >&2
  exit 1
}
owned_gitlab_validations="$(docker ps -a \
  --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
  --filter 'label=net.unraid.ci-runner-farm.role=validate-job' \
  --filter 'label=net.unraid.ci-runner-farm.slot' \
  --format '{{.Names}}' 2>/dev/null)" || {
  echo "deploy: cannot enumerate GitLab validation jobs; refusing deployment" >&2
  exit 1
}
if [ -n "$owned_managers" ] || [ -n "$owned_sidecars" ] || [ -n "$owned_host_jobs" ] \
   || [ -n "$owned_mirrors" ] || [ -n "$owned_legacy_mirrors" ] \
   || [ -n "$owned_github_validations" ] \
   || [ -n "$owned_gitlab_validations" ]; then
  echo "deploy: CI Runner Farm still owns Docker objects; Stop/clean the fleet before deploying" >&2
  [ -z "$owned_managers" ] || printf '  managers:\n%s\n' "$owned_managers" >&2
  [ -z "$owned_sidecars" ] || printf '  GitLab sidecars:\n%s\n' "$owned_sidecars" >&2
  [ -z "$owned_host_jobs" ] || printf '  GitLab jobs/helpers/services:\n%s\n' "$owned_host_jobs" >&2
  [ -z "$owned_mirrors" ] || printf '  registry mirrors:\n%s\n' "$owned_mirrors" >&2
  [ -z "$owned_legacy_mirrors" ] || printf '  legacy registry mirrors:\n%s\n' "$owned_legacy_mirrors" >&2
  [ -z "$owned_github_validations" ] || printf '  GitHub validations:\n%s\n' "$owned_github_validations" >&2
  [ -z "$owned_gitlab_validations" ] || printf '  GitLab validation jobs:\n%s\n' "$owned_gitlab_validations" >&2
  exit 1
fi

daemon_check=0
pgrep -f '[r]unner-farm.sh (autoscale-daemon|imageupdate-daemon|reconcile-drain|boot-autostart)' >/dev/null 2>&1 \
  || daemon_check=$?
case "$daemon_check" in
  0)
    echo "deploy: a CI Runner Farm background daemon is active; Stop the fleet before deploying" >&2
    exit 1 ;;
  1) ;;
  *)
    echo "deploy: cannot verify CI Runner Farm background-daemon state; refusing deployment" >&2
    exit 1 ;;
esac

backup="${dest}.deploy-backup.$$"
rollback() {
  status=$?
  if [ ! -e "$dest" ] && [ -e "$backup" ]; then mv "$backup" "$dest"; fi
  exit "$status"
}
trap rollback ERR HUP INT TERM

if [ -e "$dest" ]; then mv "$dest" "$backup"; fi
mv "$stage" "$dest"
rm -rf -- "$backup"
trap - ERR HUP INT TERM

echo "[deploy] installed complete runtime tree:"
find "$dest" -maxdepth 2 -type f -print | sort
REMOTE

trap - EXIT HUP INT TERM
echo "[deploy] done"
