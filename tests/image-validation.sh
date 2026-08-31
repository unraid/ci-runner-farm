#!/usr/bin/env bash
# Verify that remote job images have one safe Docker-reference argument shape.
set -euo pipefail
# The sourced engine consumes configuration through Bash dynamic scope.
# shellcheck disable=SC2034
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/cache"
# shellcheck source=/dev/null
source "$ENGINE"

IMAGE_SOURCE=remote
CACHE_ROOT="$tmp/cache"
CACHE_MOUNTS=''
DIND=false
SHARE_DOCKER_SOCK=false
WORK_TMPFS_SIZE=''
GH_SCOPE=repo
GH_REPOS='example/project'
ACCESS_TOKEN=''

valid='ghcr.io/example/runner:latest'
IMAGE="$valid"
[ "$(effective_image)" = "$valid" ] \
  || { echo 'image-validation: valid remote image was rejected' >&2; exit 1; }
github_build_args 1 ci-runner-1 \
  || { echo 'image-validation: valid image failed GitHub argument construction' >&2; exit 1; }
[ "${ARGS[${#ARGS[@]}-1]}" = "$valid" ] \
  || { echo 'image-validation: validated image did not reach the final Docker argument' >&2; exit 1; }

for invalid in '-q' 'bad image' 'image;touch' '$(touch '"$tmp"'/executed)' '"quoted"'; do
  IMAGE="$invalid"
  if effective_image >/dev/null 2>"$tmp/error"; then
    echo "image-validation: accepted invalid image shape: $invalid" >&2
    exit 1
  fi
  if github_build_args 1 ci-runner-1 >/dev/null 2>&1; then
    echo "image-validation: GitHub arguments accepted invalid image shape: $invalid" >&2
    exit 1
  fi
done
[ ! -e "$tmp/executed" ] || { echo 'image-validation: invalid image was executed' >&2; exit 1; }

IMAGE_SOURCE=builtin
IMAGE='not-used'
[ "$(effective_image)" = "$(builtin_image)" ] \
  || { echo 'image-validation: built-in image path changed' >&2; exit 1; }

echo "image-validation: PASS"
