#!/usr/bin/env bash
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

fail() { printf 'recommendation-history-integration: FAIL: %s\n' "$*" >&2; exit 1; }

managed_names() { printf 'ci-runner-1\n'; }
container_provider() { printf 'github\n'; }
github_usage_stat_target() { printf '%s\n' "$1"; }
runner_state() { printf 'idle\n'; }
cache_root_problem() { :; }
public_repo_problem() { :; }
docker() {
  [ "${1:-}" = stats ] || return 0
  printf 'ci-runner-1|25.0%%|512MiB / 8GiB\n'
}

now="$(date +%s)"
job64="$(_b64 'JS lint')"
printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
  ci-runner-1 20 300 busy "$job64" "$((now - 10))" github _ _ _ _ _ _ _ _ _ \
  > "$CRF_RUNDIR/usage.cache"

cmd_usage_refresh

stats="$(crf_history_stats github 'JS lint')"
IFS='|' read -r _ samples _ average min max _ <<< "$stats"
[ "$samples" = 1 ] || fail "usage-refresh did not record completed job"
[ "$average" -ge 10 ] && [ "$average" -le 30 ] && [ "$min" = "$average" ] && [ "$max" = "$average" ] \
  || fail "usage-refresh recorded wrong completion duration: $stats"

read -r _ _ _ phase _ _ _ _ _ _ _ _ _ _ _ _ < "$CRF_RUNDIR/usage.cache"
[ "$phase" = idle ] || fail "usage-refresh did not publish current idle state"

# Exercise daemon start/stop command construction without spawning a real worker.
history_log="$tmp/history-start.log"
nohup() { printf '%s\n' "$*" >> "$history_log"; }
recommendation_history_stop() { :; }
recommendation_history_start
[ -s "$HISTORY_PID" ] || fail 'history start did not publish PID file'
grep -q 'history-daemon' "$history_log" || fail 'history start did not launch history-daemon'

stop_log="$tmp/history-stop.log"
stop_worker_group() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$stop_log"; }
recommendation_history_stop() { stop_worker_group "recommendation history" "$HISTORY_PID" '[r]unner-farm.sh history-daemon'; }
recommendation_history_stop
grep -q '^recommendation history|' "$stop_log" || fail 'history stop did not use worker-group cleanup'

# Stop paths must stop history before touching fleet state.
stop_calls="$tmp/stop-calls.log"
boot_autostart_stop() { printf 'boot\n' >> "$stop_calls"; }
recommendation_history_stop() { printf 'history\n' >> "$stop_calls"; return 1; }
managed_names() { fail 'stop path reached fleet state after history stop failed'; }
cmd_stop >/dev/null 2>&1 || true
grep -qx 'history' "$stop_calls" || fail 'cmd_stop did not stop history daemon first'

echo "recommendation-history-integration: OK"

# Exercise the real wait/trap boundary: native stop allows only two seconds.
worker="$tmp/history-worker.sh"
cat > "$worker" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" != usage-refresh ] || exit 0
source "$HISTORY_SOURCE"
load_cfg() { :; }
reload_secret_files() { :; }
log() { :; }
recommendation_history_daemon
WORKER
chmod +x "$worker"
export HISTORY_SOURCE="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
"$worker" &
worker_pid=$!
sleeper_pid=""
for _ in $(seq 1 20); do
  sleeper_pid="$(ps -ax -o pid=,ppid=,comm= | awk -v parent="$worker_pid" '$2==parent && $3 ~ /(^|\/)sleep$/ {print $1}')"
  [ -z "$sleeper_pid" ] || break
  sleep 0.05
done
[ -n "$sleeper_pid" ] || fail 'history worker did not enter the real sleep boundary'
kill -TERM "$worker_pid"
for _ in $(seq 1 20); do
  kill -0 "$worker_pid" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$worker_pid" 2>/dev/null; then
  kill -TERM "$sleeper_pid" 2>/dev/null || true
  wait "$worker_pid" || true
  fail 'history TERM waited for the thirty-second sleep'
fi
wait "$worker_pid"
! kill -0 "$sleeper_pid" 2>/dev/null || fail 'history TERM left its sleep child running'
echo 'recommendation-history-shutdown: OK'
