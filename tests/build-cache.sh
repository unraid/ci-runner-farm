#!/usr/bin/env bash
# Exercise the real profile generator and provider mounts without a live farm.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { echo "BUILD CACHE FAIL: $*" >&2; exit 1; }
host() { echo testhost; }
runner_host_service_ipv4() { echo 192.0.2.10; }
CACHE_ROOT="$tmp/cache"; CACHE_MOUNTS=''; NO_REGISTER=1
mkdir -p "$CACHE_ROOT"

[ "${BUILD_CACHE_MODE:-missing}" = off ] || fail 'profile must default to off'
legacy="$(github_confgen)"
[ "$(crf_confgen)" = "$legacy" ] || fail 'off mode changes the legacy fingerprint'
[ -z "$(build_cache_profile)" ] || fail 'off mode exposes a profile'
[ ! -e "$RUNDIR/build-cache-profiles" ] || fail 'off mode creates files'
github_build_args 1
if printf '%s\n' "${ARGS[@]}" | grep -q 'build-cache'; then fail 'off mode mounts a profile'; fi

BUILD_CACHE_MODE=registry
BUILD_CACHE_REPOSITORY='registry.example.test:5443/team/build-cache'
BUILD_CACHE_LOCAL_GIB=20
profile="$(build_cache_profile)"
[ -f "$profile/profile.env" ] && [ -f "$profile/buildkitd.toml" ] || fail 'profile missing'
first_gen="$(crf_confgen)"
[ "$first_gen" != "$legacy" ] || fail 'enabled mode omitted from fingerprint'
grep -qx 'CRF_BUILD_CACHE_REPOSITORY=registry.example.test:5443/team/build-cache' "$profile/profile.env"
grep -qx '  maxUsedSpace = "20GiB"' "$profile/buildkitd.toml"
grep -qx '  reservedSpace = "0B"' "$profile/buildkitd.toml"
first_bytes="$(sha256sum "$profile/profile.env" "$profile/buildkitd.toml")"
[ "$(build_cache_profile)" = "$profile" ] || fail 'same configuration is not idempotent'
(
  # This is the documented workflow boundary. No host credential is exported.
  source "$profile/profile.env"
  [ "$CRF_BUILD_CACHE_MODE" = registry ]
  [ "$CRF_BUILDKIT_CONFIG" = /etc/ci-runner-farm/build-cache/buildkitd.toml ]
)
github_build_args 1
printf '%s\n' "${ARGS[@]}" | grep -qxF "$profile:/etc/ci-runner-farm/build-cache:ro"
printf '%s\n' "${ARGS[@]}" | grep -qxF "$CACHE_ROOT/docker/ci-runner-1:/var/lib/docker"

# Changing a setting must not rewrite the files used by a busy runner.
BUILD_CACHE_LOCAL_GIB=10
second="$(build_cache_profile)"
[ "$second" != "$profile" ] && [ "$(crf_confgen)" != "$first_gen" ] || fail 'budget change is stale'
[ "$(sha256sum "$profile/profile.env" "$profile/buildkitd.toml")" = "$first_bytes" ] || fail 'old profile was overwritten'
BUILD_CACHE_REPOSITORY='registry.example.test/team/other-cache'
[ "$(build_cache_profile)" != "$second" ] || fail 'repository omitted from hash'

# Reject literal shell/config injection and invalid budgets before any arithmetic.
for invalid in '' 'https://registry.example.test/cache' 'registry.example.test/cache:latest' \
  'registry.example.test/cache@sha256:abc' 'registry.example.test/cache,mode=max' \
  'registry.example.test/../cache' 'registry.example.test/cache;touch /tmp/never' \
  'registry.example.test/$(id)' $'registry.example.test/cache\nEVIL=true'; do
  BUILD_CACHE_REPOSITORY="$invalid"
  if build_cache_profile >/dev/null 2>&1; then fail 'unsafe repository accepted'; fi
done
BUILD_CACHE_REPOSITORY='registry.example.test/team/cache'
for invalid in 0 -1 01 1025 999999999999999999999 '1.5' 'a[$(id)]' $'20\n'; do
  BUILD_CACHE_LOCAL_GIB="$invalid"
  if build_cache_profile >/dev/null 2>&1; then fail 'invalid budget accepted'; fi
done
BUILD_CACHE_LOCAL_GIB=20; DIND=false
if build_cache_profile >/dev/null 2>&1; then fail 'host-socket profile accepted'; fi
DIND=true; BUILD_CACHE_MODE=unknown
if provider_validate_settings >/dev/null 2>&1; then fail 'invalid mode passed settings validation'; fi
BUILD_CACHE_MODE=registry

# Both GitLab bind boundaries must refer to the same immutable source directory.
CI_PROVIDER=gitlab; GITLAB_RUNNER_TOKEN='glrt-test-only-token'
profile="$(build_cache_profile)"
gitlab_write_config 1 ci-runner-1
grep -qF "$profile:/etc/ci-runner-farm/build-cache:ro" "$CFGDIR/gitlab-runners/ci-runner-1/config.toml"
docker() {
  case "$1" in
    inspect) return 1 ;;
    run) printf '%s\n' "$@" > "$tmp/sidecar.args" ;;
    --host) return 0 ;;
    *) return 0 ;;
  esac
}
gitlab_start_sidecar 1 ci-runner-1
grep -qxF "$profile:$profile:ro" "$tmp/sidecar.args"
if grep -qF "$GITLAB_RUNNER_TOKEN" "$profile/"*; then fail 'credential in profile'; fi

# Reboot loses RUNDIR. The existing sidecar must not start with an empty bind.
(
  fixture_manager_id="$(printf '%064d' 1)"; fixture_side_id="$(printf '%064d' 2)"
  rm "$profile/profile.env" "$profile/buildkitd.toml"
  rmdir "$profile"
  gitlab_validate_manager_version() { return 0; }
  gitlab_sidecar_owned() { return 0; }
  gitlab_running_executor_containers() { return 0; }
  gitlab_start_sidecar() { return 0; }
  gitlab_ensure_job_image() { return 0; }
  docker() {
    case "$1" in
      inspect)
        case "${3:-}" in
          '{{.Id}}') [ "$4" = ci-runner-1 ] && echo "$fixture_manager_id" || echo "$fixture_side_id" ;;
          '{{.Image}}') echo test-image ;;
        esac ;;
      start)
        [ -s "$profile/profile.env" ] && [ -s "$profile/buildkitd.toml" ] || fail 'restart preceded profile recovery'
        printf '%s\n' "$2" >> "$tmp/restarted" ;;
    esac
    return 0
  }
  gitlab_start_stopped ci-runner-1 1 "$fixture_manager_id"
  grep -qx "$fixture_side_id" "$tmp/restarted"
  grep -qx "$fixture_manager_id" "$tmp/restarted"
)

# Partial or substituted snapshots must fail, never be repaired in place.
mv "$profile/profile.env" "$tmp/saved.env"
if build_cache_profile >/dev/null 2>&1; then fail 'partial snapshot accepted'; fi
ln -s "$tmp/saved.env" "$profile/profile.env"
if build_cache_profile >/dev/null 2>&1; then fail 'symlink snapshot accepted'; fi
BUILD_CACHE_MODE=off
[ "$(crf_confgen)" = "$(gitlab_confgen)" ] || fail 'disabling does not restore legacy config'
[ -z "$(build_cache_profile)" ] || fail 'disabled profile remains active'
echo 'build-cache: OK'
