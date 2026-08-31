#!/usr/bin/env bash
# Temporary files and option-like Docker image names must fail closed.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
GITHUB="src/usr/local/emhttp/plugins/ci-runner-farm/include/providers/github.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "temp-safety: $*" >&2; exit 1; }

run_rollover_mktemp_test() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/rollover-cfg" CRF_RUNDIR="$tmp/rollover-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"
  IMAGEUPDATE_PENDING="$CRF_RUNDIR/image-update.pending"

  mktemp() { return 1; }
  if imageupdate_rollover false >"$tmp/rollover.out" 2>&1; then
    fail "rollover succeeded after mktemp failed"
  fi
  grep -q 'cannot create rollover retry state' "$tmp/rollover.out" \
    || fail "rollover did not report its temporary-file failure"
  [ ! -e "$IMAGEUPDATE_PENDING" ] || fail "rollover created pending state after mktemp failed"
  unset -f mktemp
  ! grep -qF '.tmp.$$' "$ENGINE" \
    || fail "rollover still uses a predictable process-ID temporary filename"
)

run_github_mktemp_test() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/github-cfg" CRF_RUNDIR="$tmp/github-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"
  # The provider is normally sourced by the engine; source it explicitly so
  # this test remains clear if provider loading becomes configurable.
  # shellcheck source=/dev/null
  source "$GITHUB"
  check_cache_root() { return 0; }
  ensure_dirs() { return 0; }
  registry_login() { return 0; }
  github_build_args() { ARGS=(validation-image); }
  docker() { fail "docker was called after validation mktemp failed"; }

  mktemp() { return 1; }
  if github_validate >"$tmp/github.out" 2>&1; then
    fail "GitHub validation succeeded after mktemp failed"
  fi
  grep -q 'could not create a temp file for docker run output' "$tmp/github.out" \
    || fail "GitHub validation did not report its temporary-file failure"
)

run_docker_option_separator_test() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/pull-cfg" CRF_RUNDIR="$tmp/pull-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"
  HOST_DOCKER_CONFIG="$tmp/docker-config"
  docker_log="$tmp/docker-pull.log"
  docker() { printf '%s\n' "$*" > "$docker_log"; }

  host_docker_pull '--image-looking-like-an-option'
  [ "$(cat "$docker_log")" = "--config $HOST_DOCKER_CONFIG pull -- --image-looking-like-an-option" ] \
    || fail "host Docker pull did not terminate options before the image name"
)

run_rollover_mktemp_test
run_github_mktemp_test
run_docker_option_separator_test
echo "temp-safety: PASS"
