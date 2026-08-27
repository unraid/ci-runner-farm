#!/usr/bin/env bash
# Build-poison self-heal: the GitHub scan must flag exactly the slots whose
# failed jobs carry a supported corruption signature, download each job log at most
# once, and the healer must repair only an idle, still-current flagged slot —
# stop, clear ONLY buildkit/ from its DinD root, restart — bounded to one
# attempt per slot per interval, never touching a busy slot.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config"
export CRF_RUNDIR="$tmp/run"
export CRF_SOURCE_ONLY=1
export CRF_POISON_SCAN_INTERVAL=0
export CRF_POISON_SCAN_LOOKBACK=1800
export CRF_POISON_HEAL_MIN_INTERVAL=3600
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'LEASE SELFHEAL FAIL: %s\n' "$*" >&2; exit 1; }

# ── Fixtures ─────────────────────────────────────────────────────────────────
ACCESS_TOKEN='github_pat_selfheal_secret'
GH_REPOS='example/one'
DIND=true
CACHE_ROOT="$tmp/cache"
RID2="$(printf '2%.0s' $(seq 64))"
RID3="$(printf '3%.0s' $(seq 64))"
host() { printf 'mockhost\n'; }
# The cache-root guard has its own dedicated coverage in safe-paths.sh; here it
# must resolve to the sandbox so the heal's rm -rf can be observed for real.
crf_safe_cache_root() { printf '%s' "$CACHE_ROOT"; }

# Runner slot 2 (poisoned) and slot 3 (healthy) exist and are idle by default.
CRF_TEST_BUSY=0
DOCKER_LOG="$tmp/docker.log"; : > "$DOCKER_LOG"
docker() {
  printf 'docker %s\n' "$*" >> "$DOCKER_LOG"
  local last="${*: -1}"
  case "$1" in
    inspect)
      local fmt="$3"
      case "$last" in
        ci-runner-2|"$RID2") slot=2; rid="$RID2" ;;
        ci-runner-3|"$RID3") slot=3; rid="$RID3" ;;
        *) return 1 ;;
      esac
      case "$fmt" in
        *'.Id}}'*) printf '%s|true|github|runner|%s|gen123|/ci-runner-%s\n' "$rid" "$slot" "$slot" ;;
        *provider*) printf 'github\n' ;;
        *'.State.Status'*) printf 'running\n' ;;
        *) printf '\n' ;;
      esac ;;
    exec)
      [ "$CRF_TEST_BUSY" = 1 ] && printf 'busy\n' || printf 'idle\n' ;;
    logs) printf 'Listening for Jobs\n' ;;
    stop|start) return 0 ;;
    *) return 0 ;;
  esac
}

# One failed run (900001) whose jobs: 700001 failed on mockhost-ci-runner-2
# with the dangling-lease signature, 700002 failed on a GitHub-hosted runner,
# 700003 SUCCEEDED on mockhost-ci-runner-3 with a step whose nested conclusion
# is "failure", and 700004 failed on mockhost-ci-runner-3 with a missing
# BuildKit snapshot parent. The parser must keep the job-level conclusion, not
# a step's.
GH_API_LOG="$tmp/gh-api.log"; : > "$GH_API_LOG"
gh_api() {
  printf '%s %s\n' "$1" "$2" >> "$GH_API_LOG"
  case "$2" in
    /repos/example/one/actions/runs\?status=failure*)
      cat <<'EOF'
{
  "total_count": 1,
  "workflow_runs": [
    {
      "id": 900001,
      "name": "CI",
      "check_suite_id": 111222333,
      "head_branch": "feat/x",
      "repository": {
        "id": 4242,
        "name": "one"
      }
    }
  ]
}
EOF
      ;;
    /repos/example/one/actions/runs/900001/jobs*)
      cat <<'EOF'
{
  "total_count": 4,
  "jobs": [
    {
      "id": 700001,
      "run_id": 900001,
      "status": "completed",
      "conclusion": "failure",
      "steps": [
        {
          "name": "build",
          "conclusion": "failure"
        }
      ],
      "runner_id": 11,
      "runner_name": "mockhost-ci-runner-2"
    },
    {
      "id": 700002,
      "run_id": 900001,
      "status": "completed",
      "conclusion": "failure",
      "steps": [],
      "runner_id": 12,
      "runner_name": "GitHub Actions 42"
    },
    {
      "id": 700003,
      "run_id": 900001,
      "status": "completed",
      "conclusion": "success",
      "steps": [
        {
          "name": "flaky step that was retried",
          "conclusion": "failure"
        }
      ],
      "runner_id": 13,
      "runner_name": "mockhost-ci-runner-3"
    },
    {
      "id": 700004,
      "run_id": 900001,
      "status": "completed",
      "conclusion": "failure",
      "steps": [],
      "runner_id": 13,
      "runner_name": "mockhost-ci-runner-3"
    }
  ]
}
EOF
      ;;
    *) return 1 ;;
  esac
}

# Job-log transport: jobs 700001 and 700004 carry supported poison signatures.
CURL_LOG="$tmp/curl.log"; : > "$CURL_LOG"
curl() {
  printf '%s\n' "$*" >> "$CURL_LOG"
  cat >/dev/null   # consume the stdin curl config carrying the PAT
  case "$*" in
    */jobs/700001/logs*)
      printf '2026-08-16T20:57:43.6390511Z #13 ERROR: lease "idf11ya2iiot5bqwvr7qojagq": not found\n'
      printf '2026-08-16T20:57:43.6402537Z ERROR: failed to build: failed to solve: lease "idf11ya2iiot5bqwvr7qojagq": not found\n' ;;
    */jobs/700004/logs*)
      printf 'ERROR: failed to prepare sha256:25cd as abc: failed to stat parent: stat /var/lib/buildkit/runc-overlayfs/snapshots/snapshots/562/fs: no such file or directory\n' ;;
    *) printf 'ordinary failing job log without the signature\n' ;;
  esac
}

# ── Detection ────────────────────────────────────────────────────────────────
github_build_poison_scan || fail "scan returned non-zero on the fixture"
[ -f "$CRF_RUNDIR/poison-pending.ci-runner-2" ] || fail "signature job did not flag ci-runner-2"
[ "$(cat "$CRF_RUNDIR/poison-pending.ci-runner-2")" = "$RID2" ] \
  || fail "poison flag does not carry the slot's immutable container ID"
[ -f "$CRF_RUNDIR/poison-pending.ci-runner-3" ] \
  || fail "missing-snapshot job did not flag ci-runner-3"
[ "$(cat "$CRF_RUNDIR/poison-pending.ci-runner-3")" = "$RID3" ] \
  || fail "snapshot-corruption flag does not carry ci-runner-3's immutable container ID"
grep -qx 700001 "$CRF_RUNDIR/poison-scan.seen" || fail "seen cache is missing the scanned job"
grep -qx 700004 "$CRF_RUNDIR/poison-scan.seen" || fail "seen cache is missing the snapshot-corruption job"
if grep -q 700003 "$CURL_LOG"; then fail "log of a succeeded job was downloaded"; fi
if grep -qF "$ACCESS_TOKEN" "$CURL_LOG"; then fail "PAT leaked into the log-download curl argv"; fi
logs_before="$(grep -c 'jobs/70000' "$CURL_LOG" || true)"
POISON_SCAN_INTERVAL=0 github_build_poison_scan || fail "rescan returned non-zero"
logs_after="$(grep -c 'jobs/70000' "$CURL_LOG" || true)"
[ "$logs_before" = "$logs_after" ] || fail "a rescan re-downloaded an already-seen job log"
rm -f "$CRF_RUNDIR/poison-pending.ci-runner-3"

# ── Heal defers while the slot is busy ───────────────────────────────────────
POISON_SCAN_INTERVAL=99999   # keep the embedded scan quiet during heal phases
mkdir -p "$CACHE_ROOT/docker/ci-runner-2/buildkit" "$CACHE_ROOT/docker/ci-runner-2/image" \
         "$CACHE_ROOT/docker/ci-runner-2/overlay2"
touch "$CACHE_ROOT/docker/ci-runner-2/buildkit/metadata_v2.db"
CRF_TEST_BUSY=1
heal_poisoned_runners || fail "heal returned non-zero while deferring a busy slot"
[ -f "$CRF_RUNDIR/poison-pending.ci-runner-2" ] || fail "busy slot lost its poison flag"
if grep -q "docker stop" "$DOCKER_LOG"; then fail "healer stopped a busy slot"; fi
[ -d "$CACHE_ROOT/docker/ci-runner-2/buildkit" ] || fail "busy slot's buildkit store was cleared"

# ── Heal repairs the idle slot: stop, clear only buildkit/, start ────────────
CRF_TEST_BUSY=0
heal_poisoned_runners || fail "heal returned non-zero repairing an idle slot"
grep -q "docker stop.*$RID2" "$DOCKER_LOG" || fail "healer did not stop the poisoned container by immutable ID"
grep -q "docker start $RID2" "$DOCKER_LOG" || fail "healer did not restart the poisoned container"
[ ! -d "$CACHE_ROOT/docker/ci-runner-2/buildkit" ] || fail "buildkit store survived the heal"
[ -d "$CACHE_ROOT/docker/ci-runner-2/image" ] || fail "heal deleted the warm image cache"
[ -d "$CACHE_ROOT/docker/ci-runner-2/overlay2" ] || fail "heal deleted the layer store"
[ ! -e "$CRF_RUNDIR/poison-pending.ci-runner-2" ] || fail "healed slot kept its poison flag"
[ -f "$CRF_RUNDIR/poison-healed.ci-runner-2" ] || fail "heal did not stamp its attempt"

# ── The per-slot bound blocks an immediate second reset ──────────────────────
echo "$RID2" > "$CRF_RUNDIR/poison-pending.ci-runner-2"
stops_before="$(grep -c 'docker stop' "$DOCKER_LOG" || true)"
heal_poisoned_runners || fail "heal returned non-zero while enforcing the per-slot bound"
stops_after="$(grep -c 'docker stop' "$DOCKER_LOG" || true)"
[ "$stops_before" = "$stops_after" ] || fail "per-slot bound did not prevent a second stop within the interval"
[ -f "$CRF_RUNDIR/poison-pending.ci-runner-2" ] || fail "bounded slot lost its poison flag"
rm -f "$CRF_RUNDIR/poison-pending.ci-runner-2"

# ── A flag for a replaced container is discarded untouched ───────────────────
echo "$(printf '9%.0s' $(seq 64))" > "$CRF_RUNDIR/poison-pending.ci-runner-3"
stops_before="$(grep -c 'docker stop' "$DOCKER_LOG" || true)"
heal_poisoned_runners || fail "heal returned non-zero discarding a stale flag"
stops_after="$(grep -c 'docker stop' "$DOCKER_LOG" || true)"
[ "$stops_before" = "$stops_after" ] || fail "healer stopped a container whose flag no longer matches it"
[ ! -e "$CRF_RUNDIR/poison-pending.ci-runner-3" ] || fail "stale flag for a replaced container survived"

echo "lease-selfheal checks passed"
