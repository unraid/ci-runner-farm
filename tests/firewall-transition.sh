#!/usr/bin/env bash
# Mock the strict-network endpoint handoff used during provider/config drains.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'FIREWALL TRANSITION FAIL: %s\n' "$*" >&2; exit 1; }
CI_PROVIDER=gitlab
GITLAB_URL='https://new-gitlab.example.test:8443/gitlab'
IMAGE_SOURCE=remote
REGISTRY_SERVER='registry.example.test:5001'
NETWORK_ISOLATION=strict
RUNNER_NETWORK='ci-runner-net'
SHARED_IMAGE_CACHE=true
DIND=true
IPTABLES_LOG="$tmp/iptables.log"; export IPTABLES_LOG

runner_host_service_ipv4() { printf '157.180.7.27\n'; }

getent() {
  local host="${3:-${2:-}}"
  case "$host" in
    new-gitlab.example.test) printf '10.20.30.40 STREAM host\n' ;;
    registry.example.test)   printf '10.20.30.50 STREAM host\n' ;;
  esac
}

docker() {
  if [ "${1:-}" = network ] && [ "${2:-}" = inspect ]; then
    case "$*" in
      *Subnet*) printf '172.31.0.0/16\n' ;;
      *Gateway*) printf '172.31.0.1\n' ;;
    esac
    return 0
  fi
  if [ "${1:-}" = inspect ]; then
    case "$*" in *IPAddress*) printf '172.31.0.2\n' ;; esac
    return 0
  fi
  return 0
}

iptables() {
  printf '%s\n' "$*" >> "$IPTABLES_LOG"
  case "$*" in
    *'-L DOCKER-USER --line-numbers'*)
      printf '1 old allow /* ci-runner-farm:gitlab */\n2 old allow /* ci-runner-farm:registry */\n' ;;
    *'-L INPUT --line-numbers'*)
      printf '1 old allow /* ci-runner-farm:in-gitlab */\n' ;;
    *'-L DOCKER-USER -n'*)
      # A healthy existing base policy on the PREVIOUS subnet/mirror.  A
      # network/subnet change must not clear it while busy stale slots drain.
      printf 'RETURN 172.30.0.0/16 172.30.0.2 tcp dpt:5000 /* ci-runner-farm:mirror */\n'
      printf 'DROP 172.30.0.0/16 10.0.0.0/8 /* ci-runner-farm:lan10 */\n' ;;
    *' -C '*) return 1 ;;
  esac
  return 0
}

# The pre-replacement phase is additive: install current endpoint exceptions
# ahead of the LAN drops without deleting old exceptions still used by busy slots.
firewall_prepare_replacement
if grep -Eq ' -D (DOCKER-USER|INPUT) [0-9]+$' "$IPTABLES_LOG"; then
  fail "additive handoff deleted an old tagged rule"
fi
grep -q -- '-I DOCKER-USER 1 -s 172.31.0.0/16 -j DROP .*ci-runner-farm:install-guard' "$IPTABLES_LOG" \
  || fail "additive handoff did not install its temporary fail-closed guard first"
grep -q -- '-D DOCKER-USER -s 172.31.0.0/16 -j DROP .*ci-runner-farm:install-guard' "$IPTABLES_LOG" \
  || fail "successful additive handoff did not retire its temporary guard"
grep -q -- '-d 10.20.30.40 -p tcp --dport 8443' "$IPTABLES_LOG" \
  || fail "new GitLab endpoint was not allowed"
grep -q -- '-d 10.20.30.50 -p tcp --dport 5001' "$IPTABLES_LOG" \
  || fail "new registry endpoint was not allowed"
grep -q -- '-I INPUT 1' "$IPTABLES_LOG" || fail "host-input endpoint exception was not added"
grep -q -- '-I DOCKER-USER 1 -s 172.31.0.0/16 -d 192.168.0.0/16 -j DROP' "$IPTABLES_LOG" \
  || fail "complete policy for the replacement subnet was not added"
grep -q -- '-I INPUT 1 -s 172.31.0.0/16 -j DROP' "$IPTABLES_LOG" \
  || fail "replacement subnet did not receive a host-input drop"
grep -q -- '-s 172.31.0.0/16 -d 172.31.0.2 -p tcp --dport 5000' "$IPTABLES_LOG" \
  || fail "replacement subnet did not receive its mirror allow"
grep -q -- '-s 172.31.0.0/16 -d 157.180.7.27 -p tcp --dport 22' "$IPTABLES_LOG" \
  || fail "replacement subnet did not receive its local QA VM MCP allow"
grep -q -- '-I INPUT 1 -s 172.31.0.0/16 -d 157.180.7.27 -p tcp --dport 22' "$IPTABLES_LOG" \
  || fail "replacement subnet did not receive its local QA VM host-input allow"

# A GitLab job/service can override a locally built default image. Keep the one
# configured private-registry exception in that mode, while preserving GitHub's
# historical remote-default-only behavior.
IMAGE_SOURCE=builtin
gitlab_builtin_endpoints="$(configured_strict_endpoints)"
printf '%s\n' "$gitlab_builtin_endpoints" | grep -q '^10\.20\.30\.50 5001 registry$' \
  || fail "built-in-default GitLab policy omitted the configured override registry"
CI_PROVIDER=github
if configured_strict_endpoints | grep -q ' registry$'; then
  fail "built-in GitHub policy unexpectedly enabled a registry exception"
fi
CI_PROVIDER=gitlab
IMAGE_SOURCE=remote

# Start must select the same additive path when managed runners already exist.
# Mock every later lifecycle step so this checks only the preflight decision.
: > "$IPTABLES_LOG"
managed_names() { printf 'ci-runner-1\n'; }
managed_runner_snapshot() {
  printf '%064d|gitlab|manager|1|mock-generation\n' 1
}
provider_token_ready() { return 0; }
gitlab_validate_settings() { return 0; }
public_repo_problem() { return 0; }
provision_base() { printf 'base\n' >> "$IPTABLES_LOG"; }
provision_preflight() { fail "existing strict fleet used destructive preflight"; }
firewall_prepare_replacement() { printf 'additive\n' >> "$IPTABLES_LOG"; }
gitlab_cleanup_orphan_sidecars() { return 0; }
on_expected_network() { return 0; }
start_stopped_managed() { return 0; }
reap_dead_runners() { return 0; }
start_one() { return 0; }
AUTOSCALE=false IMAGE_AUTOUPDATE=false RUNNER_COUNT=1
cmd_start >/dev/null
[ "$(sed -n '1p' "$IPTABLES_LOG")" = base ] || fail "Start skipped shared base provisioning"
[ "$(sed -n '2p' "$IPTABLES_LOG")" = additive ] || fail "Start skipped additive strict policy preparation"

# Even when a replacement is now current, firewall_apply must remain additive
# while any manager is live. It may retire only the temporary exact guard, never
# an old tagged rule still protecting a stale endpoint/subnet.
: > "$IPTABLES_LOG"
firewall_apply
if grep -Eq ' -D (DOCKER-USER|INPUT) [0-9]+$' "$IPTABLES_LOG"; then
  fail "live-fleet firewall finalization deleted tagged rules"
fi
grep -q -- '-I DOCKER-USER 1' "$IPTABLES_LOG" \
  || fail "live-fleet firewall finalization was not additive"

# Only a positively empty managed fleet permits the authoritative clear/rebuild.
: > "$IPTABLES_LOG"
managed_names() { :; }
firewall_apply
grep -q ' -D DOCKER-USER ' "$IPTABLES_LOG" || fail "authoritative rebuild did not remove old forward rules"
grep -q ' -D INPUT ' "$IPTABLES_LOG" || fail "authoritative rebuild did not remove old input rules"
grep -q -- '-d 10.20.30.40 -p tcp --dport 8443' "$IPTABLES_LOG" \
  || fail "authoritative rebuild omitted current GitLab endpoint"
grep -q -- '-d 157.180.7.27 -p tcp --dport 22' "$IPTABLES_LOG" \
  || fail "authoritative rebuild omitted the local QA VM MCP endpoint"

echo 'firewall-transition: OK — current endpoints are added before old exceptions are retired'
