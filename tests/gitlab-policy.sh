#!/usr/bin/env bash
# GitLab Docker-executor policy controls: upgrade-safe defaults, generated TOML,
# validation, and config fingerprints that force a safe manager recreation.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config"
export CRF_RUNDIR="$tmp/run"
export CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'GITLAB POLICY FAIL: %s\n' "$*" >&2; exit 1; }

CI_PROVIDER=gitlab
GITLAB_URL='https://gitlab.example.test'
GITLAB_RUNNER_TOKEN='glrt-policytest000000000000000'
GITLAB_RUNNER_IMAGE='gitlab/gitlab-runner:alpine'
CACHE_ROOT="$tmp/cache"
CACHE_MOUNTS=''
IMAGE_SOURCE=builtin
DIND=true
SHARE_DOCKER_SOCK=false
NETWORK_ISOLATION=off
mkdir -p "$CACHE_ROOT"

# Empty allowlists intentionally preserve GitLab Runner's permissive upgrade
# behavior. Pull-policy "auto" preserves the existing built-in/remote choice,
# while allowed_pull_policies prevents a job from selecting a weaker policy.
gitlab_validate_settings || fail "default execution policy was rejected"
REGISTRY_SERVER='http://registry.example.test:5000'
if gitlab_validate_settings >/dev/null 2>&1; then
  fail "GitLab accepted an insecure HTTP registry endpoint"
fi
REGISTRY_SERVER='https://registry.example.test:5443'
gitlab_validate_settings || fail "GitLab rejected a normalized HTTPS registry endpoint"
REGISTRY_SERVER=''
gitlab_write_config 1 ci-runner-1 || fail "default policy TOML generation failed"
cfg="$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml"
if grep -qE 'allowed_(images|services)[[:space:]]*=' "$cfg"; then
  fail "blank allowlists were emitted instead of preserving Runner defaults"
fi
grep -qF '    pull_policy = "if-not-present"' "$cfg" \
  || fail "auto policy did not preserve the built-in image pull behavior"
grep -qF '    allowed_pull_policies = ["if-not-present"]' "$cfg" \
  || fail "job-level pull-policy overrides are not restricted"
grep -qF '    shm_size = 0' "$cfg" || fail "default shared-memory size changed"

# Space-separated wildcard patterns become quoted TOML arrays without pathname
# expansion. A configured policy must survive exactly as the operator entered it.
GITLAB_ALLOWED_IMAGES='registry.example.test/team/*:* node:24'
GITLAB_ALLOWED_SERVICES='postgres:* redis:*'
GITLAB_PULL_POLICY='if-not-present'
GITLAB_SHM_SIZE='1073741824'
gitlab_validate_settings || fail "valid custom execution policy was rejected"
gitlab_write_config 1 ci-runner-1 || fail "custom policy TOML generation failed"
grep -qF '    allowed_images = ["registry.example.test/team/*:*", "node:24"]' "$cfg" \
  || fail "allowed image patterns were not emitted exactly"
grep -qF '    allowed_services = ["postgres:*", "redis:*"]' "$cfg" \
  || fail "allowed service patterns were not emitted exactly"
grep -qF '    pull_policy = "if-not-present"' "$cfg" || fail "custom pull policy missing"
grep -qF '    allowed_pull_policies = ["if-not-present"]' "$cfg" \
  || fail "custom pull policy is not enforced against job overrides"
grep -qF '    shm_size = 1073741824' "$cfg" || fail "custom shared-memory size missing"
python3 - "$cfg" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    docker = tomllib.load(fh)["runners"][0]["docker"]
assert docker["allowed_images"] == ["registry.example.test/team/*:*", "node:24"]
assert docker["allowed_services"] == ["postgres:*", "redis:*"]
assert docker["pull_policy"] == "if-not-present"
assert docker["allowed_pull_policies"] == ["if-not-present"]
assert docker["shm_size"] == 1073741824
PY

for invalid_policy in never sometimes; do
  GITLAB_PULL_POLICY="$invalid_policy"
  if gitlab_validate_settings >/dev/null 2>&1; then fail "invalid pull policy accepted: $invalid_policy"; fi
done
IMAGE_SOURCE=builtin; GITLAB_PULL_POLICY=always
if gitlab_validate_settings >/dev/null 2>&1; then fail "always pull policy accepted for a local-only built-in image"; fi
IMAGE_SOURCE=remote; GITLAB_PULL_POLICY=always
gitlab_validate_settings >/dev/null 2>&1 || fail "always pull policy rejected for a remote default image"
IMAGE_SOURCE=builtin
GITLAB_PULL_POLICY='auto'
GITLAB_SHUTDOWN_TIMEOUT=07200
if gitlab_validate_settings >/dev/null 2>&1; then fail "leading-zero shutdown timeout accepted into invalid TOML"; fi
GITLAB_SHUTDOWN_TIMEOUT=7200
original_mounts="$CACHE_MOUNTS"
for invalid_mounts in \
  'cache:relative/path' \
  'cache:/cache' \
  'cache:/var/run/docker.sock' \
  'cache:/etc/gitlab-runner/certs/ca.crt' \
  'cache:/foo/../cache' \
  'cache:/var/run/../run/docker.sock' \
  'cache:/opt//shared' \
  'cache:/opt/shared/' \
  'one:/opt/shared two:/opt/shared' \
  '../escape:/opt/cache' \
  'cache:/opt/cache:ro'
do
  CACHE_MOUNTS="$invalid_mounts"
  if gitlab_validate_settings >/dev/null 2>&1; then
    fail "invalid GitLab cache destination/source accepted: $invalid_mounts"
  fi
done
CACHE_MOUNTS='one:/opt/cache-one two:/opt/cache-two'
gitlab_validate_settings >/dev/null 2>&1 || fail "valid distinct GitLab cache mounts were rejected"
CACHE_MOUNTS="$original_mounts"
for invalid_shm in -1 01 1g 92233720368547758070; do
  GITLAB_SHM_SIZE="$invalid_shm"
  if gitlab_validate_settings >/dev/null 2>&1; then
    fail "invalid shared-memory size accepted: $invalid_shm"
  fi
done
GITLAB_SHM_SIZE=0
for invalid_images in 'node:24,alpine:3' $'node:24\nredis:7' 'node:24\evil'; do
  GITLAB_ALLOWED_IMAGES="$invalid_images"
  if gitlab_validate_settings >/dev/null 2>&1; then
    fail "unsafe allowed-image pattern accepted"
  fi
done

# Every baked policy value participates in confgen, so Apply drains and recreates
# stale managers instead of silently leaving old executor policy in service.
GITLAB_ALLOWED_IMAGES=''
GITLAB_ALLOWED_SERVICES=''
GITLAB_PULL_POLICY='auto'
GITLAB_SHM_SIZE=0
baseline="$(crf_confgen)"
for assignment in \
  'GITLAB_ALLOWED_IMAGES=node:*' \
  'GITLAB_ALLOWED_SERVICES=postgres:*' \
  'GITLAB_PULL_POLICY=always' \
  'GITLAB_SHM_SIZE=67108864'
do
  GITLAB_ALLOWED_IMAGES=''
  GITLAB_ALLOWED_SERVICES=''
  GITLAB_PULL_POLICY='auto'
  GITLAB_SHM_SIZE=0
  key="${assignment%%=*}"; value="${assignment#*=}"
  printf -v "$key" '%s' "$value"
  [ "$(crf_confgen)" != "$baseline" ] || fail "confgen ignores $key"
done

echo "gitlab-policy: OK — executor allowlists, pull policy, shm size, validation, and confgen are wired"
