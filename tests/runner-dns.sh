#!/usr/bin/env bash
# RUNNER_DNS contract: explicit runner resolvers reach docker run as ordered
# --dns arguments, change the config generation only when set, and are rejected
# when Docker or strict isolation could never use them.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/cache"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'RUNNER DNS FAIL: %s\n' "$*" >&2; exit 1; }

RUNNER_MODE=single RUNNER_POOLS='' RUNNER_LABELS=ci-build GH_SCOPE=org CI_PROVIDER=github
RUNNER_CPUS='' RUNNER_MEMORY=16g IMAGE_SOURCE=builtin IMAGE=''
CACHE_ROOT="$tmp/cache" CACHE_MOUNTS='' WORK_TMPFS_SIZE=1g
ACCESS_TOKEN='' NO_REGISTER=1 DIND=false SHARE_DOCKER_SOCK=false NETWORK_ISOLATION=strict
pool_base_refresh
validate_runner_mode || fail "$POOL_CONFIG_ERROR"

# Each --dns value, in argv order.
dns_args() {
  local i
  for ((i = 0; i < ${#ARGS[@]}; i++)); do
    [ "${ARGS[i]}" != --dns ] || printf '%s ' "${ARGS[i + 1]}"
  done
}

# Empty inherits host DNS: no argument and the pre-existing fingerprint.
RUNNER_DNS=''
github_validate_settings || fail 'empty RUNNER_DNS was rejected'
github_build_args 1 ci-runner-1 || fail 'argv without RUNNER_DNS failed'
[ -z "$(dns_args)" ] || fail 'empty RUNNER_DNS still passed --dns'
inherited_generation="$(github_confgen)"

RUNNER_DNS='1.1.1.1 8.8.8.8'
github_validate_settings || fail 'public resolvers were rejected under strict isolation'
github_build_args 1 ci-runner-1 || fail 'argv with RUNNER_DNS failed'
[ "$(dns_args)" = '1.1.1.1 8.8.8.8 ' ] || fail "resolvers did not reach docker run in order: $(dns_args)"
set_generation="$(github_confgen)"
[ "$set_generation" != "$inherited_generation" ] || fail 'setting RUNNER_DNS did not change the config generation'

# Whitespace is not configuration; order is, because Docker tries servers in order.
RUNNER_DNS='  1.1.1.1   8.8.8.8 '
[ "$(github_confgen)" = "$set_generation" ] || fail 'whitespace changed the config generation'
RUNNER_DNS='8.8.8.8 1.1.1.1'
[ "$(github_confgen)" != "$set_generation" ] || fail 'reordered resolvers kept the config generation'

for bad in '1.1.1.1 8.8.8.8 9.9.9.9 8.8.4.4' '1.1.1.1 1.1.1.1' 127.0.0.11 0.0.0.0 224.0.0.251 \
  255.255.255.255 256.1.1.1 01.1.1.1 1.1.1 dns.google '1.1.1.1;true' 2606:4700:4700::1111 \
  10.0.0.53 172.16.0.1 172.31.255.254 192.168.1.1 100.100.100.100; do
  RUNNER_DNS="$bad"
  github_validate_settings 2>/dev/null && fail "accepted RUNNER_DNS='$bad' under strict isolation"
  github_build_args 1 ci-runner-1 2>/dev/null && fail "built runner argv with RUNNER_DNS='$bad'"
done

# Only strict isolation blocks private and CGNAT resolvers.
for ok in 172.15.0.1 172.32.0.1 100.63.0.1 100.128.0.1 192.169.0.1; do
  RUNNER_DNS="$ok"
  github_validate_settings || fail "rejected public resolver $ok under strict isolation"
done
NETWORK_ISOLATION=isolate
for ok in 10.0.0.53 192.168.1.1 100.100.100.100; do
  RUNNER_DNS="$ok"
  github_validate_settings || fail "rejected reachable resolver $ok without strict isolation"
done
RUNNER_DNS=127.0.0.1
github_validate_settings 2>/dev/null && fail 'accepted a loopback resolver without strict isolation'

# A daemon reload honours the file: deleting the line opts out, as for the
# other config-file-only policies, instead of keeping the last loaded list.
NETWORK_ISOLATION=strict
printf 'RUNNER_DNS="1.1.1.1 8.8.8.8"\n' > "$CFG"
load_cfg
[ "$RUNNER_DNS" = '1.1.1.1 8.8.8.8' ] || fail "load_cfg did not read RUNNER_DNS: '$RUNNER_DNS'"
[ "$(github_confgen)" = "$set_generation" ] || fail 'a loaded list changed the config generation'
: > "$CFG"
load_cfg
[ -z "$RUNNER_DNS" ] || fail "a removed RUNNER_DNS line survived reload: '$RUNNER_DNS'"
[ "$(github_confgen)" = "$inherited_generation" ] || fail 'a removed RUNNER_DNS line kept its config generation'

echo "runner DNS ok"
