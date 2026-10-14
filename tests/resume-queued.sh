#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
logfile="$tmp/calls"; : > "$logfile"
shared_capacity_require_starts_open() { return 0; }
shared_capacity_enabled() { return 0; }
validate_runner_mode() { return 0; }
QUEUED_POOLS=true; CI_PROVIDER=github
test_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
managed_runner_snapshot() { printf '%s|github|runner|1|old\n' "$test_id"; }
runner_pool() { printf 'build-small\n'; }
pool_activate() { printf 'pool %s\n' "$1" >> "$logfile"; }
crf_confgen() { printf 'new\n'; }
test_state=created
docker() { printf '%s\n' "$test_state"; }
shared_capacity_call() { printf 'native %s\n' "$*" >> "$logfile"; }
provider_call() { printf 'provider %s\n' "$*" >> "$logfile"; }
shared_capacity_start() { printf 'start %s\n' "$*" >> "$logfile"; }
provision_base() { printf 'provision\n' >> "$logfile"; }
firewall_prepare_replacement() { printf 'firewall\n' >> "$logfile"; }
cmd_resume_queued ci-runner-build-small-1
expected="$(printf 'pool build-small\nprovision\nfirewall\nnative refresh-queued ci-runner-build-small-1 %s\nprovider start_one 1 ci-runner-build-small-1' "$test_id")"
[ "$(cat "$logfile")" = "$expected" ] || { echo 'queued replacement bypasses network preparation' >&2; exit 1; }
grep -qx "native refresh-queued ci-runner-build-small-1 $test_id" "$logfile"
grep -qx 'provider start_one 1 ci-runner-build-small-1' "$logfile"
for test_state in running exited paused unknown; do
 : > "$logfile"
 if cmd_resume_queued ci-runner-build-small-1; then echo "resumed unsafe state $test_state" >&2; exit 1; fi
 [ ! -s "$logfile" ]
done
test_state=created; crf_confgen() { printf 'old\n'; }; : > "$logfile"
cmd_resume_queued ci-runner-build-small-1
grep -qx "start ci-runner-build-small-1 $test_id" "$logfile"
if grep -q '^native refresh' "$logfile"; then exit 1; fi
crf_confgen() { printf 'new\n'; }
for failure in provision firewall; do
 : > "$logfile"
 provision_base() { [ "$failure" != provision ]; }
 firewall_prepare_replacement() { [ "$failure" != firewall ]; }
 if cmd_resume_queued ci-runner-build-small-1; then exit 1; fi
 if grep -qE '^(native|provider) ' "$logfile"; then exit 1; fi
done
provision_base() { return 0; }; firewall_prepare_replacement() { return 0; }
shared_capacity_call() { return 1; }; crf_confgen() { printf 'new\n'; }; : > "$logfile"
if cmd_resume_queued ci-runner-build-small-1; then exit 1; fi
if grep -q '^provider ' "$logfile"; then exit 1; fi
printf 'resume queued exact native owner and no unsafe state PASS\n'
