#!/usr/bin/env bash
# Focused provider-adapter tests with mocked Docker/curl. These exercise the
# generated GitLab TOML and status/API mappings without an Unraid host or daemon.
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
# Keep the real implementation available after transaction-specific mocks replace
# cmd_stop later in this single-process test harness.
eval "$(declare -f cmd_stop | sed '1s/^cmd_stop /engine_cmd_stop /')"

fail() { printf 'PROVIDER MOCK FAIL: %s\n' "$*" >&2; exit 1; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Upgrade/default contract and supported runner-auth token variants.
[ "$CI_PROVIDER" = github ] || fail "GitHub is not the source-only default"
[ "$(builtin_image)" = ci-runner-farm-runner:latest ] || fail "GitHub built-in image changed"

# GitHub adapter regression coverage: preserve the legacy repo/org argv,
# registration lifecycle, queue/stat mappings, status metadata, and GHCR PAT
# fallback while keeping the long-lived PAT out of runner argv.
CACHE_ROOT="$tmp/cache"; CACHE_MOUNTS=''; mkdir -p "$CACHE_ROOT"
ACCESS_TOKEN='github_pat_long_lived_secret_1234567890'
GH_OWNER='example-owner'; GH_REPOS='example/one example/two'
RUNNER_LABELS='self-hosted,unraid,build'; RUNNER_GROUP='secure-group'
RUNNER_CPUS='2'; RUNNER_MEMORY='4g'; IMAGE_SOURCE=builtin
WORK_TMPFS_SIZE='2g'; DIND=true; SHARE_DOCKER_SOCK=false
SHARED_IMAGE_CACHE=true; NETWORK_ISOLATION=off; EPHEMERAL=false; RUN_AS_ROOT=false
host() { printf 'mockhost\n'; }
legacy_confgen="$(printf '%s\0' "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" "$RUNNER_GROUP" "$RUNNER_LABELS" \
  "$EPHEMERAL" "$RUNNER_CPUS" "$RUNNER_MEMORY" "$WORK_TMPFS_SIZE" "$CACHE_MOUNTS" \
  "$DIND" "$SHARE_DOCKER_SOCK" "$RUN_AS_ROOT" "$IMAGE_SOURCE" "$IMAGE" \
  "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" \
  "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" | sha256sum | cut -c1-12)"
[ "$(crf_confgen)" = "$legacy_confgen" ] || fail "GitHub upgrade-safe config fingerprint changed"

# Exercise the REAL adapter transport before replacing gh_api with the response
# fixture below. The long-lived PAT must enter curl through config stdin and must
# never be present in argv (where it would be visible via /proc).
GH_CURL_ARGV="$tmp/github-curl.argv"; GH_CURL_STDIN="$tmp/github-curl.stdin"
curl() {
  printf '%s\n' "$*" > "$GH_CURL_ARGV"
  cat > "$GH_CURL_STDIN"
  printf '%s\n' '{"login":"mock-user"}'
}
[ "$(gh_api GET /user)" = '{"login":"mock-user"}' ] || fail "real GitHub API transport did not return curl response"
grep -qF "Authorization: Bearer $ACCESS_TOKEN" "$GH_CURL_STDIN" || fail "GitHub PAT was not sent through curl config stdin"
if grep -qF "$ACCESS_TOKEN" "$GH_CURL_ARGV"; then fail "GitHub PAT leaked into curl argv"; fi
unset -f curl

GH_API_LOG="$tmp/github-api.log"; : > "$GH_API_LOG"
gh_api() {
  printf '%s %s\n' "$1" "$2" >> "$GH_API_LOG"
  case "$1 $2" in
    POST*) printf '%s\n' '{"token":"short-registration-token"}' ;;
    GET*)  printf '%s\n' '{' '"id": 77,' '"name": "mockhost-ci-runner-1",' '"os": "linux"' '}' ;;
    DELETE*) return 0 ;;
  esac
}
[ "$(github_registration_token 'repo:example/one')" = short-registration-token ] \
  || fail "GitHub repo registration-token response mapping changed"
grep -qF 'POST /repos/example/one/actions/runners/registration-token' "$GH_API_LOG" \
  || fail "GitHub repo registration endpoint changed"

GH_SCOPE=repo
github_build_args 2 || fail "GitHub default-name repo argv generation failed"
github_args="$(printf '%s\n' "${ARGS[@]}")"
printf '%s\n' "$github_args" | grep -qx 'ci-runner-2' \
  || fail "GitHub default runner name did not use its function argument"
printf '%s\n' "$github_args" | grep -qx 'REPO_URL=https://github.com/example/two' \
  || fail "GitHub repo round-robin assignment changed"
printf '%s\n' "$github_args" | grep -qx 'RUNNER_TOKEN=short-registration-token' \
  || fail "short-lived GitHub registration token missing from runner argv"
if printf '%s\n' "$github_args" | grep -qF "$ACCESS_TOKEN"; then fail "GitHub PAT leaked into runner argv"; fi
printf '%s\n' "$github_args" | grep -qx -- '--privileged' || fail "GitHub DinD privilege flag missing"
printf '%s\n' "$github_args" | grep -qx 'START_DOCKER_SERVICE=true' || fail "GitHub DinD environment missing"
printf '%s\n' "$github_args" | grep -qx '/_work:rw,exec,size=2g' || fail "GitHub workspace tmpfs changed"

GH_SCOPE=org
github_build_args 1 ci-runner-1 || fail "GitHub org argv generation failed"
github_args="$(printf '%s\n' "${ARGS[@]}")"
for expected in 'RUNNER_SCOPE=org' 'ORG_NAME=example-owner' 'RUNNER_GROUP=secure-group'; do
  printf '%s\n' "$github_args" | grep -qx "$expected" || fail "GitHub org argv missing $expected"
done
grep -qF 'POST /orgs/example-owner/actions/runners/registration-token' "$GH_API_LOG" \
  || fail "GitHub org registration endpoint changed"

GH_SCOPE=repo; DIND=false; SHARE_DOCKER_SOCK=true; WORK_TMPFS_SIZE=''
github_build_args 1 ci-runner-1 || fail "GitHub host-socket argv generation failed"
github_args="$(printf '%s\n' "${ARGS[@]}")"
printf '%s\n' "$github_args" | grep -qx '/var/run/docker.sock:/var/run/docker.sock' \
  || fail "GitHub host-socket mount changed"
printf '%s\n' "$github_args" | grep -qx "$CACHE_ROOT/work/ci-runner-1:/_work" \
  || fail "GitHub bind-workspace fallback changed"

# GitHub removal must stop the listener before deleting its registration.
: > "$GH_API_LOG"
provider_stop_remove_container() { printf 'STOP %s\n' "$1" >> "$GH_API_LOG"; }
github_remove_runner ci-runner-1 false || fail "GitHub non-purge recycle removal failed"
[ "$(sed -n '1p' "$GH_API_LOG")" = 'STOP ci-runner-1' ] || fail "GitHub deregistration ran before container stop"
grep -qF 'GET /repos/example/one/actions/runners?per_page=100' "$GH_API_LOG" \
  || fail "GitHub runner discovery endpoint changed"
grep -qF 'DELETE /repos/example/one/actions/runners/77' "$GH_API_LOG" \
  || fail "GitHub runner deletion endpoint changed"

github_fetch_all() {
  case "$1" in
    *status=queued*) printf '%s' '{"total_count":2}' > "$2/1"; printf '%s' '{"total_count":3}' > "$2/2" ;;
    *) printf '%s' '{"workflow_runs":[{"conclusion":"success"},{"conclusion":"failure"}]}' > "$2/1"
       printf '%s' '{"workflow_runs":[{"conclusion":"cancelled"},{"conclusion":"timed_out"}]}' > "$2/2" ;;
  esac
}
github_queued_refresh
read -r ghq_provider _ ghq_count < "$CRF_RUNDIR/queued.cache"
[ "$ghq_provider" = github ] && [ "$ghq_count" = 5 ] || fail "GitHub queue mapping changed"
github_stats_refresh
read -r ghs_provider _ ghs_ok ghs_fail ghs_cancel ghs_other ghs_total < "$CRF_RUNDIR/stats.cache"
[ "$ghs_provider" = github ] && [ "$ghs_ok" = 1 ] && [ "$ghs_fail" = 2 ] \
  && [ "$ghs_cancel" = 1 ] && [ "$ghs_other" = 0 ] && [ "$ghs_total" = 4 ] \
  || fail "GitHub stats mapping changed"

docker() {
  case "$1" in
    logs) printf '%s\n' '2026-08-03T12:00:00Z Running job: compile' ;;
    exec) printf '%s\n' 'GITHUB_REPOSITORY=example/one' 'GITHUB_RUN_ID=123' 'GITHUB_REF_NAME=42/merge' ;;
  esac
}
job=''; jstarted='_'; project=''; job_id='_'; job_url=''; ref=''; ref_url=''
jrepo=''; jpr='_'; jbranch=''; jrun='_'
github_usage_context ci-runner-1
[ "$project" = example/one ] && [ "$job_id" = 123 ] && [ "$ref" = 'PR #42' ] \
  && [ "$job_url" = 'https://github.com/example/one/actions/runs/123' ] \
  || fail "GitHub provider-neutral job/status mapping changed"

REGISTRY_SERVER=ghcr.io; REGISTRY_USERNAME=''; REGISTRY_TOKEN=''
github_registry_probe() { local user="$REGISTRY_USERNAME" pass="$REGISTRY_TOKEN"; github_registry_credentials; printf '%s|%s\n' "$user" "$pass"; }
[ "$(github_registry_probe)" = "example-owner|$ACCESS_TOKEN" ] || fail "GitHub GHCR PAT fallback changed"

CI_PROVIDER=gitlab
# GitLab 18 routable runner tokens carry a base64url payload plus version,
# encoded-length, and CRC fields separated by two literal dots. Keep one fully
# synthetic but structurally realistic value throughout config/probe/retirement
# coverage so every credential parser proves that the complete token survives.
ROUTABLE_GITLAB_RUNNER_TOKEN='glrt-AAECAwQFBgcICQoLDA0OD286MQpwOjIKdTozCnQ6Mw8.01.170z6aiyq'
ROUTABLE_GITLAB_RUNNER_PAYLOAD="${ROUTABLE_GITLAB_RUNNER_TOKEN#glrt-}"
GITLAB_RUNNER_TOKEN="$ROUTABLE_GITLAB_RUNNER_TOKEN"
provider_token_ready || fail "routable exact-prefix glrt- token rejected"

# The endpoint and every runtime parser share a 507-character post-prefix cap.
printf -v max_runner_payload '%*s' 507 ''
max_runner_payload="${max_runner_payload// /a}"
GITLAB_RUNNER_TOKEN="glrt-$max_runner_payload"
provider_token_ready || fail "maximum-length glrt- token rejected"
GITLAB_RUNNER_TOKEN="glrt-${max_runner_payload}a"
if provider_token_ready; then fail "overlength glrt- token accepted"; fi

GITLAB_RUNNER_TOKEN="glrtr-$ROUTABLE_GITLAB_RUNNER_PAYLOAD"
if provider_token_ready; then fail "registration-created glrtr- token accepted for shared-manager lifecycle"; fi
GITLAB_RUNNER_TOKEN="acme-glrt-$ROUTABLE_GITLAB_RUNNER_PAYLOAD"
if provider_token_ready; then fail "instance-prefixed token accepted despite unsafe unregister dispatch"; fi
GITLAB_RUNNER_TOKEN=$'glrt-bad\nheader'
if provider_token_ready; then fail "control characters accepted in runner token"; fi

# UI/CLI log streams redact both the exact locked credential snapshot and common
# provider token shapes. Registry passwords may contain sed/shell punctuation and
# must still be treated literally.
redact_access='loaded-access-secret-1234'
redact_runner='loaded-glrt-runner-secret-1234'
redact_api='loaded-api-secret-5678'
redact_registry='reg[]/.*&\punct$token-9012'
redact_routable="$ROUTABLE_GITLAB_RUNNER_TOKEN"
redact_routable_legacy="glrtr-$ROUTABLE_GITLAB_RUNNER_PAYLOAD"
redact_routable_custom="acme-glrt-$ROUTABLE_GITLAB_RUNNER_PAYLOAD"
redacted_log="$(
  ACCESS_TOKEN="$redact_access"
  GITLAB_RUNNER_TOKEN="$redact_runner"
  GITLAB_API_TOKEN="$redact_api"
  REGISTRY_TOKEN="$redact_registry"
  printf '%s\n' \
    "loaded $ACCESS_TOKEN $GITLAB_RUNNER_TOKEN $GITLAB_API_TOKEN $REGISTRY_TOKEN" \
    'shape glrt-abcdefghijklmnop glrtr-abcdefghijklmnop acme-glrt-abcdefghijklmnop' \
    "shape $redact_routable $redact_routable_legacy $redact_routable_custom" \
    'shape glpat-abcdefghijklmnop github_pat_abcdefghijklmnop ghp_abcdefghijklmnop' \
    | redact_log_stream
)"
for leaked in "$redact_access" "$redact_runner" "$redact_api" "$redact_registry" \
  glrt-abcdefghijklmnop glrtr-abcdefghijklmnop acme-glrt-abcdefghijklmnop \
  "$redact_routable" "$redact_routable_legacy" "$redact_routable_custom" \
  glpat-abcdefghijklmnop github_pat_abcdefghijklmnop ghp_abcdefghijklmnop
do
  if printf '%s\n' "$redacted_log" | grep -Fq -- "$leaked"; then fail "log redaction leaked $leaked"; fi
done
printf '%s\n' "$redacted_log" | grep -q '\[REDACTED\]' \
  || fail "loaded-secret redaction marker is missing"
printf '%s\n' "$redacted_log" | grep -q '\[REDACTED_GITLAB_TOKEN\]' \
  || fail "GitLab shape redaction marker is missing"
printf '%s\n' "$redacted_log" \
  | grep -Fx 'shape [REDACTED_GITLAB_TOKEN] [REDACTED_GITLAB_TOKEN] [REDACTED_GITLAB_TOKEN]' >/dev/null \
  || fail "routable GitLab token redaction left a dotted suffix visible"
printf '%s\n' "$redacted_log" | grep -q '\[REDACTED_GITHUB_TOKEN\]' \
  || fail "GitHub shape redaction marker is missing"

GITLAB_RUNNER_TOKEN="$ROUTABLE_GITLAB_RUNNER_TOKEN"
GITLAB_URL='https://gitlab.example.test///'
[ "$(gitlab_url)" = 'https://gitlab.example.test' ] || fail "GitLab URL was not normalized"
GITLAB_RUNNER_IMAGE='gitlab/gitlab-runner:alpine'

# Every mode needs Runner 16+ for manager-only unregister; host-socket cleanup
# additionally depends on exact service labels fixed in 18.5. Probe the selected
# image, cache a successful result, and fail closed on old/prerelease/malformed
# output.
MANAGER_VERSION_LOG="$tmp/gitlab-manager-version.log"; : > "$MANAGER_VERSION_LOG"
(
  MOCK_MANAGER_VERSION='18.4.1'
  docker() {
    printf '%s\n' "$*" >> "$MANAGER_VERSION_LOG"
    if [ "$*" = "run --rm $GITLAB_RUNNER_IMAGE --version" ]; then
      case "$MOCK_MANAGER_VERSION" in
        fail) return 1 ;;
        *) printf 'Version:      %s\nGit revision: mock\n' "$MOCK_MANAGER_VERSION" ;;
      esac
    fi
  }

  DIND=true; MOCK_MANAGER_VERSION='15.11.1'; GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
  if gitlab_validate_host_socket_manager_version >/dev/null 2>&1; then exit 1; fi
  MOCK_MANAGER_VERSION='18.4.1'; GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
  gitlab_validate_host_socket_manager_version || exit 1
  probes="$(grep -c -- '--version' "$MANAGER_VERSION_LOG")"
  gitlab_validate_host_socket_manager_version || exit 1
  [ "$(grep -c -- '--version' "$MANAGER_VERSION_LOG")" -eq "$probes" ] || exit 1

  DIND=false; MOCK_MANAGER_VERSION='18.4.1'; GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
  if gitlab_validate_host_socket_manager_version >/dev/null 2>&1; then exit 1; fi
  MOCK_MANAGER_VERSION='18.5.0'; GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
  gitlab_validate_host_socket_manager_version || exit 1
  gitlab_validate_host_socket_manager_version || exit 1

  MOCK_MANAGER_VERSION='19.0.0'; GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
  gitlab_validate_host_socket_manager_version || exit 1
  MOCK_MANAGER_VERSION='18.5.0-rc1'; GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
  if gitlab_validate_host_socket_manager_version >/dev/null 2>&1; then exit 1; fi
  MOCK_MANAGER_VERSION='not-a-version'; GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
  if gitlab_validate_host_socket_manager_version >/dev/null 2>&1; then exit 1; fi
  MOCK_MANAGER_VERSION=fail; GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
  if gitlab_validate_host_socket_manager_version >/dev/null 2>&1; then exit 1; fi
) || fail "GitLab host-socket manager version gate failed"

DIND=true; SHARE_DOCKER_SOCK=false; NETWORK_ISOLATION=off
GITLAB_URL='http://gitlab.example.test'
if gitlab_validate_settings >/dev/null 2>&1; then fail "insecure HTTP GitLab URL accepted"; fi
for invalid_url in \
  'https://user@gitlab.example.test' \
  'https://gitlab.example.test?token=x' \
  'https://gitlab.example.test/#fragment' \
  'https://gitlab.example.test:70000' \
  'https://gitlab.example.test:bad' \
  'https://gitlab.example.test bad'
do
  GITLAB_URL="$invalid_url"
  if gitlab_validate_settings >/dev/null 2>&1; then fail "unsafe GitLab URL accepted: $invalid_url"; fi
done
GITLAB_URL='https://gitlab.example.test:8443/gitlab/'
gitlab_validate_settings >/dev/null 2>&1 || fail "valid self-managed GitLab subpath/port rejected"
[ "$(gitlab_url)" = 'https://gitlab.example.test:8443/gitlab' ] || fail "self-managed GitLab URL normalization changed"
for isolated_mode in isolate strict; do
  DIND=false; SHARE_DOCKER_SOCK=true; NETWORK_ISOLATION="$isolated_mode"
  if gitlab_validate_settings >/dev/null 2>&1; then
    fail "GitLab host-socket mode accepted unenforceable $isolated_mode networking"
  fi
done
DIND=true; SHARE_DOCKER_SOCK=false; NETWORK_ISOLATION=off
GITLAB_SHUTDOWN_TIMEOUT=29
if gitlab_validate_settings >/dev/null 2>&1; then fail "too-short GitLab graceful shutdown timeout accepted"; fi
GITLAB_SHUTDOWN_TIMEOUT=7200

# Generate a real per-slot config without Docker. The reusable token must exist
# only in the protected TOML—not manager argv—and system IDs must survive writes.
CACHE_ROOT="$tmp/cache"
CACHE_MOUNTS=''
IMAGE_SOURCE=builtin
mkdir -p "$CACHE_ROOT"
gitlab_write_config 1 ci-runner-1 || fail "GitLab TOML generation failed"
cfg="$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml"
[ "$(mode_of "$cfg")" = 600 ] || fail "config.toml is not mode 0600"
grep -q '^concurrent = 1$' "$cfg" || fail "global concurrency missing"
grep -q '^shutdown_timeout = 7200$' "$cfg" || fail "GitLab graceful shutdown timeout missing from TOML"
grep -q '^  limit = 1$' "$cfg" || fail "per-manager limit missing"
grep -q '^  executor = "docker"$' "$cfg" || fail "Docker executor missing"
grep -q 'FF_NETWORK_PER_BUILD=1' "$cfg" || fail "per-build networks missing"
grep -q 'image = "ci-runner-farm-gitlab-job:latest"' "$cfg" || fail "default GitLab job image missing"
grep -q 'pull_policy = "if-not-present"' "$cfg" || fail "built-in GitLab image pull policy is not if-not-present"
grep -q 'host = "unix:///runner-services/docker.sock"' "$cfg" \
  || fail "GitLab DinD manager does not use the restart-safe socket-directory path"
grep -q 'net.unraid.ci-runner-farm.slot' "$cfg" || fail "per-slot executor label missing"
grep -qF "$GITLAB_RUNNER_TOKEN" "$cfg" || fail "runner token not written to protected manager config"
[ "$(mode_of "$CRF_CFGDIR/gitlab-runners/ci-runner-1/.runner_system_id")" = 600 ] \
  || fail "generated system ID is not mode 0600"
first_system_id="$(cat "$CRF_CFGDIR/gitlab-runners/ci-runner-1/.runner_system_id")"
printf '%s' "$first_system_id" | grep -qE '^r_[a-f0-9]{12}$' || fail "generated GitLab system ID has an invalid shape"
gitlab_write_config 2 ci-runner-2 || fail "second-slot TOML generation failed"
second_system_id="$(cat "$CRF_CFGDIR/gitlab-runners/ci-runner-2/.runner_system_id")"
[ "$first_system_id" != "$second_system_id" ] || fail "fresh GitLab slots received the same system ID"
printf 's_c2d22f638c25\n' > "$CRF_CFGDIR/gitlab-runners/ci-runner-1/.runner_system_id"
gitlab_write_config 1 ci-runner-1 || fail "TOML rewrite failed"
grep -qx 's_c2d22f638c25' "$CRF_CFGDIR/gitlab-runners/ci-runner-1/.runner_system_id" || fail "system ID was not preserved"

# Verify the real reusable token through a dedicated manager identity before a
# slot can start. Because GitLab's verify endpoint creates that manager row, the
# transaction must immediately manager-unregister it and preserve retry material
# across ambiguous transport or cleanup failures.
VERIFY_CURL_ARGS="$tmp/gitlab-verify.argv"; VERIFY_CURL_BODY="$tmp/gitlab-verify.body"
VERIFY_DOCKER_ARGS="$tmp/gitlab-verify.docker"; : > "$VERIFY_DOCKER_ARGS"
VERIFY_HTTP=200; VERIFY_TRANSPORT_FAIL=0; VERIFY_UNREGISTER_FAIL=0
curl() {
  printf '%s\n' "$*" > "$VERIFY_CURL_ARGS"
  cat > "$VERIFY_CURL_BODY"
  [ "$VERIFY_TRANSPORT_FAIL" = 0 ] || return 7
  printf '%s' "$VERIFY_HTTP"
}
docker() {
  printf '%s\n' "$*" >> "$VERIFY_DOCKER_ARGS"
  case "$*" in
    "run --rm $GITLAB_RUNNER_IMAGE --version") printf 'Version:      18.5.0\nGit revision: mock\n' ;;
    'network inspect bridge') return 0 ;;
    *' unregister --name ci-runner-farm-token-probe') [ "$VERIFY_UNREGISTER_FAIL" = 0 ] ;;
  esac
}
GITLAB_MANAGER_VERSION_VALIDATED_KEY=''
GITLAB_TOKEN_PROBE_VALIDATED_TARGET=''
gitlab_verify_manager_token ci-runner-1 || fail "valid GitLab runner token/system ID verification failed"
probe_dir="$CRF_CFGDIR/gitlab-token-probe"
probe_system_id="$(cat "$probe_dir/.runner_system_id")"
grep -qx "token=$GITLAB_RUNNER_TOKEN&system_id=$probe_system_id" "$VERIFY_CURL_BODY" \
  || fail "GitLab verification omitted the dedicated probe token/system ID body"
grep -qF 'https://gitlab.example.test:8443/gitlab/api/v4/runners/verify' "$VERIFY_CURL_ARGS" \
  || fail "GitLab verification used the wrong normalized endpoint"
if grep -qF "$GITLAB_RUNNER_TOKEN" "$VERIFY_CURL_ARGS"; then fail "GitLab runner token leaked into curl argv"; fi
grep -q 'run --rm --network bridge .* unregister --name ci-runner-farm-token-probe' "$VERIFY_DOCKER_ARGS" \
  || fail "successful GitLab token verification left its temporary manager registered"
[ ! -e "$probe_dir/config.toml" ] || fail "successful GitLab token probe retained token-bearing retry config"

printf '%s\n' '-----BEGIN CERTIFICATE-----' 'YWJj' '-----END CERTIFICATE-----' > "$GITLAB_CA_FILE"
printf '%s' "$GITLAB_RUNNER_TOKEN" > "$GITLAB_RUNNER_TOKEN_FILE"
reload_secret_files
GITLAB_TOKEN_PROBE_VALIDATED_TARGET=''
gitlab_verify_manager_token ci-runner-1 || fail "GitLab token verification ignored the configured CA"
grep -qF -- "--cacert $probe_dir/certs/gitlab-ca.crt" "$VERIFY_CURL_ARGS" \
  || fail "GitLab verification omitted its protected self-managed CA snapshot"
rm -f "$GITLAB_CA_FILE"
reload_secret_files

VERIFY_HTTP=403
GITLAB_TOKEN_PROBE_VALIDATED_TARGET=''
if gitlab_verify_manager_token ci-runner-1 >/dev/null 2>&1; then fail "rejected GitLab runner token was accepted"; fi
[ ! -e "$probe_dir/config.toml" ] || fail "definitive 403 retained unnecessary probe credentials"

VERIFY_HTTP=200; VERIFY_TRANSPORT_FAIL=1
GITLAB_TOKEN_PROBE_VALIDATED_TARGET=''
if gitlab_verify_manager_token ci-runner-1 >/dev/null 2>&1; then fail "unreachable GitLab verification was accepted"; fi
[ -s "$probe_dir/config.toml" ] || fail "ambiguous GitLab verify transport failure discarded manager cleanup material"
VERIFY_TRANSPORT_FAIL=0
gitlab_verify_manager_token ci-runner-1 || fail "ambiguous GitLab token probe could not recover on retry"
[ ! -e "$probe_dir/config.toml" ] || fail "recovered GitLab token probe retained token-bearing config"

VERIFY_UNREGISTER_FAIL=1
GITLAB_TOKEN_PROBE_VALIDATED_TARGET=''
if gitlab_verify_manager_token ci-runner-1 >/dev/null 2>&1; then fail "GitLab token probe ignored manager-unregister failure"; fi
[ -s "$probe_dir/config.toml" ] || fail "failed probe unregister discarded exact retry material"
VERIFY_UNREGISTER_FAIL=0
gitlab_verify_manager_token ci-runner-1 || fail "GitLab token probe unregister did not recover on retry"
[ ! -e "$probe_dir/config.toml" ] || fail "recovered probe unregister retained token-bearing config"
unset -f curl

mkdir -p "$CRF_CFGDIR/gitlab-runners/ci-runner-4"
printf '%s\n' corrupt-system-id > "$CRF_CFGDIR/gitlab-runners/ci-runner-4/.runner_system_id"
if gitlab_ensure_system_id "$CRF_CFGDIR/gitlab-runners/ci-runner-4" >/dev/null 2>&1; then
  fail "invalid persisted GitLab system ID was silently replaced"
fi
grep -qx corrupt-system-id "$CRF_CFGDIR/gitlab-runners/ci-runner-4/.runner_system_id" \
  || fail "invalid persisted GitLab system ID was mutated"

gitlab_build_manager_args 1 || fail "default-name manager argv generation failed"
printf '%s\n' "${ARGS[@]}" | grep -qx 'ci-runner-1' \
  || fail "GitLab default manager name did not use its function argument"
if printf '%s\n' "${ARGS[@]}" | grep -qF "$GITLAB_RUNNER_TOKEN"; then fail "runner token leaked into Docker argv"; fi
printf '%s\n' "${ARGS[@]}" | grep -qF 'wget -qO- http://127.0.0.1:9252/metrics' \
  || fail "GitLab manager health check is not a local metrics probe"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--stop-signal' \
  || fail "GitLab manager does not explicitly use SIGQUIT stop semantics"
printf '%s\n' "${ARGS[@]}" | grep -qx 'SIGQUIT' \
  || fail "GitLab manager SIGQUIT value is missing"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--stop-timeout' \
  || fail "GitLab manager Docker stop timeout is missing"
printf '%s\n' "${ARGS[@]}" | grep -qx '7200' \
  || fail "GitLab manager Docker stop timeout value is missing"
printf '%s\n' "${ARGS[@]}" | grep -qx "$CACHE_ROOT/gitlab-sockets/ci-runner-1:/runner-services" \
  || fail "GitLab manager bind-mounts a stale socket inode instead of its socket directory"
if printf '%s\n' "${ARGS[@]}" | grep -qx "$CACHE_ROOT/gitlab-sockets/ci-runner-1/docker.sock:/var/run/docker.sock"; then
  fail "GitLab manager still bind-mounts the replaceable DinD socket file"
fi

# GitLab Runner's current receipt message is `Checking for jobs... received`,
# while completion messages begin with a capitalized `Job`. Normalize the log
# line before classifying it, but keep executor containers and metrics as the
# higher-confidence signals.
(
  STATE_JOB=''; STATE_METRICS=''; STATE_LOG=''
  gitlab_job_container() { printf '%s\n' "$STATE_JOB"; }
  docker() {
    case "${1:-}" in
      inspect) printf 'running\n' ;;
      exec) printf '%s\n' "$STATE_METRICS" ;;
      logs) printf '%s\n' "$STATE_LOG" ;;
    esac
  }

  STATE_JOB=runner-build-123
  STATE_METRICS='gitlab_runner_jobs 0'
  STATE_LOG='Job succeeded duration_s=4.2 job=123 project=456 runner=abc'
  [ "$(gitlab_runner_state ci-runner-1)" = busy ] \
    || exit 1

  STATE_JOB=''
  STATE_METRICS='gitlab_runner_jobs{runner="abc"} 1'
  STATE_LOG='Job succeeded duration_s=4.2 job=123 project=456 runner=abc'
  [ "$(gitlab_runner_state ci-runner-1)" = busy ] \
    || exit 1

  STATE_METRICS='gitlab_runner_jobs 0'
  STATE_LOG='Checking for jobs... received job=124 repo_url=https://gitlab.example.test/group/project.git runner=abc'
  [ "$(gitlab_runner_state ci-runner-1)" = busy ] \
    || exit 1

  STATE_LOG='Job succeeded duration_s=4.2 job=124 project=456 runner=abc'
  [ "$(gitlab_runner_state ci-runner-1)" = idle ] \
    || exit 1

  STATE_LOG='Checking for jobs... no jobs runner=abc status=204 No Content'
  [ "$(gitlab_runner_state ci-runner-1)" = idle ] \
    || exit 1
) || fail "GitLab manager state mapping did not recognize real Runner log messages"

# Official images without `lint` use `list`; require a clean schema diagnostic,
# the exact generated manager name, and Docker executor identity.
valid_list_output=$'Runtime platform arch=amd64 os=linux\nmockhost-ci-runner-1 Executor=docker Token=redacted URL=https://gitlab.example.test'
gitlab_list_output_valid mockhost-ci-runner-1 "$valid_list_output" \
  || fail "valid GitLab list fallback output was rejected"
if gitlab_list_output_valid mockhost-ci-runner-1 $'mockhost-ci-runner-1 Executor=docker\njsonschema: additionalProperties'; then
  fail "GitLab list fallback accepted jsonschema diagnostics"
fi
if gitlab_list_output_valid mockhost-ci-runner-1 $'There might be a problem with your config\nmockhost-ci-runner-1 Executor=docker'; then
  fail "GitLab list fallback accepted Runner config warning"
fi
if gitlab_list_output_valid wrong-name 'mockhost-ci-runner-1 Executor=docker'; then
  fail "GitLab list fallback accepted a missing generated manager"
fi
if gitlab_list_output_valid mockhost-ci-runner-1 'mockhost-ci-runner-1 Executor=shell'; then
  fail "GitLab list fallback accepted a non-Docker executor"
fi

printf '%s\n' '-----BEGIN CERTIFICATE-----' 'YWJj' '-----END CERTIFICATE-----' > "$CRF_CFGDIR/gitlab-ca.crt"
reload_secret_files
GITLAB_CA_FINGERPRINT='mock-ca-fingerprint'
gitlab_build_manager_args 1 ci-runner-1 || fail "custom-CA manager argv generation failed"
slot_ca="$CRF_CFGDIR/gitlab-runners/ci-runner-1/certs/gitlab-ca.crt"
grep -q 'tls-ca-file = "/etc/gitlab-runner/certs/gitlab-ca.crt"' "$cfg" || fail "custom CA is absent from GitLab TOML"
[ -d "$CRF_CFGDIR/gitlab-runners/ci-runner-1/certs" ] || fail "custom-CA bind target directory is missing"
cmp -s "$CRF_CFGDIR/gitlab-ca.crt" "$slot_ca" || fail "active CA was not snapshotted into the slot"
[ "$(mode_of "$slot_ca")" = 600 ] || fail "per-slot CA snapshot is not mode 0600"
printf '%s\n' "${ARGS[@]}" | grep -qx "$slot_ca:/etc/gitlab-runner/certs/gitlab-ca.crt:ro" \
  || fail "custom CA is absent from manager mounts"
grep -qF "$slot_ca:/etc/gitlab-runner/certs/ca.crt:ro" "$cfg" \
  || fail "custom CA is absent from Docker-executor helper/job mounts"
# Publishing any replacement config invalidates the completion marker associated
# with the prior manager identity, even if the rendered settings are identical.
unregister_marker="$CRF_CFGDIR/gitlab-runners/ci-runner-1/.remote-unregister-complete"
printf '%s\n' stale-manager-fingerprint > "$unregister_marker"
gitlab_write_config 1 ci-runner-1 || fail "GitLab config rewrite with stale unregister marker failed"
[ ! -e "$unregister_marker" ] || fail "new GitLab manager config retained a prior unregister completion marker"

# A nested Docker daemon must see the host-side CA bind source used by the
# generated executor config. It also needs Docker's exact certs.d authority for
# private registry image pulls; a port is part of that authority.
REGISTRY_SERVER='https://registry.gitlab.example.test:5443'
[ "$(gitlab_registry_authority)" = 'registry.gitlab.example.test:5443' ] \
  || fail "private registry CA authority normalization failed"
# A locally built default does not make job/service image overrides public. The
# configured registry credential must still reach each GitLab manager.
IMAGE_SOURCE=builtin
REGISTRY_USERNAME='gitlab-override-user'
REGISTRY_TOKEN='gitlab-override-registry-secret'
gitlab_write_docker_auth ci-runner-1 || fail "built-in-default GitLab registry auth generation failed"
slot_auth="$CRF_CFGDIR/gitlab-runners/ci-runner-1/docker/config.json"
[ -s "$slot_auth" ] && [ "$(mode_of "$slot_auth")" = 600 ] \
  || fail "built-in-default GitLab registry auth was not protected"
grep -qF 'registry.gitlab.example.test:5443' "$slot_auth" \
  || fail "built-in-default GitLab registry auth omitted the configured authority"
if grep -qF 'https://registry.gitlab.example.test:5443' "$slot_auth"; then
  fail "GitLab registry auth retained a URL scheme that cannot match image authorities"
fi
gitlab_build_manager_args 1 ci-runner-1 || fail "built-in-default GitLab manager auth mount generation failed"
printf '%s\n' "${ARGS[@]}" | grep -qx "$CRF_CFGDIR/gitlab-runners/ci-runner-1/docker:/root/.docker:ro" \
  || fail "built-in-default GitLab manager did not receive registry auth"
SIDECAR_ARGS="$tmp/gitlab-sidecar.args"
docker() {
  case "${1:-}" in
    inspect) return 1 ;;
    run) printf '%s\n' "$@" > "$SIDECAR_ARGS"; return 0 ;;
    --host) return 0 ;;
  esac
  return 0
}
gitlab_start_sidecar 1 ci-runner-1 || fail "custom-CA GitLab DinD sidecar generation failed"
grep -qx -- '--restart=unless-stopped' "$SIDECAR_ARGS" \
  || fail "GitLab DinD sidecar does not survive Docker daemon restarts"
expected_dind_suffix="$(printf '%s\n' "$GITLAB_DIND_IMAGE" dockerd --host=unix:///runner-services/docker.sock)"
[ "$(tail -n 3 "$SIDECAR_ARGS")" = "$expected_dind_suffix" ] \
  || fail "GitLab DinD sidecar does not retain the stock entrypoint with exactly one private Unix listener"
if grep -qF 'tcp://' "$SIDECAR_ARGS"; then
  fail "GitLab DinD sidecar exposes a TCP Docker API"
fi
grep -qx "type=bind,src=$slot_ca,dst=$slot_ca,readonly" "$SIDECAR_ARGS" \
  || fail "DinD cannot resolve the executor's custom-CA bind source"
grep -qx "type=bind,src=$slot_ca,dst=/etc/docker/certs.d/registry.gitlab.example.test:5443/ca.crt,readonly" "$SIDECAR_ARGS" \
  || fail "custom CA is absent from the configured DinD registry trust path"
grep -qx 'host.docker.internal:host-gateway' "$SIDECAR_ARGS" \
  || fail "GitLab DinD cannot resolve the shared mirror through the default host-gateway endpoint"

# GitLab DinD must not authenticate or pull the remote job image through the
# Unraid host daemon: that would bypass the per-slot CA and credential files.
# Host-socket mode still requires the legacy host login/pull path.
IMAGE_SOURCE=remote; IMAGE='registry.gitlab.example.test:5443/team/job:latest'
PREFLIGHT_LOG="$tmp/remote-preflight.log"; : > "$PREFLIGHT_LOG"
(
  check_cache_root() { :; }
  ensure_dirs() { :; }
  ensure_network() { :; }
  ensure_mirror() { :; }
  registry_login() { printf 'host-login\n' >> "$PREFLIGHT_LOG"; }
  host_docker_pull() { printf 'host-pull %s\n' "$1" >> "$PREFLIGHT_LOG"; }
  DIND=true; SHARE_DOCKER_SOCK=false
  provision_base
) || fail "GitLab DinD provider-aware preflight failed"
[ ! -s "$PREFLIGHT_LOG" ] || fail "GitLab DinD preflight touched host registry auth/pull"
# Recycle has an additional image guard before removing the old manager. A
# remote DinD image must pass that guard without either a host pull or a host
# image inspection; the replacement sidecar performs the real pull on start.
(
  host_docker_pull() { printf 'recycle-host-pull %s\n' "$1" >> "$PREFLIGHT_LOG"; return 1; }
  docker() { printf 'recycle-host-docker %s\n' "$*" >> "$PREFLIGHT_LOG"; return 1; }
  DIND=true; SHARE_DOCKER_SOCK=false
  recycle_image_preflight "$IMAGE"
) || fail "GitLab DinD remote recycle image preflight failed"
[ ! -s "$PREFLIGHT_LOG" ] || fail "GitLab DinD remote recycle inspected/pulled the job image on the host"
(
  check_cache_root() { :; }
  ensure_dirs() { :; }
  ensure_network() { :; }
  ensure_mirror() { :; }
  registry_login() { printf 'host-login\n' >> "$PREFLIGHT_LOG"; }
  host_docker_pull() { printf 'host-pull %s\n' "$1" >> "$PREFLIGHT_LOG"; }
  DIND=false; SHARE_DOCKER_SOCK=true
  provision_base
) || fail "GitLab host-socket provider-aware preflight failed"
grep -qx 'host-login' "$PREFLIGHT_LOG" || fail "GitLab host-socket preflight skipped host registry login"
grep -qx "host-pull $IMAGE" "$PREFLIGHT_LOG" || fail "GitLab host-socket preflight skipped host image pull"

# Common provisioning delegates before auth: a cached if-not-present image
# remains usable offline and does not require credentials that will not be used.
: > "$PREFLIGHT_LOG"
(
  check_cache_root() { :; }
  ensure_dirs() { :; }
  ensure_network() { :; }
  ensure_mirror() { :; }
  registry_login() { printf 'unexpected-login\n' >> "$PREFLIGHT_LOG"; return 1; }
  host_docker_pull() { printf 'unexpected-pull\n' >> "$PREFLIGHT_LOG"; return 1; }
  docker() { [ "$*" = "image inspect $IMAGE" ]; }
  DIND=false; SHARE_DOCKER_SOCK=true; GITLAB_PULL_POLICY=if-not-present
  provision_base
) || fail "cached GitLab if-not-present provisioning required unused registry credentials"
[ ! -s "$PREFLIGHT_LOG" ] || fail "cached GitLab if-not-present provisioning touched registry auth/pull"

# Pull-policy ownership is adapter-specific. DinD never touches the host daemon;
# host-socket mode refreshes host auth and honors always/if-not-present.
POLICY_LOG="$tmp/gitlab-pull-policy.log"; : > "$POLICY_LOG"
(
  registry_login() { printf 'login\n' >> "$POLICY_LOG"; }
  host_docker_pull() { printf 'pull %s\n' "$1" >> "$POLICY_LOG"; }
  docker() {
    printf 'docker %s\n' "$*" >> "$POLICY_LOG"
    case "$*" in image\ inspect*) [ "${POLICY_IMAGE_PRESENT:-0}" = 1 ] ;; esac
  }
  DIND=true; GITLAB_PULL_POLICY=always
  gitlab_prepare_remote_image "$IMAGE" || exit 1
  [ ! -s "$POLICY_LOG" ] || exit 1

  DIND=false; GITLAB_PULL_POLICY=always
  gitlab_prepare_remote_image "$IMAGE" || exit 1
  grep -qx login "$POLICY_LOG" && grep -qx "pull $IMAGE" "$POLICY_LOG" || exit 1
  gitlab_remote_image_update_allowed || exit 1

  : > "$POLICY_LOG"; POLICY_IMAGE_PRESENT=1; GITLAB_PULL_POLICY=if-not-present
  gitlab_prepare_remote_image "$IMAGE" || exit 1
  grep -q '^docker image inspect ' "$POLICY_LOG" || exit 1
  ! grep -q '^login$' "$POLICY_LOG" || exit 1
  ! grep -q '^pull ' "$POLICY_LOG" || exit 1
  if gitlab_remote_image_update_allowed; then exit 1; fi

  : > "$POLICY_LOG"; POLICY_IMAGE_PRESENT=0
  gitlab_prepare_remote_image "$IMAGE" || exit 1
  grep -qx login "$POLICY_LOG" || exit 1
  grep -qx "pull $IMAGE" "$POLICY_LOG" || exit 1

) || fail "GitLab remote-image host/DinD pull-policy contract failed"

# The slot daemon applies the same policy after DinD starts. In particular,
# `if-not-present` avoids needless network pulls.
SLOT_POLICY_LOG="$tmp/gitlab-slot-pull-policy.log"; : > "$SLOT_POLICY_LOG"
(
  docker() {
    printf '%s\n' "$*" >> "$SLOT_POLICY_LOG"
    case "$*" in
      *' image inspect '*) [ "${SLOT_IMAGE_PRESENT:-0}" = 1 ]; return ;;
      *' pull '*) return 0 ;;
    esac
    return 0
  }
  DIND=true; IMAGE_SOURCE=remote; IMAGE='registry.gitlab.example.test:5443/team/job:latest'
  GITLAB_PULL_POLICY=always; SLOT_IMAGE_PRESENT=1
  gitlab_ensure_job_image ci-runner-1 || exit 1
  grep -q ' pull registry.gitlab.example.test:5443/team/job:latest$' "$SLOT_POLICY_LOG" || exit 1

  : > "$SLOT_POLICY_LOG"; GITLAB_PULL_POLICY=if-not-present; SLOT_IMAGE_PRESENT=1
  gitlab_ensure_job_image ci-runner-1 || exit 1
  ! grep -q ' pull ' "$SLOT_POLICY_LOG" || exit 1

  : > "$SLOT_POLICY_LOG"; SLOT_IMAGE_PRESENT=0
  gitlab_ensure_job_image ci-runner-1 || exit 1
  grep -q ' pull registry.gitlab.example.test:5443/team/job:latest$' "$SLOT_POLICY_LOG" || exit 1

) || fail "GitLab per-slot Docker pull policy failed"

# For the editable built-in image, `auto` tracks rebuilds. Explicit
# if-not-present preserves an existing nested image instead of silently
# overwriting it with the host's newer image.
BUILTIN_POLICY_LOG="$tmp/gitlab-builtin-policy.log"; : > "$BUILTIN_POLICY_LOG"
(
  docker() {
    printf '%s\n' "$*" >> "$BUILTIN_POLICY_LOG"
    if [ "${1:-}" = image ] && [ "${2:-}" = inspect ] && [ "${3:-}" = -f ]; then
      printf '%s\n' sha256:new-host-image; return 0
    fi
    if [ "${1:-}" = --host ] && [ "${3:-}" = image ] && [ "${4:-}" = inspect ]; then
      [ -n "${BUILTIN_NESTED_ID:-}" ] || return 1
      printf '%s\n' "$BUILTIN_NESTED_ID"; return 0
    fi
    return 0
  }
  DIND=true; IMAGE_SOURCE=builtin; IMAGE=''
  GITLAB_PULL_POLICY=if-not-present; BUILTIN_NESTED_ID=sha256:old-nested-image
  gitlab_ensure_job_image ci-runner-1 || exit 1
  ! grep -q '^image save ' "$BUILTIN_POLICY_LOG" || exit 1

  : > "$BUILTIN_POLICY_LOG"; BUILTIN_NESTED_ID=''
  gitlab_ensure_job_image ci-runner-1 || exit 1
  grep -q '^image save ' "$BUILTIN_POLICY_LOG" && grep -q ' image load$' "$BUILTIN_POLICY_LOG" || exit 1

  : > "$BUILTIN_POLICY_LOG"; GITLAB_PULL_POLICY=auto; BUILTIN_NESTED_ID=sha256:old-nested-image
  gitlab_ensure_job_image ci-runner-1 || exit 1
  grep -q '^image save ' "$BUILTIN_POLICY_LOG" || exit 1
) || fail "GitLab built-in image pull-policy semantics failed"

# Host-socket cleanup is deliberately broader than busy-job discovery: every
# plugin-owned build, helper, and service container for the slot must be removed.
HOST_JOB_LOG="$tmp/gitlab-host-jobs.log"; : > "$HOST_JOB_LOG"
(
  docker() {
    printf '%s\n' "$*" >> "$HOST_JOB_LOG"
    case "$*" in
      'ps -aq '*) printf '%s\n' build-id helper-id service-id ;;
    esac
  }
  gitlab_remove_host_jobs ci-runner-1 || exit 1
) || fail "GitLab host-socket job/helper/service cleanup failed"
grep -q 'provider=gitlab' "$HOST_JOB_LOG" && grep -q 'slot=ci-runner-1' "$HOST_JOB_LOG" \
  || fail "GitLab host cleanup did not scope discovery to its provider and slot"
grep -q 'com.gitlab.gitlab-runner.managed=true' "$HOST_JOB_LOG" \
  || fail "GitLab host cleanup can select containers not owned by GitLab Runner"
if grep -q 'gitlab-runner.type=build' "$HOST_JOB_LOG"; then fail "GitLab host cleanup still filters out helper/service containers"; fi
grep -q '^rm -f build-id helper-id service-id$' "$HOST_JOB_LOG" \
  || fail "GitLab host cleanup did not remove all plugin-owned slot containers"

IMAGE_SOURCE=builtin; IMAGE=''; REGISTRY_SERVER=''; DIND=true; SHARE_DOCKER_SOCK=false

# The UI warning is a security contract, not marketing: per-slot Docker scope
# limits ordinary sibling access but privileged DinD is not a host boundary.
rm -f "$SECURITY_CACHE"
GITLAB_API_TOKEN=''; GITLAB_PROJECTS=''; DIND=true; SHARE_DOCKER_SOCK=false
security_warning="$(provider_public_problem)"
printf '%s' "$security_warning" | grep -qF 'job, helper, and service containers' \
  || fail "GitLab DinD warning omits the slot sibling-container blast radius"
printf '%s' "$security_warning" | grep -qF 'not a security boundary against the Unraid host' \
  || fail "GitLab DinD warning implies privileged DinD is a host boundary"
gitlab_gen_before="$(crf_confgen)"
GITLAB_RUNNER_TOKEN='glrt-memory-snapshot-changed-1234567890'
[ "$(crf_confgen)" != "$gitlab_gen_before" ] || fail "GitLab confgen ignores the in-memory runner token"
GITLAB_RUNNER_TOKEN="$ROUTABLE_GITLAB_RUNNER_TOKEN"
gitlab_gen_before="$(crf_confgen)"; REGISTRY_TOKEN='registry-memory-snapshot-changed'
[ "$(crf_confgen)" != "$gitlab_gen_before" ] || fail "GitLab confgen ignores the in-memory registry token"
REGISTRY_TOKEN=''

# Mock GitLab API pagination and a Jobs response containing nested pipeline and
# runner status fields. Tokens arrive through curl config stdin and must never
# appear in argv/logs.
export MOCK_CURL_ARGS="$tmp/curl.argv"
: > "$MOCK_CURL_ARGS"
curl() {
  local headers='' output='' url='' arg input code="${MOCK_CURL_STATUS:-200}"
  printf '%s\n' "$*" >> "$MOCK_CURL_ARGS"
  input="$(cat)"
  case "$input" in 'header = "PRIVATE-TOKEN: '*'"') ;; *) return 22 ;; esac
  while [ "$#" -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      -D) headers="$1"; shift ;;
      -o) output="$1"; shift ;;
      http*) url="$arg" ;;
    esac
  done
  [ -n "$headers" ] && printf 'HTTP/2 %s\r\n' "$code" > "$headers"
  if [ "$code" != 200 ]; then
    printf 'location: https://redirect.invalid/token-catcher\r\n\r\n' >> "$headers"
    printf '%s' '{"visibility":"public","id":999,"status":"success"}' > "$output"
    printf '%s' "$code"
    return 0
  fi
  if printf '%s' "$url" | grep -q 'scope%5B%5D=pending'; then
    if printf '%s' "$url" | grep -q 'group%2Fsub%2Fproject'; then
      printf 'x-total: 2\r\n\r\n' >> "$headers"
    else
      printf 'x-total: 3\r\n\r\n' >> "$headers"
    fi
    printf '%s' '[{"id":101,"status":"pending","pipeline":{"id":9},"runner":{"id":4}}]' > "$output"
  elif printf '%s' "$url" | grep -q '/jobs?per_page=50'; then
    if printf '%s' "$url" | grep -q 'group%2Fsub%2Fproject'; then
      printf '%s' '[{"id":7,"status":"canceled","pipeline":{"id":8,"status":"success"},"runner":{"id":9,"status":"online"}},{"id":10,"status":"skipped","pipeline":{"id":11,"status":"failed"},"runner":{"id":12,"status":"offline"}}]' > "$output"
    else
      printf '%s' '[{"id":1,"status":"success","pipeline":{"id":2,"status":"failed"},"runner":{"id":3,"status":"online"}},{"id":4,"status":"failed","pipeline":{"id":5,"status":"success"},"runner":{"id":6,"status":"offline"}}]' > "$output"
    fi
  else
    if printf '%s' "$url" | grep -q 'group%2Fsub%2Fproject'; then
      printf '%s' '{"visibility":"public"}' > "$output"
    else
      printf '%s' '{"visibility":"private"}' > "$output"
    fi
  fi
  printf '%s' "$code"
}

GITLAB_API_TOKEN='custom@prefix-token_1234567890'
GITLAB_PROJECTS='group/project group/sub/project'
gitlab_queued_refresh
read -r qprovider _ qcount < "$CRF_RUNDIR/queued.cache"
[ "$qprovider" = gitlab ] && [ "$qcount" = 5 ] || fail "GitLab multi-project queue pagination mapping is wrong"
gitlab_stats_refresh
read -r sprovider _ sok sfail scancel sother stotal < "$CRF_RUNDIR/stats.cache"
[ "$sprovider" = gitlab ] && [ "$sok" = 1 ] && [ "$sfail" = 1 ] \
  && [ "$scancel" = 1 ] && [ "$sother" = 1 ] && [ "$stotal" = 4 ] \
  || fail "GitLab multi-project stats aggregation counted nested status fields"
rm -f "$SECURITY_CACHE"
public_warning="$(gitlab_public_repo_problem)"
printf '%s' "$public_warning" | grep -qF 'group/sub/project' \
  || fail "GitLab public-project warning did not inspect every monitored project"
if grep -qF "$GITLAB_API_TOKEN" "$MOCK_CURL_ARGS"; then fail "API token leaked into curl argv"; fi
while IFS= read -r curl_args; do
  read -r -a curl_argv <<< "$curl_args"
  [ "${curl_argv[0]:-}" = -q ] || fail "GitLab API curl did not disable curlrc first"
  for curl_arg in "${curl_argv[@]}"; do
    case "$curl_arg" in
      --location|--location-trusted|--follow) fail "GitLab API curl can follow a redirect" ;;
      --*) ;;
      -*) case "${curl_arg#-}" in *L*) fail "GitLab API curl can follow a redirect" ;; esac ;;
    esac
  done
done < "$MOCK_CURL_ARGS"

# curl's fail mode treats 3xx as success. Every redirect status must therefore
# be rejected explicitly so a redirect body cannot become dashboard data and
# the custom PRIVATE-TOKEN can never reach its Location target.
for redirect_code in 300 301 302 303 307 308 399; do
  MOCK_CURL_STATUS="$redirect_code"
  gitlab_queued_refresh
  read -r _ _ qcount < "$CRF_RUNDIR/queued.cache"
  [ "$qcount" = -1 ] || fail "GitLab $redirect_code queue redirect was treated as API data"
  gitlab_stats_refresh
  read -r _ _ _ _ _ _ stotal < "$CRF_RUNDIR/stats.cache"
  [ "$stotal" = -1 ] || fail "GitLab $redirect_code stats redirect was treated as API data"
done
unset MOCK_CURL_STATUS

GITLAB_API_TOKEN=''
gitlab_queued_refresh
read -r _ _ qcount < "$CRF_RUNDIR/queued.cache"
[ "$qcount" = -1 ] || fail "missing API token did not produce unavailable queue sentinel"
gitlab_stats_refresh
read -r _ _ _ _ _ _ stotal < "$CRF_RUNDIR/stats.cache"
[ "$stotal" = -1 ] || fail "missing API token did not produce unavailable stats sentinel"

# Feed one neutral GitLab cache row into status-json and mock its single batched
# inspect. This proves the public mapping without exposing any CI environment.
GITLAB_RUNNER_TOKEN="$ROUTABLE_GITLAB_RUNNER_TOKEN"
GITLAB_API_TOKEN=''
cur_gen="$(crf_confgen)"
printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
  ci-runner-1 12.5 256 busy "$(_b64 compile)" 2026-08-03T12:00:00Z gitlab \
  "$(_b64 group/project)" 42 "$(_b64 'https://gitlab.example.test/group/project/-/jobs/42')" \
  "$(_b64 main)" "$(_b64 'https://gitlab.example.test/group/project/-/tree/main')" _ _ _ _ \
  > "$CRF_RUNDIR/usage.cache"
: > "$CRF_RUNDIR/warn.cache"; : > "$CRF_RUNDIR/sec.cache"
managed_names() { printf 'ci-runner-1\n'; }
docker() {
  if [ "${1:-}" = inspect ]; then
    printf '/ci-runner-1|running|2000000000|4294967296|%s|gitlab\n' "$cur_gen"
    return 0
  fi
  return 0
}
status_json="$(cmd_status_json)"
STATUS_JSON="$status_json" python3 -c '
import json, os
d = json.loads(os.environ["STATUS_JSON"])
r = (d.get("runners") or [{}])[0]
assert d.get("provider") == "gitlab" and d.get("token") is True
assert r.get("provider") == "gitlab" and r.get("project") == "group/project"
assert r.get("job_id") == "42" and r.get("ref") == "main"
assert r.get("repo") == "" and r.get("run_id") == ""
' || fail "provider-neutral status JSON mapping failed"
if printf '%s' "$status_json" | grep -qF "$GITLAB_RUNNER_TOKEN"; then fail "runner token leaked into status JSON"; fi

# A cache row must agree with the live container provider. This prevents stale
# provider-switch data from being presented as the new provider's current job.
printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
  ci-runner-1 99 999 busy "$(_b64 stale-job)" 2026-08-03T11:00:00Z github \
  "$(_b64 wrong/project)" 999 "$(_b64 'https://wrong.invalid/job')" \
  "$(_b64 wrong-ref)" "$(_b64 'https://wrong.invalid/ref')" "$(_b64 wrong/repo)" 9 "$(_b64 wrong)" 999 \
  > "$CRF_RUNDIR/usage.cache"
status_json="$(cmd_status_json)"
STATUS_JSON="$status_json" python3 -c '
import json, os
r = (json.loads(os.environ["STATUS_JSON"]).get("runners") or [{}])[0]
assert r.get("provider") == "gitlab"
assert r.get("phase") == "starting" and r.get("project") == ""
assert r.get("job_id") == "" and r.get("repo") == ""
' || fail "provider-mismatched status cache row was consumed"

# Pre-provider ten-field cache rows remain upgrade-compatible for a live GitHub
# container only; they also populate the new neutral URL/ref fields.
printf '%s %s %s %s %s %s %s %s %s %s\n' \
  ci-runner-1 6.25 128 busy "$(_b64 legacy-build)" 2026-08-03T10:00:00Z \
  "$(_b64 example/legacy)" 17 "$(_b64 feature/legacy)" 321 \
  > "$CRF_RUNDIR/usage.cache"
status_json="$(cmd_status_json)"
STATUS_JSON="$status_json" python3 -c '
import json, os
r = (json.loads(os.environ["STATUS_JSON"]).get("runners") or [{}])[0]
assert r.get("provider") == "gitlab" and r.get("phase") == "starting"
assert r.get("project") == "" and r.get("run_id") == ""
' || fail "legacy GitHub cache row was accepted for a live GitLab manager"

docker() {
  if [ "${1:-}" = inspect ]; then
    printf '/ci-runner-1|running|2000000000|4294967296|%s|github\n' "$cur_gen"
    return 0
  fi
  return 0
}
status_json="$(cmd_status_json)"
STATUS_JSON="$status_json" python3 -c '
import json, os
r = (json.loads(os.environ["STATUS_JSON"]).get("runners") or [{}])[0]
assert r.get("provider") == "github" and r.get("project") == "example/legacy"
assert r.get("job_id") == "321" and r.get("job_url") == "https://github.com/example/legacy/actions/runs/321"
assert r.get("ref") == "PR #17" and r.get("ref_url") == "https://github.com/example/legacy/pull/17"
assert r.get("repo") == "example/legacy" and r.get("run_id") == "321"
' || fail "legacy GitHub status cache compatibility/neutral URL mapping failed"

# A manager removed outside the lifecycle must not cause its only exact
# unregister identity to be silently scrubbed. Once a matching completion
# marker proves the remote manager deletion succeeded, the interrupted local
# credential cleanup is safe to finish while preserving the system ID.
saved_cfgdir="$CFGDIR"
CFGDIR="$tmp/orphan-cfg"
orphan_dir="$CFGDIR/gitlab-runners/ci-runner-7"
mkdir -p "$orphan_dir/docker" "$orphan_dir/certs"
printf '%s\n' '[[runners]]' '  name = "host-ci-runner-7"' \
  '  token = "glrt-orphan-manager-token-123456"' > "$orphan_dir/config.toml"
printf '%s\n' s_c2d22f638c25 > "$orphan_dir/.runner_system_id"
printf '%s\n' registry-auth > "$orphan_dir/docker/config.json"
printf '%s\n' saved-ca > "$orphan_dir/certs/gitlab-ca.crt"
docker() { return 1; }
if gitlab_assert_no_orphan_manager_configs >/dev/null 2>&1; then
  fail "missing GitLab manager credentials were silently accepted without unregister proof"
fi
[ -s "$orphan_dir/config.toml" ] && [ -s "$orphan_dir/docker/config.json" ] \
  || fail "orphan-manager check discarded unregister retry material"
orphan_identity="$(gitlab_unregister_identity "$orphan_dir")"
gitlab_mark_unregister_complete "$orphan_dir" "$orphan_identity" \
  || fail "could not create completed-unregister test marker"
gitlab_assert_no_orphan_manager_configs \
  || fail "completed unregister marker did not permit local credential scrub"
[ ! -e "$orphan_dir/config.toml" ] && [ ! -e "$orphan_dir/docker/config.json" ] \
  && [ ! -e "$orphan_dir/certs/gitlab-ca.crt" ] \
  || fail "completed unregister cleanup retained reusable credential material"
grep -qx s_c2d22f638c25 "$orphan_dir/.runner_system_id" \
  || fail "completed unregister cleanup removed the stable system ID"
CFGDIR="$saved_cfgdir"
docker() { return 0; }

# Credential clears are engine-owned fleet-lock transactions. Exercise the
# inner commands directly here (dispatch locking has a static contract check),
# with Docker/stop/reconcile mocked so no host daemon is required.
mkdir -p "$HOST_DOCKER_CONFIG" "$CRF_CFGDIR/docker-auth" \
  "$CRF_CFGDIR/gitlab-runners/ci-runner-1/docker"

ACCESS_TOKEN='github_pat_clear_transaction_secret_1234567890'
printf '%s' "$ACCESS_TOKEN" > "$TOKEN_FILE"
printf '%s' host-auth > "$HOST_DOCKER_CONFIG/config.json"
printf '%s' fallback-auth > "$CRF_CFGDIR/docker-auth/config.json"
cmd_credential_clear_github_token > "$tmp/clear-github.json" \
  || fail "GitHub credential clear transaction failed"
grep -q '"ok":true' "$tmp/clear-github.json" || fail "GitHub clear did not report success"
grep -q '"token_removed":true' "$tmp/clear-github.json" || fail "GitHub clear token result is missing"
grep -q '"host_auth_removed":true' "$tmp/clear-github.json" || fail "GitHub clear host-auth result is missing"
[ ! -e "$TOKEN_FILE" ] && [ ! -e "$HOST_DOCKER_CONFIG/config.json" ] \
  && [ ! -e "$CRF_CFGDIR/docker-auth/config.json" ] || fail "GitHub clear left a credential copy"
[ -z "$ACCESS_TOKEN" ] || fail "GitHub clear retained the in-memory PAT"
if grep -qF 'github_pat_clear_transaction_secret' "$tmp/clear-github.json"; then
  fail "GitHub PAT leaked into clear response"
fi

CI_PROVIDER=gitlab
GITLAB_RUNNER_TOKEN='glrt-clear-transaction-secret-1234567890'
printf '%s' "$GITLAB_RUNNER_TOKEN" > "$GITLAB_RUNNER_TOKEN_FILE"
printf '%s' token-bearing-toml > "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml"
printf '%s' interrupted-toml > "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml.tmp"
printf '%s\n' s_c2d22f638c25 > "$CRF_CFGDIR/gitlab-runners/ci-runner-1/.runner_system_id"
cmd_credential_clear_gitlab_runner 0 > "$tmp/clear-gitlab-unconfirmed.json" \
  || fail "unconfirmed GitLab clear response failed"
grep -q '"confirmation_required":true' "$tmp/clear-gitlab-unconfirmed.json" \
  || fail "active GitLab token clear did not require confirmation"
[ -e "$GITLAB_RUNNER_TOKEN_FILE" ] && [ -e "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml" ] \
  || fail "unconfirmed GitLab clear changed credentials"

cmd_stop() { printf '%s\n' 'mock GitLab fleet stopped and managers unregistered'; }
gitlab_assert_no_orphan_manager_configs() { return 0; }
gitlab_recover_pending_probe() { return 1; }
if cmd_credential_clear_gitlab_runner 1 > "$tmp/clear-gitlab-probe-blocked.json"; then
  fail "GitLab token clear ignored a pending probe-manager cleanup failure"
fi
[ -e "$GITLAB_RUNNER_TOKEN_FILE" ] \
  || fail "blocked GitLab token clear removed the only bootstrap credential before probe recovery"
grep -q '"token_removed":false' "$tmp/clear-gitlab-probe-blocked.json" \
  || fail "blocked GitLab token clear did not report credential preservation"
gitlab_recover_pending_probe() { return 0; }
cmd_credential_clear_gitlab_runner 1 > "$tmp/clear-gitlab-confirmed.json" \
  || fail "confirmed GitLab credential clear transaction failed"
grep -q '"ok":true' "$tmp/clear-gitlab-confirmed.json" || fail "confirmed GitLab clear did not report success"
grep -q '"fleet_stop_requested":true' "$tmp/clear-gitlab-confirmed.json" \
  || fail "confirmed GitLab clear did not report the stop request"
grep -q '"fleet_stopped":true' "$tmp/clear-gitlab-confirmed.json" \
  || fail "confirmed GitLab clear did not report a stopped fleet"
grep -q '"slot_configs_removed":true' "$tmp/clear-gitlab-confirmed.json" \
  || fail "confirmed GitLab clear did not report per-slot cleanup"
[ ! -e "$GITLAB_RUNNER_TOKEN_FILE" ] \
  && [ ! -e "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml" ] \
  && [ ! -e "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml.tmp" ] \
  || fail "confirmed GitLab clear left a token-bearing config"
grep -qx s_c2d22f638c25 "$CRF_CFGDIR/gitlab-runners/ci-runner-1/.runner_system_id" \
  || fail "GitLab clear removed or changed the persistent manager system ID"
[ -z "$GITLAB_RUNNER_TOKEN" ] || fail "GitLab clear retained the in-memory runner token"
if grep -qF 'glrt-clear-transaction-secret' "$tmp/clear-gitlab-confirmed.json"; then
  fail "GitLab runner token leaked into clear response"
fi

REGISTRY_TOKEN='registry-clear-transaction-secret'
printf '%s' "$REGISTRY_TOKEN" > "$REGISTRY_TOKEN_FILE"
printf '%s' slot-auth > "$CRF_CFGDIR/gitlab-runners/ci-runner-1/docker/config.json"
printf '%s' interrupted-auth > "$CRF_CFGDIR/gitlab-runners/ci-runner-1/docker/config.json.tmp"
printf '%s' host-auth > "$HOST_DOCKER_CONFIG/config.json"
printf '%s' fallback-auth > "$CRF_CFGDIR/docker-auth/config.json"
cmd_reconcile_config() { printf '%s\n' 'mock reconcile queued'; }
cmd_credential_clear_registry_token > "$tmp/clear-registry.json" \
  || fail "registry credential clear transaction failed"
for field in token_removed slot_auth_removed host_auth_removed reconcile_requested reconcile_started; do
  grep -q "\"$field\":true" "$tmp/clear-registry.json" || fail "registry clear result is missing $field=true"
done
[ ! -e "$REGISTRY_TOKEN_FILE" ] \
  && [ ! -e "$CRF_CFGDIR/gitlab-runners/ci-runner-1/docker/config.json" ] \
  && [ ! -e "$CRF_CFGDIR/gitlab-runners/ci-runner-1/docker/config.json.tmp" ] \
  && [ ! -e "$HOST_DOCKER_CONFIG/config.json" ] \
  && [ ! -e "$CRF_CFGDIR/docker-auth/config.json" ] \
  || fail "registry clear left a credential or derived Docker auth copy"
[ -z "$REGISTRY_TOKEN" ] || fail "registry clear retained the in-memory token"
if grep -qF 'registry-clear-transaction-secret' "$tmp/clear-registry.json"; then
  fail "registry token leaked into clear response"
fi

# A failed manager `docker run` may scrub its freshly rendered reusable token
# only when Docker positively proves no manager exists, or after an owned
# Created residue is removed by immutable ID. Any inspection/enumeration
# ambiguity must retain the complete identity for operator-safe recovery.
(
  START_FAIL_CFGDIR="$tmp/start-failure-config"
  START_FAIL_LOG="$tmp/start-failure.log"
  START_FAIL_NAME=ci-runner-8
  START_FAIL_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  CRF_CFGDIR="$START_FAIL_CFGDIR"
  mkdir -p "$CRF_CFGDIR"

  gitlab_validate_host_socket_manager_version() { return 0; }
  gitlab_verify_manager_token() { return 0; }
  gitlab_build_args() { ARGS=(--detach --name "$2" "$GITLAB_RUNNER_IMAGE"); }
  gitlab_start_sidecar() { return 0; }
  gitlab_ensure_job_image() { return 0; }
  gitlab_remove_sidecar() { printf 'SIDECAR_REMOVE %s\n' "$1" >> "$START_FAIL_LOG"; }
  managed_runner_snapshot() {
    case "$START_FAIL_MODE" in
      created) printf '%s|gitlab|manager|8|mock-generation\n' "$START_FAIL_ID" ;;
      unverified-created) printf '%s|github|runner|8|mock-generation\n' "$START_FAIL_ID" ;;
      *) return 1 ;;
    esac
  }
  docker() {
    printf 'DOCKER %s\n' "$*" >> "$START_FAIL_LOG"
    case "${1:-}" in
      image) return 0 ;;
      run) return 1 ;;
      inspect)
        if [ "${2:-}" = -f ]; then
          case "$START_FAIL_MODE" in
            created|unverified-created) printf 'created\n'; return 0 ;;
            *) return 1 ;;
          esac
        fi
        case "$START_FAIL_MODE" in
          created|unverified-created) return 0 ;;
          *) return 1 ;;
        esac
        ;;
      ps)
        case "$START_FAIL_MODE" in
          absent) return 0 ;;
          listed-but-uninspectable) printf '%s\n' "$START_FAIL_NAME"; return 0 ;;
          ambiguous) return 1 ;;
        esac
        ;;
      rm)
        [ "$START_FAIL_MODE" = created ] && [ "${2:-}" = "$START_FAIL_ID" ]
        return
        ;;
    esac
    return 1
  }
  prepare_start_failure_identity() {
    local dir
    dir="$(gitlab_slot_config_dir "$START_FAIL_NAME")"
    mkdir -p "$dir"
    printf '%s\n' token-bearing-config > "$dir/config.toml"
    printf '%s\n' s_c2d22f638c25 > "$dir/.runner_system_id"
  }
  start_failure_config() {
    printf '%s/config.toml\n' "$(gitlab_slot_config_dir "$START_FAIL_NAME")"
  }

  START_FAIL_MODE=absent; : > "$START_FAIL_LOG"; prepare_start_failure_identity
  if gitlab_start_one 8 "$START_FAIL_NAME" >/dev/null 2>&1; then
    fail "failed GitLab manager start unexpectedly succeeded"
  fi
  [ ! -e "$(start_failure_config)" ] \
    || fail "successful Docker enumeration proving manager absence retained credentials"
  grep -q '^DOCKER ps -a --format {{.Names}}$' "$START_FAIL_LOG" \
    || fail "failed manager start did not enumerate all containers before scrubbing"
  grep -q "^SIDECAR_REMOVE $START_FAIL_NAME$" "$START_FAIL_LOG" \
    || fail "proven-absent manager start failure retained its sidecar"

  START_FAIL_MODE=ambiguous; : > "$START_FAIL_LOG"; prepare_start_failure_identity
  if gitlab_start_one 8 "$START_FAIL_NAME" >/dev/null 2>&1; then
    fail "ambiguous failed GitLab manager start unexpectedly succeeded"
  fi
  [ -s "$(start_failure_config)" ] \
    || fail "Docker enumeration failure discarded protected manager identity"
  if grep -q '^SIDECAR_REMOVE ' "$START_FAIL_LOG"; then
    fail "Docker enumeration failure removed the protected manager sidecar"
  fi

  START_FAIL_MODE=listed-but-uninspectable; : > "$START_FAIL_LOG"; prepare_start_failure_identity
  if gitlab_start_one 8 "$START_FAIL_NAME" >/dev/null 2>&1; then
    fail "listed-but-uninspectable failed GitLab manager start unexpectedly succeeded"
  fi
  [ -s "$(start_failure_config)" ] \
    || fail "listed-but-uninspectable manager discarded protected identity"
  if grep -q '^SIDECAR_REMOVE ' "$START_FAIL_LOG"; then
    fail "listed-but-uninspectable manager removed its protected sidecar"
  fi

  START_FAIL_MODE=created; : > "$START_FAIL_LOG"; prepare_start_failure_identity
  if gitlab_start_one 8 "$START_FAIL_NAME" >/dev/null 2>&1; then
    fail "Created-residue GitLab manager start unexpectedly succeeded"
  fi
  grep -q "^DOCKER rm $START_FAIL_ID$" "$START_FAIL_LOG" \
    || fail "owned Created residue was not removed by immutable container ID"
  [ ! -e "$(start_failure_config)" ] \
    || fail "removed owned Created residue retained reusable credentials"
  grep -q "^SIDECAR_REMOVE $START_FAIL_NAME$" "$START_FAIL_LOG" \
    || fail "removed owned Created residue retained its sidecar"

  START_FAIL_MODE=unverified-created; : > "$START_FAIL_LOG"; prepare_start_failure_identity
  if gitlab_start_one 8 "$START_FAIL_NAME" >/dev/null 2>&1; then
    fail "unverified Created-residue GitLab manager start unexpectedly succeeded"
  fi
  [ -s "$(start_failure_config)" ] \
    || fail "unverified Created residue discarded protected manager identity"
  if grep -Eq '^DOCKER rm |^SIDECAR_REMOVE ' "$START_FAIL_LOG"; then
    fail "unverified Created residue triggered destructive local cleanup"
  fi
)

# The common stopped-slot loop must carry the immutable ID from its ownership
# snapshot into the provider adapter; a later fixed-name lookup is not an
# authority to restart whichever container happens to hold that name.
(
  DISPATCH_LOG="$tmp/start-stopped-dispatch.log"
  DISPATCH_MANAGER_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  CI_PROVIDER=gitlab
  managed_names() { printf '%s\n' ci-runner-1; }
  managed_runner_snapshot() {
    printf '%s|gitlab|manager|1|dispatch-generation\n' "$DISPATCH_MANAGER_ID"
  }
  crf_confgen() { printf '%s\n' dispatch-generation; }
  docker() {
    [ "$*" = "inspect -f {{.State.Running}} $DISPATCH_MANAGER_ID" ] || return 1
    printf 'false\n'
  }
  gitlab_start_stopped() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$DISPATCH_LOG"; }
  start_stopped_managed || fail "stopped-manager dispatch rejected an owned GitLab slot"
  grep -qx "ci-runner-1|1|$DISPATCH_MANAGER_ID" "$DISPATCH_LOG" \
    || fail "stopped-manager dispatch dropped its ownership-verified immutable ID"
)

# An unchanged stopped manager restarts in place (preserving system ID) without
# remote unregister. A retired manager drains before manager-only unregister,
# using its exact persisted name, old image, token, config, and system ID.
LIFECYCLE_LOG="$tmp/gitlab-lifecycle.log"; : > "$LIFECYCLE_LOG"
LIFECYCLE_STOP_FAIL=0
LIFECYCLE_UNREGISTER_FAIL=0
LIFECYCLE_RM_FAIL=0
LIFECYCLE_JOB=''
LIFECYCLE_JOB_IMAGE_FAIL=0
LIFECYCLE_MANAGER_ID=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
LIFECYCLE_NAME_MANAGER_ID="$LIFECYCLE_MANAGER_ID"
LIFECYCLE_SIDE_ID=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
UNREGISTER_MOUNT_FILE="$tmp/gitlab-unregister.mount"
UNREGISTER_CONFIG_CAPTURE="$tmp/gitlab-unregister.config"
UNREGISTER_CA_CAPTURE="$tmp/gitlab-unregister.ca"
gitlab_start_sidecar() { printf 'SIDECAR %s %s\n' "$1" "$2" >> "$LIFECYCLE_LOG"; }
gitlab_ensure_job_image() {
  printf 'JOB_IMAGE %s\n' "$1" >> "$LIFECYCLE_LOG"
  [ "$LIFECYCLE_JOB_IMAGE_FAIL" = 0 ]
}
docker() {
  local mount='' source='' arg fmt='' target=''
  printf 'DOCKER %s\n' "$*" >> "$LIFECYCLE_LOG"
  if [ "${1:-}" = stop ] && [ "$LIFECYCLE_STOP_FAIL" = 1 ]; then return 1; fi
  if [ "${1:-}" = rm ] && [ "${2:-}" = ci-runner-1 ] && [ "$LIFECYCLE_RM_FAIL" = 1 ]; then return 1; fi
  if [ "${1:-}" = inspect ]; then
    if [ "${2:-}" != -f ]; then return 0; fi
    fmt="${3:-}"; target="${4:-}"
    case "$fmt" in
      '{{.Id}}')
        [ "$target" = ci-runner-1 ] && printf '%s\n' "$LIFECYCLE_NAME_MANAGER_ID" \
          || { [ "$target" = ci-runner-1-dind ] && printf '%s\n' "$LIFECYCLE_SIDE_ID"; }
        ;;
      *State.Running*) printf 'false\n' ;;
      *'.Image'*) printf 'sha256:old-gitlab-runner-image\n' ;;
      *NetworkSettings.Networks*) printf 'bridge\n' ;;
      *ci-runner-farm.sidecar*) [ "$target" = "$LIFECYCLE_SIDE_ID" ] && printf 'true\n' ;;
      *ci-runner-farm.provider*) [ "$target" = "$LIFECYCLE_SIDE_ID" ] && printf 'gitlab\n' ;;
      *ci-runner-farm.role*) [ "$target" = "$LIFECYCLE_SIDE_ID" ] && printf 'dind\n' ;;
    esac
  fi
  if [ "${1:-}" = ps ] && printf '%s' "$*" | grep -q -- '--format {{.Names}}'; then
    printf '%s\n' ci-runner-1-dind
  fi
  if [ "${1:-}" = --host ] && printf '%s' "$*" | grep -q ' ps -q '; then
    [ -z "$LIFECYCLE_JOB" ] || printf '%s\n' "$LIFECYCLE_JOB"
  fi
  if [ "${1:-}" = run ] && printf '%s' "$*" | grep -q ' unregister --name '; then
    [ "$LIFECYCLE_UNREGISTER_FAIL" = 0 ] || return 1
    while [ "$#" -gt 0 ]; do
      arg="$1"; shift
      if [ "$arg" = -v ] && [ "$#" -gt 0 ]; then mount="$1"; break; fi
    done
    source="${mount%%:*}"
    [ -n "$source" ] && [ -s "$source/config.toml" ] || return 1
    printf '%s\n' "$source" > "$UNREGISTER_MOUNT_FILE"
    cp "$source/config.toml" "$UNREGISTER_CONFIG_CAPTURE"
    [ ! -s "$source/certs/gitlab-ca.crt" ] \
      || cp "$source/certs/gitlab-ca.crt" "$UNREGISTER_CA_CAPTURE"
    # The official command rewrites its mounted config on success. Simulate that
    # behavior to prove the adapter mounted a disposable copy, not the live slot.
    printf '%s\n' '# rewritten by gitlab-runner unregister' > "$source/config.toml"
  fi
  if [ "$*" = 'run --rm sha256:old-gitlab-runner-image --version' ]; then
    printf 'Version:      18.5.0\nGit revision: mock\n'
  fi
  return 0
}
if gitlab_start_stopped ci-runner-1 1 invalid-id >/dev/null 2>&1; then
  fail "stopped GitLab manager accepted an invalid immutable container ID"
fi
[ ! -s "$LIFECYCLE_LOG" ] \
  || fail "invalid stopped-manager ID reached Docker or sidecar preparation"
gitlab_start_stopped ci-runner-1 1 "$LIFECYCLE_MANAGER_ID" \
  || fail "unchanged stopped GitLab manager did not restart in place"
grep -q '^SIDECAR 1 ci-runner-1$' "$LIFECYCLE_LOG" || fail "stopped manager restart skipped its private Docker sidecar"
grep -q '^JOB_IMAGE ci-runner-1$' "$LIFECYCLE_LOG" || fail "stopped manager restart skipped default job-image preparation"
grep -q "^DOCKER inspect -f {{.Image}} $LIFECYCLE_MANAGER_ID$" "$LIFECYCLE_LOG" \
  || fail "stopped manager image validation did not use its immutable ID"
grep -q "^DOCKER start $LIFECYCLE_MANAGER_ID$" "$LIFECYCLE_LOG" \
  || fail "stopped manager was not started by immutable ID"
job_image_line="$(grep -n '^JOB_IMAGE ci-runner-1$' "$LIFECYCLE_LOG" | head -1 | cut -d: -f1 || true)"
manager_start_line="$(grep -n "^DOCKER start $LIFECYCLE_MANAGER_ID$" "$LIFECYCLE_LOG" | head -1 | cut -d: -f1 || true)"
[ -n "$job_image_line" ] && [ -n "$manager_start_line" ] && [ "$job_image_line" -lt "$manager_start_line" ] \
  || fail "stopped manager resumed before its default job image was prepared"
if grep -q unregister "$LIFECYCLE_LOG"; then fail "ordinary stopped-manager restart attempted unregister"; fi

: > "$LIFECYCLE_LOG"
start_slot_dir="$CRF_CFGDIR/gitlab-runners/ci-runner-1"
printf '%s\n' completed-identity > "$start_slot_dir/.remote-unregister-complete"
if gitlab_start_stopped ci-runner-1 1 "$LIFECYCLE_MANAGER_ID" >/dev/null 2>&1; then
  fail "remotely unregistered stopped GitLab manager restarted"
fi
if grep -Eq '^SIDECAR |^JOB_IMAGE |^DOCKER start ' "$LIFECYCLE_LOG"; then
  fail "unregister completion marker allowed stopped-manager restart preparation"
fi
rm -f "$start_slot_dir/.remote-unregister-complete"

: > "$LIFECYCLE_LOG"
LIFECYCLE_NAME_MANAGER_ID=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
if gitlab_start_stopped ci-runner-1 1 "$LIFECYCLE_MANAGER_ID" >/dev/null 2>&1; then
  fail "stopped GitLab manager restarted after its stable name was reused"
fi
if grep -Eq '^SIDECAR |^JOB_IMAGE |^DOCKER start ' "$LIFECYCLE_LOG"; then
  fail "manager name-reuse race reached stopped-manager restart preparation"
fi
LIFECYCLE_NAME_MANAGER_ID="$LIFECYCLE_MANAGER_ID"

: > "$LIFECYCLE_LOG"; LIFECYCLE_JOB_IMAGE_FAIL=1
if gitlab_start_stopped ci-runner-1 1 "$LIFECYCLE_MANAGER_ID" >/dev/null 2>&1; then
  fail "stopped GitLab manager restarted after default job-image preparation failed"
fi
grep -q '^SIDECAR 1 ci-runner-1$' "$LIFECYCLE_LOG" \
  || fail "job-image failure test did not reach sidecar preparation"
grep -q '^JOB_IMAGE ci-runner-1$' "$LIFECYCLE_LOG" \
  || fail "job-image failure test did not exercise image preparation"
if grep -q '^DOCKER start ' "$LIFECYCLE_LOG"; then
  fail "stopped manager resumed despite default job-image preparation failure"
fi
LIFECYCLE_JOB_IMAGE_FAIL=0

: > "$LIFECYCLE_LOG"; LIFECYCLE_JOB=surviving-build-container
[ "$(gitlab_runner_state ci-runner-1)" = busy ] \
  || fail "stopped GitLab manager did not report its surviving executor job as busy"
if gitlab_start_stopped ci-runner-1 1 "$LIFECYCLE_MANAGER_ID"; then
  fail "stopped GitLab manager restarted over a surviving job"
fi
if grep -q '^SIDECAR 1 ci-runner-1$' "$LIFECYCLE_LOG"; then
  fail "surviving-job guard ran after sidecar replacement was already allowed"
fi
if grep -q '^JOB_IMAGE ci-runner-1$' "$LIFECYCLE_LOG"; then
  fail "surviving-job guard ran after default job-image preparation was already allowed"
fi
if grep -q '^DOCKER start ' "$LIFECYCLE_LOG"; then
  fail "surviving-job guard still restarted the manager"
fi
LIFECYCLE_JOB=''

# Ordinary retirement must preserve that same surviving workload. A running
# manager's SIGQUIT normally drains it first; for an already-stopped manager,
# fail closed after the stop probe and leave interruption to force-forget.
: > "$LIFECYCLE_LOG"; LIFECYCLE_JOB=surviving-build-container
container_provider() { printf 'gitlab\n'; }
if gitlab_remove_runner ci-runner-1 false; then fail "GitLab retirement removed a surviving executor job"; fi
grep -q '^DOCKER stop --signal SIGQUIT --timeout 7200 ci-runner-1$' "$LIFECYCLE_LOG" \
  || fail "surviving-job retirement did not attempt the graceful manager stop"
if grep -Eq 'unregister|^DOCKER rm ' "$LIFECYCLE_LOG"; then
  fail "surviving-job retirement unregistered or removed the slot"
fi
LIFECYCLE_JOB=''

: > "$LIFECYCLE_LOG"
slot_dir="$CRF_CFGDIR/gitlab-runners/ci-runner-1"
mkdir -p "$slot_dir/certs"
printf '%s\n' \
  'concurrent = 1' \
  '[[runners]]' \
  '  name = "persisted-host-ci-runner-1"' \
  '  url = "https://old.gitlab.example.test/root"' \
  "  token = \"$ROUTABLE_GITLAB_RUNNER_TOKEN\"" \
  '  tls-ca-file = "/etc/gitlab-runner/certs/gitlab-ca.crt"' \
  > "$slot_dir/config.toml"
printf '%s\n' 's_c2d22f638c25' > "$slot_dir/.runner_system_id"
printf '%s\n' old-slot-ca > "$slot_dir/certs/gitlab-ca.crt"
printf '%s\n' old-slot-ca > "$tmp/old-slot-ca.expected"
printf '%s\n' new-global-ca > "$GITLAB_CA_FILE"
GITLAB_URL='https://new.gitlab.example.test'
cp "$slot_dir/config.toml" "$tmp/live-config.before-unregister"
gitlab_unregister_manager ci-runner-1 || fail "stopped manager one-shot unregister failed"
grep -q 'DOCKER run --rm --network bridge .*sha256:old-gitlab-runner-image unregister --name persisted-host-ci-runner-1' "$LIFECYCLE_LOG" \
  || fail "stopped manager did not unregister its exact persisted manager identity"
if grep -q -- '--all-runners' "$LIFECYCLE_LOG"; then fail "slot retirement used broad --all-runners unregister"; fi
if grep -q '^DOCKER exec ' "$LIFECYCLE_LOG"; then fail "stopped manager attempted docker exec unregister"; fi
unregister_mount="$(cat "$UNREGISTER_MOUNT_FILE")"
[ "$unregister_mount" != "$slot_dir" ] || fail "unregister mounted the live token-bearing slot directory"
[ ! -e "$unregister_mount" ] || fail "secure unregister workspace survived completion"
cmp -s "$slot_dir/config.toml" "$tmp/live-config.before-unregister" \
  || fail "official unregister rewrite changed the live slot config"
grep -q 'url = "https://old.gitlab.example.test/root"' "$UNREGISTER_CONFIG_CAPTURE" \
  || fail "unregister did not use the retired manager's persisted URL"
grep -qF "token = \"$ROUTABLE_GITLAB_RUNNER_TOKEN\"" "$UNREGISTER_CONFIG_CAPTURE" \
  || fail "unregister did not use the retired manager's persisted token"
cmp -s "$UNREGISTER_CA_CAPTURE" "$tmp/old-slot-ca.expected" \
  || fail "unregister used the replacement/global CA instead of the slot snapshot"
[ -s "$slot_dir/.remote-unregister-complete" ] \
  && [ "$(mode_of "$slot_dir/.remote-unregister-complete")" = 600 ] \
  || fail "successful manager unregister did not atomically persist a protected completion marker"
grep -qx 's_c2d22f638c25' "$slot_dir/.runner_system_id" \
  || fail "stopped manager unregister changed the persisted system ID"

# A repeated call for the same config/system-ID identity must not hit GitLab a
# second time, even if the remote command would now fail.
: > "$LIFECYCLE_LOG"; LIFECYCLE_UNREGISTER_FAIL=1
gitlab_unregister_manager ci-runner-1 || fail "completed manager unregister was not retry-safe"
if grep -q ' unregister --name ' "$LIFECYCLE_LOG"; then fail "completion marker allowed duplicate remote unregister"; fi
LIFECYCLE_UNREGISTER_FAIL=0

# The registration-created token form can delete the shared runner entity. Even
# a stale/tampered persisted config must fail closed without invoking unregister.
sed 's/token = "glrt-/token = "glrtr-/' "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml" \
  > "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml.swap"
mv "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml.swap" "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml"
: > "$LIFECYCLE_LOG"
if gitlab_unregister_manager ci-runner-1; then fail "glrtr- config reached unregister"; fi
if grep -q unregister "$LIFECYCLE_LOG"; then fail "unsafe token invoked GitLab unregister command"; fi
sed 's/token = "glrtr-/token = "glrt-/' "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml" \
  > "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml.swap"
mv "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml.swap" "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml"

# A slot config is generated with exactly one runner entry. Refuse broad or
# tampered multi-entry configs even when every token happens to be modern.
cp "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml" \
  "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml.one"
printf '%s\n' '[[runners]]' '  name = "unexpected-second-manager"' \
  '  token = "glrt-zyxwvutsrqponmlkjihgfedcba123456"' \
  >> "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml"
: > "$LIFECYCLE_LOG"
if gitlab_unregister_manager ci-runner-1; then fail "multi-entry config reached unregister"; fi
if grep -q unregister "$LIFECYCLE_LOG"; then fail "multi-entry config invoked GitLab unregister command"; fi
mv "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml.one" \
  "$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml"

# Explicit removal sends SIGQUIT and waits before unregistering this manager.
: > "$LIFECYCLE_LOG"; gitlab_clear_unregister_complete "$slot_dir"; LIFECYCLE_RM_FAIL=1
container_provider() { printf 'gitlab\n'; }
gitlab_remove_sidecar() { :; }
mkdir -p "$slot_dir/docker"
printf '%s\n' retired-registry-auth > "$slot_dir/docker/config.json"
if gitlab_remove_runner ci-runner-1 false; then fail "GitLab removal ignored a local Docker-rm failure"; fi
stop_line="$(grep -n '^DOCKER stop --signal SIGQUIT --timeout 7200 ci-runner-1$' "$LIFECYCLE_LOG" | head -1 | cut -d: -f1 || true)"
unregister_line="$(grep -n 'DOCKER run --rm .* unregister --name persisted-host-ci-runner-1$' "$LIFECYCLE_LOG" | head -1 | cut -d: -f1 || true)"
[ -n "$stop_line" ] && [ -n "$unregister_line" ] && [ "$stop_line" -lt "$unregister_line" ] \
  || fail "GitLab manager did not drain before manager-only unregister"
[ -s "$slot_dir/.remote-unregister-complete" ] \
  || fail "Docker-rm failure lost the successful remote-unregister marker"
for retry_file in "$slot_dir/config.toml" "$slot_dir/docker/config.json" \
  "$slot_dir/certs/gitlab-ca.crt" "$slot_dir/.remote-unregister-complete"; do
  [ -s "$retry_file" ] || fail "failed retirement prematurely scrubbed retry material: $retry_file"
done

# Retrying local removal uses the marker and must succeed without a duplicate API
# call, even when the unregister transport is deliberately broken. Only after
# every remote/local step succeeds may reusable credentials, CA, and marker be
# scrubbed; the stable system ID remains.
: > "$LIFECYCLE_LOG"; LIFECYCLE_RM_FAIL=0; LIFECYCLE_UNREGISTER_FAIL=1
gitlab_remove_runner ci-runner-1 false || fail "GitLab local cleanup retry failed after successful remote unregister"
if grep -q ' unregister --name ' "$LIFECYCLE_LOG"; then fail "Docker-rm retry repeated the remote unregister API call"; fi
grep -q '^DOCKER rm ci-runner-1$' "$LIFECYCLE_LOG" || fail "Docker-rm retry did not remove the stopped manager"
for retired_file in \
  "$slot_dir/config.toml" "$slot_dir/config.toml.tmp" \
  "$slot_dir/docker/config.json" "$slot_dir/docker/config.json.tmp" \
  "$slot_dir/.remote-unregister-complete" "$slot_dir/.remote-unregister-complete.tmp" \
  "$slot_dir/certs/gitlab-ca.crt" "$slot_dir/certs/gitlab-ca.crt.tmp"; do
  [ ! -e "$retired_file" ] || fail "successful retirement retained credential/CA state: $retired_file"
done
grep -qx s_c2d22f638c25 "$slot_dir/.runner_system_id" \
  || fail "successful retirement removed or changed the stable system ID"
LIFECYCLE_UNREGISTER_FAIL=0

# A failed stop must leave the live manager, its job containers, and its sidecar
# untouched so a cleanup attempt cannot break a manager that is still serving.
: > "$LIFECYCLE_LOG"; LIFECYCLE_STOP_FAIL=1
if gitlab_remove_runner ci-runner-1 false; then fail "GitLab removal ignored a manager stop failure"; fi
grep -q '^DOCKER stop --signal SIGQUIT --timeout 7200 ci-runner-1$' "$LIFECYCLE_LOG" \
  || fail "GitLab failed-stop path did not attempt the graceful stop"
if grep -Eq 'unregister|^DOCKER rm ' "$LIFECYCLE_LOG"; then
  fail "GitLab failed-stop path unregistered or removed a still-live manager"
fi

# A failed manager-only API unregister keeps the stopped container, its exact
# persisted token/system ID, and sidecar available for a safe retry.
: > "$LIFECYCLE_LOG"
mkdir -p "$slot_dir/certs" "$slot_dir/docker"
cp "$tmp/live-config.before-unregister" "$slot_dir/config.toml"
printf '%s\n' old-slot-ca > "$slot_dir/certs/gitlab-ca.crt"
printf '%s\n' retired-registry-auth > "$slot_dir/docker/config.json"
gitlab_clear_unregister_complete "$slot_dir"
LIFECYCLE_STOP_FAIL=0; LIFECYCLE_UNREGISTER_FAIL=1
if gitlab_remove_runner ci-runner-1 false; then fail "GitLab removal ignored manager unregister failure"; fi
grep -q 'unregister --name persisted-host-ci-runner-1' "$LIFECYCLE_LOG" \
  || fail "GitLab removal did not attempt exact manager unregister"
if grep -q '^DOCKER rm ' "$LIFECYCLE_LOG"; then
  fail "GitLab unregister failure discarded the persisted manager needed for retry"
fi
for retry_file in "$slot_dir/config.toml" "$slot_dir/docker/config.json" \
  "$slot_dir/certs/gitlab-ca.crt" "$slot_dir/.runner_system_id"; do
  [ -s "$retry_file" ] || fail "unregister failure scrubbed retry material: $retry_file"
done
LIFECYCLE_UNREGISTER_FAIL=0

# Break-glass force-forget is local-only. It verifies manager/sidecar ownership,
# removes every labelled slot workload, scrubs reusable credentials and retry
# markers, and preserves the stable non-secret system ID for retry/diagnostics.
FORCE_LOG="$tmp/gitlab-force-forget.log"; : > "$FORCE_LOG"
FORCE_MANAGER_EXISTS=1; FORCE_SIDE_EXISTS=1; FORCE_UNOWNED=0; FORCE_JOBS=1
FORCE_MANAGER_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FORCE_SIDE_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
crf_safe_cache_root() { printf '%s\n' "$CACHE_ROOT"; }
docker() {
  local fmt='' target=''
  printf '%s\n' "$*" >> "$FORCE_LOG"
  case "${1:-}" in
    inspect)
      if [ "${2:-}" != -f ]; then
        case "${2:-}" in
          ci-runner-1|$FORCE_MANAGER_ID) [ "$FORCE_MANAGER_EXISTS" = 1 ] ;;
          ci-runner-1-dind|$FORCE_SIDE_ID) [ "$FORCE_SIDE_EXISTS" = 1 ] ;;
          *) return 1 ;;
        esac
        return
      fi
      fmt="${3:-}"; target="${4:-}"
      case "$fmt" in
        '{{.Id}}')
          [ "$target" = ci-runner-1 ] && printf '%s\n' "$FORCE_MANAGER_ID" \
            || { [ "$target" = ci-runner-1-dind ] && printf '%s\n' "$FORCE_SIDE_ID"; }
          ;;
        *ci-runner-farm.managed*) [ "$FORCE_UNOWNED" = 0 ] && printf 'true\n' ;;
        *ci-runner-farm.sidecar*) printf 'true\n' ;;
        *ci-runner-farm.provider*) printf 'gitlab\n' ;;
        *ci-runner-farm.role*)
          [ "$target" = "$FORCE_SIDE_ID" ] && printf 'dind\n' || printf '%s\n' "$([ "$FORCE_UNOWNED" = 0 ] && echo manager || echo foreign)" ;;
      esac
      ;;
    ps)
      [ "$FORCE_JOBS" = 1 ] && printf '%s\n' force-build force-helper force-service
      ;;
    rm) return 0 ;;
  esac
  return 0
}
mkdir -p "$slot_dir/docker"
mkdir -p "$slot_dir/certs" "$CACHE_ROOT/docker/ci-runner-1" \
  "$CACHE_ROOT/gitlab-sockets/ci-runner-1" "$CACHE_ROOT/gitlab-cache/ci-runner-1"
printf '%s\n' live-token-config > "$slot_dir/config.toml"
printf '%s\n' interrupted-config > "$slot_dir/config.toml.tmp"
printf '%s\n' derived-registry-auth > "$slot_dir/docker/config.json"
printf '%s\n' interrupted-auth > "$slot_dir/docker/config.json.tmp"
printf '%s\n' completed-identity > "$slot_dir/.remote-unregister-complete"
printf '%s\n' interrupted-marker > "$slot_dir/.remote-unregister-complete.tmp"
printf '%s\n' retired-ca > "$slot_dir/certs/gitlab-ca.crt"
printf '%s\n' s_c2d22f638c25 > "$slot_dir/.runner_system_id"
gitlab_force_forget_local ci-runner-1 || fail "local GitLab force-forget failed"
for removed in \
  "rm -f $FORCE_MANAGER_ID" \
  'rm -f force-build force-helper force-service' \
  "rm -f $FORCE_SIDE_ID"
do
  grep -qx "$removed" "$FORCE_LOG" || fail "force-forget missed local removal: $removed"
done
if grep -q unregister "$FORCE_LOG"; then fail "force-forget contacted the GitLab unregister path"; fi
for secret_copy in \
  "$slot_dir/config.toml" "$slot_dir/config.toml.tmp" \
  "$slot_dir/docker/config.json" "$slot_dir/docker/config.json.tmp" \
  "$slot_dir/.remote-unregister-complete" "$slot_dir/.remote-unregister-complete.tmp" \
  "$slot_dir/certs/gitlab-ca.crt"
do
  [ ! -e "$secret_copy" ] || fail "force-forget retained local credential/retry state: $secret_copy"
done
for purged_root in "$CACHE_ROOT/docker/ci-runner-1" \
  "$CACHE_ROOT/gitlab-sockets/ci-runner-1" "$CACHE_ROOT/gitlab-cache/ci-runner-1"; do
  [ ! -e "$purged_root" ] || fail "force-forget retained slot runtime data: $purged_root"
done
grep -qx s_c2d22f638c25 "$slot_dir/.runner_system_id" \
  || fail "force-forget removed or changed the persistent system ID"

# The action is retryable after the manager has already disappeared. Conversely,
# an unowned name collision must fail before any destructive Docker command.
: > "$FORCE_LOG"; FORCE_MANAGER_EXISTS=0; FORCE_SIDE_EXISTS=0; FORCE_JOBS=0
gitlab_force_forget_local ci-runner-1 || fail "force-forget was not retryable after local manager removal"
: > "$FORCE_LOG"; FORCE_MANAGER_EXISTS=1; FORCE_SIDE_EXISTS=0; FORCE_UNOWNED=1
if gitlab_force_forget_local ci-runner-1 >/dev/null 2>&1; then fail "force-forget accepted an unowned manager collision"; fi
if grep -q '^rm ' "$FORCE_LOG"; then fail "force-forget mutated Docker after an ownership-check failure"; fi
if gitlab_force_forget_local ../ci-runner-1 >/dev/null 2>&1; then fail "force-forget accepted an unsafe slot name"; fi

# Before Unraid stops Docker, every running GitLab manager must receive its
# graceful stop concurrently while the DinD sidecars are still alive. GitHub
# containers and all remote/local unregister/remove paths remain untouched.
(
SHUTDOWN_LOG="$tmp/gitlab-docker-shutdown.log"; : > "$SHUTDOWN_LOG"
managed_names() { printf '%s\n' ci-runner-1 ci-runner-2 ci-runner-3; }
managed_runner_snapshot() {
  case "$1" in
    ci-runner-1) printf '%064d|gitlab|manager|1|mock-generation\n' 1 ;;
    ci-runner-2) printf '%064d|gitlab|manager|2|mock-generation\n' 2 ;;
    ci-runner-3) printf '%064d|github|runner|3|mock-generation\n' 3 ;;
    *) return 1 ;;
  esac
}
docker() {
  if [ "${1:-}" = inspect ] && [ "${2:-}" = -f ]; then printf 'true\n'; fi
}
provider_stop_container() { printf 'QUIESCE %s\n' "$1" >> "$SHUTDOWN_LOG"; }
cmd_docker_stopping_locked || fail "GitLab Docker-shutdown quiesce failed"
grep -qx 'QUIESCE ci-runner-1' "$SHUTDOWN_LOG" || fail "first GitLab manager was not quiesced"
grep -qx 'QUIESCE ci-runner-2' "$SHUTDOWN_LOG" || fail "second GitLab manager was not quiesced"
if grep -q 'ci-runner-3\|unregister\|DOCKER rm' "$SHUTDOWN_LOG"; then
  fail "Docker-shutdown quiesce touched GitHub or removed/unregistered a manager"
fi
)

# Restart must not hide a failed stop/unregister behind a successful subsequent
# start, and image auto-update must use the validated recycle preflight instead
# of directly removing capacity before credentials/settings are checked.
ACTION_LOG="$tmp/action-safety.log"; : > "$ACTION_LOG"
cmd_stop() { printf 'stop\n' >> "$ACTION_LOG"; return 1; }
cmd_start() { printf 'start\n' >> "$ACTION_LOG"; }
if cmd_restart; then fail "restart masked a stop/unregister failure"; fi
grep -qx stop "$ACTION_LOG" || fail "restart did not attempt stop"
if grep -q start "$ACTION_LOG"; then fail "restart started replacements after stop failed"; fi

: > "$ACTION_LOG"
runner_busy() { return 1; }
managed_names() { printf '%s\n' ci-runner-1; }
docker() {
  case "$*" in
    'ps -a --format {{.Names}}') printf '%s\n' ci-runner-1 ;;
  esac
}
cmd_recycle() { printf 'recycle %s\n' "$1" >> "$ACTION_LOG"; return 1; }
if drain_and_recreate ci-runner-1; then fail "image update ignored validated recycle failure"; fi
grep -qx 'recycle ci-runner-1' "$ACTION_LOG" || fail "image update bypassed cmd_recycle preflight"

# A failed manager removal leaves its workload intact. Global Stop must then
# preserve host-socket jobs, mirrors, and strict firewall/network policy rather
# than weakening isolation underneath the survivor.
: > "$ACTION_LOG"
managed_names() { printf '%s\n' ci-runner-1; }
remove_runner() { printf 'remove %s\n' "$1" >> "$ACTION_LOG"; return 1; }
autoscale_stop() { :; }; imageupdate_stop() { :; }
quiesce_gitlab_managers_for_stop() { :; }
gitlab_stop_cleanup() { printf 'job-cleanup\n' >> "$ACTION_LOG"; }
gitlab_cleanup_orphan_sidecars() { printf 'sidecar-cleanup\n' >> "$ACTION_LOG"; }
firewall_clear() { printf 'firewall-clear\n' >> "$ACTION_LOG"; }
if engine_cmd_stop >/dev/null 2>&1; then fail "global Stop ignored a surviving manager"; fi
grep -qx 'remove ci-runner-1' "$ACTION_LOG" || fail "global Stop did not try the manager removal"
if grep -Eq 'job-cleanup|sidecar-cleanup|firewall-clear' "$ACTION_LOG"; then
  fail "global Stop tore down jobs/sidecars/isolation underneath a surviving manager"
fi

echo "provider-mocks: OK — adapters, lifecycle, TOML, API/status mappings, and credential clears"
