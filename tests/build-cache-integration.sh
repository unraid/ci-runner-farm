#!/usr/bin/env bash
# Real registry reuse across two isolated builders. Never prunes a Docker daemon.
# External mode uses caller-owned Docker auth and uploads only this dummy context.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" = Darwin ]; then
  command -v brew >/dev/null 2>&1 || {
    echo 'macOS cache integration requires Homebrew Coreutils (brew install coreutils).' >&2
    exit 1
  }
  coreutils_bin="$(brew --prefix coreutils)/libexec/gnubin"
  [ -x "$coreutils_bin/mv" ] || {
    echo 'Install GNU tools for macOS cache integration: brew install coreutils' >&2
    exit 1
  }
  export PATH="$coreutils_bin:$PATH"
fi
external_registry=false
if [ -n "${CRF_CACHE_TEST_REPOSITORY+x}${CRF_CACHE_TEST_TAG+x}" ]; then
  : "${CRF_CACHE_TEST_REPOSITORY:?External cache test requires a repository}"
  : "${CRF_CACHE_TEST_TAG:?External cache test requires a unique proof tag}"
  [[ "$CRF_CACHE_TEST_TAG" =~ ^proof-[a-z0-9][a-z0-9_.-]{0,100}$ ]] || {
    echo 'External cache test tag must start with proof- and contain a safe, unique suffix.' >&2
    exit 1
  }
  external_registry=true
fi
# DinD mounts its own tmpfs over /tmp, hiding nested bind sources there. Keep
# the fixture outside that overlay and preserve identical host/sidecar paths.
tmp="$(mktemp -d /var/tmp/crf-build-cache.XXXXXX)"
suffix="$(basename "$tmp" | tr '[:upper:].' '[:lower:]-')"
network="crf-cache-$suffix"
registry="crf-registry-$suffix"
builders=()
registry_id=''
network_id=''
sidecar_id=''
cleanup() {
  [ -z "$sidecar_id" ] || docker rm -fv "$sidecar_id" >/dev/null 2>&1 || true
  for builder in "${builders[@]}"; do docker buildx rm "$builder" >/dev/null 2>&1 || true; done
  [ -z "$registry_id" ] || docker rm -fv "$registry_id" >/dev/null 2>&1 || true
  [ -z "$network_id" ] || docker network rm "$network_id" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
BUILD_CACHE_MODE=registry
BUILD_CACHE_REPOSITORY="${CRF_CACHE_TEST_REPOSITORY:-cache.test:5000/team/cache}"
BUILD_CACHE_LOCAL_GIB=20
profile="$(build_cache_profile)"
cache_ref="$BUILD_CACHE_REPOSITORY:${CRF_CACHE_TEST_TAG:-project-target-platform-main}"
cp "$profile/buildkitd.toml" "$tmp/buildkitd.toml"
registry_image='registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373'
buildkit_image='moby/buildkit@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8'
network_id="$(docker network create "$network")"
if [ "$external_registry" = false ]; then
  # Plain HTTP belongs only to the disposable registry, never an external one.
  printf '\n[registry."cache.test:5000"]\n  http = true\n' >> "$tmp/buildkitd.toml"
  registry_id="$(docker run -d --name "$registry" --network "$network" --network-alias cache.test "$registry_image")"
fi
mkdir "$tmp/context"
printf 'FROM busybox:1.37.0\nRUN echo registry-cache-proof > /proof\n' > "$tmp/context/Dockerfile"
for n in 1 2; do
  builder="crf-builder-$suffix-$n"
  docker buildx create --name "$builder" --driver docker-container \
    --driver-opt "network=$network" --driver-opt "image=$buildkit_image" \
    --buildkitd-config "$tmp/buildkitd.toml" >/dev/null
  builders+=("$builder")
  docker buildx inspect "$builder" --bootstrap > "$tmp/builder-$n.log" 2>&1
  container="buildx_buildkit_${builder}0"
  docker exec "$container" buildctl debug workers --verbose > "$tmp/policy-$n.txt"
  # Both effective final policies must obey the configured budget. A generated
  # TOML assertion alone would miss BuildKit's implicit disk-percentage defaults.
  docker exec "$container" buildctl debug workers --format '{{json .}}' > "$tmp/policy-$n.json"
  jq -e 'length > 0 and all(.[]; (.gcPolicy | length > 0) and
    all(.gcPolicy[]; (.maxUsedSpace | type == "number") and .maxUsedSpace > 0 and
      .maxUsedSpace <= 21474836480 and (.reservedSpace | type == "number") and
      .reservedSpace <= 21474836480))' "$tmp/policy-$n.json" >/dev/null || {
        jq '[.[] | {gcPolicy}]' "$tmp/policy-$n.json" >&2
        exit 1
      }
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/buildkit"}}{{.Name}}{{end}}{{end}}' \
    "$container" > "$tmp/volume-$n"
  args=(--builder "$builder" --progress=plain
    --cache-to "type=registry,ref=$cache_ref,mode=max,image-manifest=true")
  if [ "$n" = 2 ]; then
    args+=(--cache-from "type=registry,ref=$cache_ref")
  fi
  if ! docker buildx build "${args[@]}" "$tmp/context" > "$tmp/build-$n.log" 2>&1; then
    tail -35 "$tmp/build-$n.log" >&2
    exit 1
  fi
done
[ -s "$tmp/volume-1" ]
[ -s "$tmp/volume-2" ]
if cmp -s "$tmp/volume-1" "$tmp/volume-2"; then
  echo 'BuildKit builders must use distinct local volumes.' >&2
  exit 1
fi
# The RUN operation, not just base-image metadata, must come from registry cache.
awk '/RUN echo registry-cache-proof/ {step=$1} $1 == step && $2 == "CACHED" {found=1} END {exit !found}' "$tmp/build-2.log"
grep -Fq "importing cache manifest from $cache_ref" "$tmp/build-2.log"
docker run --rm --mount "type=bind,src=$profile,dst=/etc/ci-runner-farm/build-cache,readonly" \
  busybox:1.37.0 sh -c '. /etc/ci-runner-farm/build-cache/profile.env &&
    test "$CRF_BUILD_CACHE_MODE" = registry &&
    ! touch /etc/ci-runner-farm/build-cache/forbidden' >/dev/null 2>&1
# GitLab's private daemon must resolve the same source path for its nested job.
sidecar_id="$(docker run -d --privileged --network "$network" \
  --mount "type=bind,src=$profile,dst=$profile,readonly" \
  docker@sha256:aa3df78ecf320f5fafdce71c659f1629e96e9de0968305fe1de670e0ca9176ce \
  dockerd --host=unix:///var/run/docker.sock)"
for attempt in $(seq 1 30); do
  docker exec "$sidecar_id" docker info >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$sidecar_id" docker info >/dev/null 2>&1
docker exec "$sidecar_id" test -s "$profile/profile.env"
docker exec "$sidecar_id" test -s "$profile/buildkitd.toml"
if docker exec "$sidecar_id" docker run --rm \
  --mount "type=bind,src=$profile,dst=/etc/ci-runner-farm/build-cache,readonly" \
  busybox:1.37.0 sh -c '. /etc/ci-runner-farm/build-cache/profile.env &&
    test "$CRF_BUILD_CACHE_MODE" = registry &&
    ! touch /etc/ci-runner-farm/build-cache/forbidden' > "$tmp/nested.log" 2>&1; then
  :
else
  result=$?
  echo 'Nested read-only profile test failed:' >&2
  tail -20 "$tmp/nested.log" >&2
  exit "$result"
fi
echo 'build-cache-integration: independent cache reuse, effective GC budgets, and direct/nested read-only profiles: OK'
if [ "$external_registry" = true ]; then
  printf 'External registry proof retained at %s (synthetic data only).\n' "$cache_ref"
fi
