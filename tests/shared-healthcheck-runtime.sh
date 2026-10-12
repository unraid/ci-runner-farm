#!/usr/bin/env bash
# Run on a disposable Docker daemon, never inside a managed farm runner.
# shellcheck disable=SC2034 # configuration consumed by sourced provider functions
set -euo pipefail
cd "$(dirname "$0")/.."
command -v docker >/dev/null
docker info >/dev/null
tmp="$(mktemp -d)"
image="crf-healthcheck-test:$(date +%s)-$$"
ids=()
cleanup() {
  local id
  for id in "${ids[@]}"; do
    docker unpause "$id" >/dev/null 2>&1 || true
    docker rm -f "$id" >/dev/null 2>&1 || true
  done
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { printf 'SHARED HEALTHCHECK FAIL: %s\n' "$*" >&2; exit 1; }
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
docker build -q -t "$image" - <<'DOCKERFILE' >/dev/null
FROM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea
HEALTHCHECK --interval=1s --timeout=1s CMD ["true"]
CMD ["sleep", "300"]
DOCKERFILE
CI_PROVIDER=github CRF_POOL_ID=build NAME_PREFIX="crf-healthcheck-$$"
printf 'FIXTURE_VALUE=private-file\n' > "$tmp/runner.env"
chmod 600 "$tmp/runner.env"
ARGS=(-d --name "$NAME_PREFIX-1" --memory 64m --cpus 0.25 --label crf.test=healthcheck --env-file "$tmp/runner.env" "$image")
touch "$CFGDIR/shared-capacity.enabled"
shared_capacity_start() {
  [ "$1" = "$NAME_PREFIX-1" ] || fail 'gate lost slot identity'
  ids+=("$2")
  printf '%s' "$2" > "$tmp/created-id"
  [ "$(docker inspect --format '{{.State.Status}}' "$2")" = created ] || fail 'adapter started before admission'
  return 75
}
if run_owned_github_container 1; then fail 'queued admission reported success'; else [ "$?" = 75 ] || fail 'queue outcome lost'; fi
id="$(cat "$tmp/created-id")"
[ "$(docker inspect --format '{{json .Config.Healthcheck.Test}}' "$id")" = '["NONE"]' ] || fail 'shared create retained inherited exec probe'
[ "$(docker inspect --format '{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}|{{index .Config.Labels "crf.test"}}' "$id")" = '67108864|250000000|healthcheck' ] || fail 'hard limits or ownership labels changed'
# Exercise process inspection across native pause with no healthcheck exec.
docker start "$id" >/dev/null
docker pause "$id" >/dev/null
python3 - "$id" <<'PY'
import subprocess, sys
result = subprocess.run(["docker", "top", sys.argv[1], "-eo", "pid,comm"], timeout=10, check=True, capture_output=True, text=True)
assert "sleep" in result.stdout, result.stdout
PY
docker unpause "$id" >/dev/null
# Legacy creation still inherits the same image's healthcheck.
rm "$CFGDIR/shared-capacity.enabled"
shared_capacity_enabled() { return 1; }
ARGS=(-d --name "$NAME_PREFIX-2" "$image")
id="$(run_owned_github_container 2)"; ids+=("$id")
[ "$(docker inspect --format '{{json .Config.Healthcheck.Test}}' "$id")" = '["CMD","true"]' ] || fail 'legacy healthcheck changed'
echo 'shared-healthcheck-runtime: inherited probe disabled, native pause/top and legacy compatibility passed'
