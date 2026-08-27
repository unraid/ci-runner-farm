#!/usr/bin/env bash
# Run the real Stop/removal policy against disposable on-disk cache fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "CACHE RETENTION FAIL: $*" >&2; exit 1; }

for provider in github gitlab; do
  (
    fixture_provider="$provider"
    export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/$provider/config" CRF_RUNDIR="$tmp/$provider/run"
    mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
    # shellcheck source=/dev/null
    source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
    CI_PROVIDER="$provider"
    CACHE_ROOT="$tmp/$provider/cache"
    NETWORK_ISOLATION=off
    CACHE_MOUNTS=''
    NO_REGISTER=1
    slot=ci-runner-1
    fixture_id=$(printf '%064d' 1)
    present="$tmp/$provider/present"
    effects="$tmp/$provider/effects"
    touch "$present" "$effects"
    for dir in docker gitlab-cache registry-mirror; do
      mkdir -p "$CACHE_ROOT/$dir/$slot"
      printf 'retained\n' > "$CACHE_ROOT/$dir/$slot/proof"
    done

    # Replace external Docker/API/process boundaries, not Stop, remove_runner,
    # the provider removal adapters, or their cache retention decisions.
    crf_safe_cache_root() { printf '%s\n' "$CACHE_ROOT"; }
    boot_autostart_stop() { return 0; }
    autoscale_stop() { return 0; }
    imageupdate_stop() { return 0; }
    reconcile_stop() { return 0; }
    quiesce_gitlab_managers_for_stop() { return 0; }
    managed_names() { if [ -e "$present" ]; then echo "$slot"; fi; }
    managed_runner_snapshot() { printf '%s|%s|runner|1|generation\n' "$fixture_id" "$fixture_provider"; }
    provider_stop_container() { printf 'stopped %s\n' "$CRF_REMOVE_ID" >> "$effects"; }
    provider_remove_container() { rm "$present"; }
    provider_stop_remove_container() { provider_stop_container "$1" && provider_remove_container "$1"; }
    github_deregister_runner_api() { printf 'unregistered\n' >> "$effects"; }
    gitlab_unregister_manager() { printf 'unregistered\n' >> "$effects"; }
    gitlab_running_executor_containers() { return 0; }
    gitlab_remove_host_jobs() { return 0; }
    gitlab_scrub_retired_slot_credentials() { printf 'credentials scrubbed\n' >> "$effects"; }
    gitlab_assert_no_orphan_manager_configs() { return 0; }
    gitlab_cleanup_orphan_sidecars() { return 0; }
    cleanup_orphan_github_validations() { return 0; }
    firewall_clear() { printf 'firewall cleared\n' >> "$effects"; }
    docker() {
      case "$1" in
        inspect) return 1 ;;
        ps)
          if [ -e "$present" ] && [[ "$*" = *'label=net.unraid.ci-runner-farm.managed=true'* ]]; then
            echo "$slot"
          fi ;;
        *) return 1 ;;
      esac
    }

    cmd_stop >/dev/null || fail "$provider Stop failed"
    [ ! -e "$present" ] || fail "$provider container survived Stop"
    grep -qx 'unregistered' "$effects" || fail "$provider registration was not removed"
    [ -f "$CACHE_ROOT/docker/$slot/proof" ] || fail "$provider Stop deleted Docker data"
    [ -f "$CACHE_ROOT/gitlab-cache/$slot/proof" ] || fail "$provider Stop deleted job cache"
    [ -f "$CACHE_ROOT/registry-mirror/$slot/proof" ] || fail "$provider Stop deleted mirror data"
    if [ "$provider" = gitlab ]; then
      grep -qx 'credentials scrubbed' "$effects" || fail 'retention skipped credential cleanup'
    fi

    # Restart uses the real Stop path before reloading and starting the fleet.
    touch "$present"
    reload_locked_snapshot() { return 0; }
    cmd_start() {
      [ ! -e "$present" ] || fail 'Restart did not stop the old container'
      [ -f "$CACHE_ROOT/docker/$slot/proof" ] || fail 'Restart lost Docker data before Start'
      [ -f "$CACHE_ROOT/gitlab-cache/$slot/proof" ] || fail 'Restart lost job cache before Start'
      touch "$present"
    }
    cmd_restart >/dev/null || fail "$provider Restart failed"
    [ -e "$present" ] || fail "$provider Restart did not start a replacement"

    # Creation maps the retained slot directory, not a fresh per-container path.
    (
      DIND=true
      BUILD_CACHE_MODE=off
      host() { echo fixture; }
      runner_host_service_ipv4() { echo 192.0.2.10; }
      if [ "$fixture_provider" = github ]; then
        github_build_args 1
        printf '%s\n' "${ARGS[@]}" | grep -qxF "$CACHE_ROOT/docker/$slot:/var/lib/docker"
      else
        GITLAB_RUNNER_TOKEN=glrt-fixture-only
        gitlab_write_config 1 "$slot"
        grep -qF "$CACHE_ROOT/gitlab-cache/$slot:/cache" "$CFGDIR/gitlab-runners/$slot/config.toml"
        docker() {
          case "$1" in
            inspect) return 1 ;;
            run) printf '%s\n' "$@" > "$tmp/sidecar.args" ;;
            --host) return 0 ;;
            *) return 1 ;;
          esac
        }
        gitlab_start_sidecar 1 "$slot"
        grep -qxF "$CACHE_ROOT/docker/$slot:/var/lib/docker" "$tmp/sidecar.args"
      fi
      [ -f "$CACHE_ROOT/docker/$slot/proof" ] || fail 'creation overwrote retained data'
    )

    # Explicit prune must still refuse a live/retained manager.
    if cmd_prune_cache >/dev/null 2>&1; then fail 'prune accepted an existing manager'; fi
    [ -f "$CACHE_ROOT/docker/$slot/proof" ] || fail 'refused prune deleted Docker data'

    # Failed removal cannot clear shared isolation or allow Restart to start.
    (
      provider_remove_container() { return 1; }
      firewall_clear() { fail 'failed Stop cleared the firewall'; }
      cmd_start() { fail 'failed Stop allowed Restart to start'; }
      if cmd_restart >/dev/null 2>&1; then fail 'Restart accepted failed removal'; fi
      [ -f "$CACHE_ROOT/docker/$slot/proof" ] || fail 'failed Stop deleted Docker data'
    )

    # Permanent slot retirement still opts into deletion, independent of Stop.
    touch "$present"
    remove_runner "$slot" true >/dev/null || fail "$provider permanent removal failed"
    [ ! -e "$CACHE_ROOT/docker/$slot" ] || fail "$provider permanent removal retained Docker data"
    [ -f "$CACHE_ROOT/registry-mirror/$slot/proof" ] || fail 'slot retirement deleted shared mirror data'

    # The existing explicit prune removes retained data only after Stop.
    mkdir -p "$CACHE_ROOT/docker/$slot"
    touch "$CACHE_ROOT/docker/$slot/proof"
    cmd_prune_cache >/dev/null || fail 'explicit prune failed'
    [ ! -e "$CACHE_ROOT/docker" ] || fail 'explicit prune did not remove retained Docker data'
    [ ! -e "$CACHE_ROOT/registry-mirror" ] || fail 'explicit prune did not remove mirror data'
  )
done

echo 'cache-retention: Stop/Restart preserve both providers; explicit retirement/prune delete caches'
