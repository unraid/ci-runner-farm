#!/usr/bin/env bash
# Validate the generated provider config with the configured official GitLab
# Runner image. CI runs this on a Linux host with Docker; local developers can
# run it after starting their daemon.
set -euo pipefail
cd "$(dirname "$0")/.."
docker info >/dev/null 2>&1 || { echo "gitlab-runner-lint: Docker daemon unavailable" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config"
export CRF_RUNDIR="$tmp/run"
export CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

CI_PROVIDER=gitlab
GITLAB_URL=https://gitlab.example.test
# Synthetic GitLab 18 routable-token shape: URL-safe payload plus the two
# version/length/CRC separators that originally exposed a stale local parser.
GITLAB_RUNNER_TOKEN=glrt-AAECAwQFBgcICQoLDA0OD286MQpwOjIKdTozCnQ6Mw8.01.170z6aiyq
GITLAB_RUNNER_IMAGE="$(sed -n 's/^GITLAB_RUNNER_IMAGE="\([^"]*\)".*/\1/p' src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg | head -1)"
[ -n "$GITLAB_RUNNER_IMAGE" ] \
  || { echo "gitlab-runner-lint: could not read GITLAB_RUNNER_IMAGE from default.cfg" >&2; exit 1; }
CACHE_ROOT="$tmp/cache"
CACHE_MOUNTS=''
RUNNER_CPUS='2'
GITLAB_ALLOWED_IMAGES='ci-runner-farm-gitlab-job:* registry.example.test/team/*:*'
GITLAB_ALLOWED_SERVICES='postgres:* redis:*'
GITLAB_PULL_POLICY='if-not-present'
GITLAB_SHM_SIZE='1073741824'
DIND=true
SHARE_DOCKER_SOCK=false
mkdir -p "$CACHE_ROOT"
# Exercise the conditional self-managed CA key with a real PEM bundle so Runner
# can open the configured path as well as parse it.
if [ -r /etc/ssl/certs/ca-certificates.crt ]; then
  cp /etc/ssl/certs/ca-certificates.crt "$GITLAB_CA_FILE"
elif [ -r /etc/ssl/cert.pem ]; then
  cp /etc/ssl/cert.pem "$GITLAB_CA_FILE"
else
  echo "gitlab-runner-lint: no host CA bundle found for the self-managed CA case" >&2
  exit 1
fi
printf '%s' "$GITLAB_RUNNER_TOKEN" > "$GITLAB_RUNNER_TOKEN_FILE"
reload_secret_files
gitlab_write_config 1 ci-runner-1
config_dir="$CRF_CFGDIR/gitlab-runners/ci-runner-1"

# Runner's decoder may discard an unknown TOML key before lint/schema checks.
# Verify the exact generated shape independently, including all conditional
# resource/CA keys, then let the official binary validate its own semantics.
CONFIG_PATH="$config_dir/config.toml" python3 - <<'PY'
import os
import tomllib

with open(os.environ["CONFIG_PATH"], "rb") as fh:
    config = tomllib.load(fh)

def exact_keys(value, expected, label):
    actual = set(value)
    expected = set(expected)
    if actual != expected:
        raise SystemExit(f"{label} keys differ: missing={sorted(expected-actual)} extra={sorted(actual-expected)}")

exact_keys(config, {
    "concurrent", "check_interval", "shutdown_timeout", "listen_address", "runners",
}, "global")
runners = config["runners"]
if not isinstance(runners, list) or len(runners) != 1:
    raise SystemExit("expected exactly one generated [[runners]] entry")
runner = runners[0]
exact_keys(runner, {
    "name", "url", "token", "executor", "limit", "request_concurrency",
    "environment", "tls-ca-file", "docker",
}, "runner")
docker = runner["docker"]
exact_keys(docker, {
    "host", "tls_verify", "image", "pull_policy", "allowed_pull_policies",
    "allowed_images", "allowed_services", "privileged",
    "disable_entrypoint_overwrite", "oom_kill_disable", "disable_cache",
    "cpus", "service_cpus", "memory", "service_memory", "shm_size",
    "volumes", "container_labels",
}, "runner.docker")
exact_keys(docker["container_labels"], {
    "net.unraid.ci-runner-farm.provider", "net.unraid.ci-runner-farm.slot",
}, "runner.docker.container_labels")
if runner["executor"] != "docker" or runner["tls-ca-file"] != "/etc/gitlab-runner/certs/gitlab-ca.crt":
    raise SystemExit("executor or self-managed CA path differs")
if not any(v.endswith(":/etc/gitlab-runner/certs/ca.crt:ro") for v in docker["volumes"]):
    raise SystemExit("self-managed CA is not mounted at the helper/job trust path")
if docker["cpus"] != "2" or docker["service_cpus"] != "2":
    raise SystemExit("job/service CPU keys differ")
if docker["pull_policy"] != "if-not-present" or docker["allowed_pull_policies"] != ["if-not-present"]:
    raise SystemExit("executor pull policy or its job-level restriction differs")
if docker["allowed_images"] != ["ci-runner-farm-gitlab-job:*", "registry.example.test/team/*:*"]:
    raise SystemExit("allowed image patterns differ")
if docker["allowed_services"] != ["postgres:*", "redis:*"]:
    raise SystemExit("allowed service patterns differ")
if docker["shm_size"] != 1073741824:
    raise SystemExit("executor shared-memory size differs")
PY

docker image inspect "$GITLAB_RUNNER_IMAGE" >/dev/null 2>&1 \
  || docker pull "$GITLAB_RUNNER_IMAGE" >/dev/null
if docker run --rm "$GITLAB_RUNNER_IMAGE" --help 2>&1 | grep -qE '(^|[[:space:]])lint([[:space:]]|$)'; then
  docker run --rm -v "$config_dir:/etc/gitlab-runner:ro" "$GITLAB_RUNNER_IMAGE" \
    lint --config /etc/gitlab-runner/config.toml
  echo "gitlab-runner-lint: generated config accepted by $GITLAB_RUNNER_IMAGE"
else
  list_rc=0
  list_output="$(docker run --rm -v "$config_dir:/etc/gitlab-runner:ro" \
    "$GITLAB_RUNNER_IMAGE" list 2>&1)" || list_rc=$?
  [ "$list_rc" -eq 0 ] \
    && gitlab_list_output_valid "$(host)-ci-runner-1" "$list_output" \
    || { printf '%s\n' "$list_output" >&2; echo "gitlab-runner-lint: list fallback rejected generated config" >&2; exit 1; }
  echo "gitlab-runner-lint: selected official image has no lint command; config parse fallback passed"
fi
