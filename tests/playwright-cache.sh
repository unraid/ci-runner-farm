#!/usr/bin/env bash
# The shared ms-playwright cache disables Playwright's browser GC on GitHub
# runners and GitLab jobs, and drains existing slots onto that setting.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'PLAYWRIGHT CACHE FAIL: %s\n' "$*" >&2; exit 1; }
gc_off=PLAYWRIGHT_SKIP_BROWSER_GC=1
salt=-ms-playwright-nogc-v1

# shellcheck disable=SC2034 # configuration consumed by sourced provider functions
{
  CACHE_ROOT="$tmp/cache"; ACCESS_TOKEN=''; NO_REGISTER=1
  GH_SCOPE=org; GH_OWNER=example; DIND=false; SHARE_DOCKER_SOCK=false
  NETWORK_ISOLATION=off; WORK_TMPFS_SIZE=64m; RUNNER_LABELS=self-hosted
}
mkdir -p "$CACHE_ROOT"
host() { printf 'mockhost\n'; }
runner_host_service_ipv4() { printf '192.0.2.10\n'; }
argv() { printf '%s\n' "${ARGS[@]}"; }
github_fingerprint_input() {
  ( sha256sum() { cat > "$tmp/fingerprint"; printf 'stub  -\n'; }; github_confgen >/dev/null )
  tr '\0' '\n' < "$tmp/fingerprint"
}

# GitHub: only runners that bind the shared browser cache get the variable.
for mounts in '' 'npm:/home/runner/.npm' 'playwright:/home/runner/.cache/ms-playwright'; do
  CACHE_MOUNTS="$mounts"
  github_build_args 1 test-runner || fail "configuration rejected: '$mounts'"
  if grep -qFx -- "$gc_off" <<< "$(argv)"; then fail "runner without an ms-playwright mount got $gc_off: '$mounts'"; fi
  if grep -qF -- "$salt" <<< "$(github_fingerprint_input)"; then fail "unrelated slots received the drain salt: '$mounts'"; fi
done

for mounts in 'ms-playwright:/home/runner/.cache/ms-playwright' \
  'npm:/home/runner/.npm ms-playwright:/home/runner/.cache/ms-playwright yarn:/home/runner/.cache/yarn' \
  'ms-playwright:/opt/browsers'; do
  CACHE_MOUNTS="$mounts"
  github_build_args 1 test-runner || fail "configuration rejected: '$mounts'"
  [ "$(argv | grep -cFx -- "$gc_off")" = 1 ] || fail "missing or duplicate $gc_off: '$mounts'"
  # A host that already had the mount must still drain onto the variable, so
  # the fingerprint needs an explicit salt, not only the mount list.
  grep -qF -- "$salt" <<< "$(github_fingerprint_input)" || fail "ms-playwright slots carry no drain salt: '$mounts'"
done

# The other cache variables still coexist with the new one.
CACHE_MOUNTS='pnpm-store:/opt/store blob-cache:/opt/blobs ms-playwright:/home/runner/.cache/ms-playwright'
github_build_args 1 test-runner || fail 'combined cache mounts rejected'
for value in PNPM_CONFIG_STORE_DIR=/opt/store CI_BLOB_CACHE_DIR=/opt/blobs "$gc_off"; do
  [ "$(argv | grep -cFx -- "$value")" = 1 ] || fail "missing or duplicate $value"
done

# GitLab: the job environment carries the variable, and managers recreate.
# shellcheck disable=SC2034 # configuration consumed by sourced provider functions
{
  CI_PROVIDER=gitlab
  GITLAB_URL='https://gitlab.example.test'
  GITLAB_RUNNER_TOKEN='glrt-playwrighttest00000000000' # kingfisher:ignore synthetic token, not a credential
  GITLAB_RUNNER_IMAGE='gitlab/gitlab-runner:alpine'
  IMAGE_SOURCE=builtin; DIND=true
}
cfg="$CRF_CFGDIR/gitlab-runners/ci-runner-1/config.toml"
gitlab_environment() {
  python3 - "$cfg" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as fh:
    print("\n".join(tomllib.load(fh)["runners"][0]["environment"]))
PY
}
gitlab_fingerprint_input() {
  ( sha256sum() { cat > "$tmp/fingerprint"; printf 'stub  -\n'; }; gitlab_confgen >/dev/null )
  tr '\0' '\n' < "$tmp/fingerprint"
}

CACHE_MOUNTS='npm:/home/runner/.npm'
gitlab_write_config 1 ci-runner-1 || fail 'GitLab TOML without the browser cache failed'
[ "$(gitlab_environment)" = FF_NETWORK_PER_BUILD=1 ] || fail 'GitLab job environment changed without an ms-playwright mount'
if grep -qF -- "$salt" <<< "$(gitlab_fingerprint_input)"; then fail 'unrelated GitLab managers received the drain salt'; fi
before="$(gitlab_confgen)"

CACHE_MOUNTS='npm:/home/runner/.npm ms-playwright:/home/runner/.cache/ms-playwright'
gitlab_write_config 1 ci-runner-1 || fail 'GitLab TOML with the browser cache failed'
[ "$(gitlab_environment)" = "FF_NETWORK_PER_BUILD=1"$'\n'"$gc_off" ] || fail "GitLab jobs did not receive $gc_off"
grep -qF -- "$salt" <<< "$(gitlab_fingerprint_input)" || fail 'GitLab managers carry no drain salt'
[ "$(gitlab_confgen)" != "$before" ] || fail 'existing GitLab managers would not recreate'

printf 'playwright cache contracts passed.\n'
