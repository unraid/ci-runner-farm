#!/usr/bin/env bash
# Shared fixed-name resources and strict firewall state must be removed only
# after positive ownership checks, and cleanup failures must propagate.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'RESOURCE OWNERSHIP FAIL: %s\n' "$*" >&2; exit 1; }

(
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/cfg" CRF_RUNDIR="$tmp/run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/cache"
  # shellcheck source=/dev/null
  source "$ENGINE"

  MIRROR_NAME=ci-runner-cache
  CACHE_ROOT="$tmp/cache"
  SHARED_IMAGE_CACHE=true
  DIND=true
  NETWORK_ISOLATION=off
  mirror_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mirror_exists=1
  mirror_owned=0
  mirror_legacy=0
  mutation_log="$tmp/mirror-mutations.log"
  : > "$mutation_log"

  docker() {
    local cmd="${1:-}" fmt="" target=""
    shift || true
    case "$cmd" in
      inspect)
        if [ "${1:-}" = -f ]; then
          fmt="$2"; target="$3"
          case "$fmt" in
            '{{.Id}}') [ "$mirror_exists" -eq 1 ] && printf '%s\n' "$mirror_id" || return 1 ;;
            '{{.Name}}') [ "$mirror_legacy" -eq 1 ] && printf '/%s\n' "$MIRROR_NAME" ;;
            '{{.Config.Image}}') [ "$mirror_legacy" -eq 1 ] && printf 'registry:2\n' ;;
            *'.Destination "/var/lib/registry"'*) [ "$mirror_legacy" -eq 1 ] && printf '%s\n' "$CACHE_ROOT/registry-mirror" ;;
            *'range .Config.Env'*) [ "$mirror_legacy" -eq 1 ] && printf 'REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io\n' ;;
            *ci-runner-farm.resource*) [ "$mirror_owned" -eq 1 ] && printf 'true\n' ;;
            *ci-runner-farm.role*) [ "$mirror_owned" -eq 1 ] && printf 'mirror\n' ;;
          esac
        else
          target="${1:-}"
          [ "$mirror_exists" -eq 1 ] && { [ "$target" = "$MIRROR_NAME" ] || [ "$target" = "$mirror_id" ]; }
        fi
        ;;
      rm)
        printf 'rm %s\n' "$*" >> "$mutation_log"
        [ "${*: -1}" = "$mirror_id" ] || return 1
        mirror_exists=0
        ;;
      ps) return 0 ;;
      *) return 0 ;;
    esac
  }

  if ensure_mirror >/dev/null 2>&1; then
    fail "shared mirror accepted an unowned fixed-name collision"
  fi
  [ ! -s "$mutation_log" ] || fail "unowned shared mirror was removed"

  mirror_legacy=1
  mirror_remove_owned || fail "upgrade-compatible legacy mirror was not recognized"
  grep -qx "rm -f $mirror_id" "$mutation_log" \
    || fail "legacy shared mirror was not removed by immutable ID"

  : > "$mutation_log"
  mirror_exists=1
  mirror_legacy=0
  mirror_owned=1
  mirror_remove_owned || fail "owned shared mirror removal failed"
  grep -qx "rm -f $mirror_id" "$mutation_log" \
    || fail "shared mirror was not removed by immutable ID"

  network_owned_flag=0
  docker() {
    case "$*" in
      'network inspect ci-runner-net') return 0 ;;
      *'index .Labels "net.unraid.ci-runner-farm"'*ci-runner-net) [ "$network_owned_flag" -eq 1 ] && printf '1\n' ;;
      'network create '*) printf 'network-create\n' >> "$mutation_log" ;;
      *) return 1 ;;
    esac
  }
  RUNNER_NETWORK=ci-runner-net
  NETWORK_ISOLATION=strict
  if ensure_network >/dev/null 2>&1; then
    fail "strict mode accepted an unowned network and could firewall foreign containers"
  fi
  if grep -q network-create "$mutation_log"; then
    fail "strict mode replaced an unowned network"
  fi
  NETWORK_ISOLATION=isolate
  ensure_network >/dev/null \
    || fail "isolate mode did not preserve an explicitly pre-existing network"

  iptables() {
    case "$*" in
      '-w -L DOCKER-USER --line-numbers -n') printf '7 DROP all -- anywhere anywhere /* %s:test */\n' "$FW_TAG" ;;
      '-w -L INPUT --line-numbers -n') return 0 ;;
      '-w -D DOCKER-USER 7') return 1 ;;
      *) return 0 ;;
    esac
  }
  if firewall_clear >/dev/null 2>&1; then
    fail "firewall cleanup hid a tagged-rule deletion failure"
  fi
)

grep -qF 'boot_autostart_stop || return 1' "$ENGINE" \
  || fail "Stop does not cancel the delayed boot worker before mutation"
grep -qF 'docker network rm "$network_id"' "$ENGINE" \
  || fail "owned runner network is not removed through its immutable ID"
grep -qF 'mirror_remove_owned || stop_failed=1' "$ENGINE" \
  || fail "Stop does not propagate shared-mirror cleanup failure"
grep -qF 'gitlab_assert_no_orphan_manager_configs || return 1' "$ENGINE" \
  || fail "Stop can discard a manually orphaned GitLab manager identity"
grep -qF 'cleanup_orphan_github_validations || return 1' "$ENGINE" \
  || fail "Stop can tear down shared resources before orphaned GitHub validation cleanup succeeds"

echo "resource-ownership: OK — shared resources and cleanup failures are ownership-gated"
