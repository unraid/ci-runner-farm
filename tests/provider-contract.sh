#!/usr/bin/env bash
# Stable, public provider contract checks. These intentionally avoid private
# helper names so the provider adapters can be refactored without rewriting the
# test. Runtime behavior belongs in focused mocked tests next to those adapters.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="src/usr/local/emhttp/plugins/ci-runner-farm"
CFG="$RUNTIME/default.cfg"
ENGINE="$RUNTIME/include/runner-farm.sh"
UI="$RUNTIME/RunnerFarmSettings.page"
IMAGE_UI="$RUNTIME/RunnerFarmImage.page"
EXEC="$RUNTIME/include/exec.php"
CORE="$RUNTIME/include/crf-core.php"
GITHUB_ADAPTER="$RUNTIME/include/providers/github.sh"
GITLAB_ADAPTER="$RUNTIME/include/providers/gitlab.sh"
STOP_EVENT="$RUNTIME/event/stopping_docker"

fail=0
bad() { printf 'PROVIDER CONTRACT FAIL: %s\n' "$*" >&2; fail=1; }

cfg_value() {
  sed -n "s/^$1=\"\([^\"]*\)\".*$/\1/p" "$CFG" | head -1
}

# GitHub is the upgrade-safe default and all public provider settings must be
# represented in the config, engine, and UI defaults.
[ "$(cfg_value CI_PROVIDER)" = "github" ] || bad "CI_PROVIDER must default to github"
for key in CI_PROVIDER GITLAB_URL GITLAB_RUNNER_IMAGE GITLAB_PROJECTS GITLAB_SHUTDOWN_TIMEOUT \
  GITLAB_ALLOWED_IMAGES GITLAB_ALLOWED_SERVICES GITLAB_PULL_POLICY GITLAB_SHM_SIZE
do
  [ -n "$(cfg_value "$key")" ] || {
    case "$key" in
      GITLAB_PROJECTS|GITLAB_ALLOWED_IMAGES|GITLAB_ALLOWED_SERVICES) ;;
      *) bad "$key is missing or empty in default.cfg" ;;
    esac
  }
  grep -q "^${key}=" "$ENGINE" || bad "$key is missing from the engine defaults"
  grep -q "'$key'[[:space:]]*=>" "$UI" || bad "$key is missing from the UI defaults"
done
[ "$(cfg_value GITLAB_SHUTDOWN_TIMEOUT)" = 7200 ] \
  || bad "GITLAB_SHUTDOWN_TIMEOUT must default to a two-hour graceful drain"
[ "$(cfg_value GITLAB_PULL_POLICY)" = auto ] \
  || bad "GITLAB_PULL_POLICY must preserve the existing source-aware behavior by default"
[ "$(cfg_value GITLAB_SHM_SIZE)" = 0 ] \
  || bad "GITLAB_SHM_SIZE must preserve Docker's shared-memory default"

case "$(cfg_value GITLAB_URL)" in
  https://*) ;;
  *) bad "GITLAB_URL must have a safe HTTPS default" ;;
esac
case "$(cfg_value GITLAB_RUNNER_IMAGE)" in
  gitlab/gitlab-runner:*) ;;
  *) bad "GITLAB_RUNNER_IMAGE must default to the official manager image" ;;
esac

# Provider credentials have distinct files and must never be conflated with the
# legacy GitHub PAT at /token. The API token and custom CA are optional, but their
# endpoints/storage names remain part of the public operator contract.
for name in gitlab-runner-token gitlab-api-token gitlab-ca.crt; do
  grep -qF "$name" "$ENGINE" || bad "credential contract '$name' is missing from the engine"
  grep -qF "$name" "$UI" || bad "credential contract '$name' is missing from the UI"
  grep -qF "$name" "$EXEC" || bad "credential contract '$name' is missing from the endpoint"
done
for action in \
  set-gitlab-runner-token clear-gitlab-runner-token \
  set-gitlab-api-token clear-gitlab-api-token \
  set-gitlab-ca clear-gitlab-ca
do
  grep -q "case '$action'" "$EXEC" || bad "endpoint action is missing: $action"
done
grep -qF "strncmp(\$tok, 'glrt-', 5) === 0" "$EXEC" \
  || bad "runner-token endpoint does not require the exact safe glrt- prefix"
if grep -qF ')?glrt-' "$EXEC"; then
  bad "runner-token endpoint accepts instance-prefixed values that official Runner unregister treats as legacy"
fi
if grep -qF 'glrtr?-' "$EXEC"; then
  bad "runner-token endpoint accepts registration-created glrtr- tokens that can delete a shared runner"
fi
# GitLab 18 routable runner tokens contain two dots. The UI endpoint, shell
# readiness/probe/unregister guards, config parser, and diagnostic redactor must
# all accept the same narrow alphabet and 10..507 post-prefix length contract.
grep -qF "preg_match('/\A[A-Za-z0-9_.-]+\z/D', \$payload)" "$EXEC" \
  || bad "runner-token endpoint rejects GitLab routable-token dots"
grep -qF '$length < 10 || $length > 507' "$EXEC" \
  || bad "runner-token endpoint does not enforce the shared 10..507 post-prefix bound"
grep -qF '[ "${#token}" -le 512 ]' "$GITLAB_ADAPTER" \
  && grep -qF '[ "${#payload}" -ge 10 ]' "$GITLAB_ADAPTER" \
  && grep -qF 'case "$payload" in *[!A-Za-z0-9_.-]*) return 1' "$GITLAB_ADAPTER" \
  && [ "$(grep -Fc 'glrt-[A-Za-z0-9_.-]{10,507}' "$GITLAB_ADAPTER")" -ge 2 ] \
  || bad "GitLab readiness/probe/unregister validators do not share the dotted 10..507 token contract"
grep -qF '\(glrt-[A-Za-z0-9_.-]*\)' "$GITLAB_ADAPTER" \
  || bad "GitLab saved-probe parser truncates routable runner tokens at the first dot"
grep -qF 'glrt(r)?-[A-Za-z0-9_.-]{10,507}' "$ENGINE" \
  || bad "GitLab diagnostic redaction does not consume full routable runner tokens"
grep -qF 'glrt(r)?-[A-Za-z0-9_.-]{10,507}' "$EXEC" \
  || bad "endpoint redaction does not share the engine's routable runner-token shape"
# The engine only filters its own log verbs. stderr is where an unanticipated
# secret would surface, and run() merges stderr into the response body, so both
# command wrappers must return through the redactor — that one choke point is
# what stops a future action from reopening the gap. tests/log-redaction.sh pins
# the endpoint and the engine to byte-identical output.
grep -Eq '^function run\(\$cmd\) \{.*return \[crf_redact\(' "$EXEC" \
  || bad "endpoint returns merged command output without log redaction"
grep -Eq '^function run_json\(\$cmd\) \{.*return \[crf_redact\(' "$EXEC" \
  || bad "endpoint returns command JSON output without log redaction"
# Self-managed GitLab can customize its PAT prefix. The optional API token must
# use a narrow token-safe alphabet, but `glpat-` is only the common default.
grep -qF 'A-Za-z0-9_.@:+\/=~-' "$EXEC" || bad "API-token endpoint does not enforce a narrow token-safe alphabet"
grep -qF '@chmod($tmp, 0600)' "$EXEC" || bad "atomic secret writes do not lock the temporary file to 0600"
grep -qF '@chmod($path, 0600)' "$EXEC" || bad "atomic secret writes do not lock the installed file to 0600"
grep -qF 'Session expired — reload this page' "$UI" \
  || bad "GitLab runner-token UI hides an actionable stale-session failure"
grep -qF "Save failed — '+m.slice(0,120)" "$UI" \
  || bad "GitLab runner-token UI hides the bounded request failure reason"
grep -qF "parse_ini_file('/var/local/emhttp/var.ini')" "$CORE" \
  || bad "shared UI core has no server-side CSRF fallback"
grep -qF 'globalThis.csrf_token' "$CORE" \
  || bad "shared UI core does not use Unraid 7.3's live browser CSRF token"
grep -qF 'p.csrf_token = liveCsrf' "$CORE" \
  || bad "shared UI actions do not submit the resolved CSRF token"

# The authenticated UI endpoint is POST-only and must never accept GET/query or
# cookie fallbacks through $_REQUEST. Every untrusted scalar reaches a type check
# before hash_equals/preg_match, and opaque registry passwords retain meaningful
# edge spaces while remaining bounded, single-line values.
grep -qF "\$_SERVER['REQUEST_METHOD']" "$EXEC" || bad "endpoint does not inspect the HTTP request method"
grep -qF "header('Allow: POST')" "$EXEC" || bad "endpoint does not advertise its POST-only action contract"
if grep -qF '$_REQUEST' "$EXEC"; then
  bad "endpoint still accepts query/cookie action inputs through \$_REQUEST"
fi
grep -qF '!is_string($given)' "$EXEC" || bad "CSRF comparison does not reject non-scalar token input"
grep -qF "function_exists('csrf_terminate')" "$EXEC" \
  || bad "endpoint does not recognize Unraid's platform CSRF prevalidation"
grep -qF "!array_key_exists('csrf_token', \$_POST)" "$EXEC" \
  || bad "endpoint does not require Unraid's consumed POST-token state"
grep -qF "!array_key_exists('HTTP_X_CSRF_TOKEN', \$_SERVER)" "$EXEC" \
  || bad "endpoint does not require Unraid's consumed header-token state"
grep -qF 'hash_equals($csrf, $csrf_token)' "$EXEC" \
  || bad "endpoint does not bind Unraid's prevalidated token to current server state"
grep -qF '$action = is_string($rawAction)' "$EXEC" || bad "endpoint dispatch does not reject a non-scalar action"
sed -n "/case 'scale':/,/case 'set-token':/p" "$EXEC" | grep -F '!is_string($raw)' >/dev/null \
  || bad "scale endpoint does not reject non-scalar targets"
for pair in "recycle:force-forget-gitlab" "runner-log:image-info"; do
  action="${pair%%:*}"; next="${pair#*:}"
  sed -n "/case '$action':/,/case '$next':/p" "$EXEC" | grep -F '!is_string($n)' >/dev/null \
    || bad "$action endpoint does not reject a non-scalar runner name"
done
grep -qF "preg_match('/[\\x00-\\x1F\\x7F]/', \$raw)" "$EXEC" \
  || bad "registry-token endpoint does not reject control characters"
grep -qF 'strlen($raw) > 8192' "$EXEC" || bad "registry-token endpoint has no explicit size bound"
if sed -n "/case 'set-registry-token':/,/case 'clear-registry-token':/p" "$EXEC" | grep 'trim(' >/dev/null; then
  bad "registry-token endpoint trims an opaque password"
fi

# Credential removal and every derived-file scrub must share the fleet mutex;
# the endpoint is deliberately only a pass-through for the engine's JSON result.
for action in credential-clear-github-token credential-clear-gitlab-runner credential-clear-registry-token; do
  grep -Eq "^[[:space:]]*${action}\\)[[:space:]]+with_fleet_lock wait" "$ENGINE" \
    || bad "credential engine action is not fleet-locked: $action"
  grep -qF " $action" "$EXEC" || bad "endpoint does not delegate to credential engine action: $action"
done
grep -Eq 'reload_locked_snapshot( \|\| exit 1)?; "\$@"' "$ENGINE" \
  || bad "fleet-lock wrapper does not reload config/secrets after acquiring the lock"
grep -qF 'GITLAB_CA_FINGERPRINT' "$GITLAB_ADAPTER" \
  || bad "GitLab config fingerprint does not use the locked in-memory CA snapshot"
grep -qF '/etc/gitlab-runner/certs/ca.crt:ro' "$GITLAB_ADAPTER" \
  || bad "custom GitLab CA is not propagated to Docker-executor helpers/jobs"
grep -qF '/etc/docker/certs.d/$registry_authority/ca.crt' "$GITLAB_ADAPTER" \
  || bad "custom GitLab CA is not propagated to the configured DinD registry authority"

# GitLab always creates a clean job container even though its manager persists.
# Keep the saved GitHub EPHEMERAL value in the submitted form, but replace the
# selector with an explicit provider-semantic label while GitLab is active.
grep -qF 'id="crfs-gitlab-ephemeral"' "$UI" \
  || bad "GitLab always-ephemeral UI status is missing"
grep -qF 'always ephemeral (clean Docker job container per job)' "$UI" \
  || bad "GitLab EPHEMERAL semantics are not stated in the UI"
grep -qF "ephemeral.style.display=provider==='github'?'':'none'" "$UI" \
  || bad "provider switch does not replace the GitHub EPHEMERAL selector for GitLab"

# Never opt token-bearing manager configs or derived Docker auth into a plugin
# support bundle. The current runtime has no such bundle manifest; this scan
# makes a future opt-in fail closed unless it remains an explicit safe allowlist.
while IFS= read -r manifest; do
  if grep -Eiq 'gitlab-runners|config\.toml|gitlab-runner-token|gitlab-api-token|registry-token|docker/config\.json' "$manifest"; then
    bad "diagnostics/support manifest includes a credential-bearing path: $manifest"
  fi
done < <(find "$RUNTIME" -maxdepth 2 -type f \( -iname 'diagnostics*.json' -o -iname '*support*bundle*' \) -print)
grep -qF 'per-slot/probe `config.toml` files' README.md \
  || bad "operator docs do not warn that per-slot/probe GitLab configs are live credentials"

# Existing installs continue to use default.Dockerfile. The named GitHub default
# is byte-identical, while GitLab's editable default is a job image—not a second
# runner-manager image.
for file in default.Dockerfile default.github.Dockerfile default.gitlab.Dockerfile; do
  [ -s "$RUNTIME/$file" ] || bad "shipped Dockerfile is missing: $file"
done
cmp -s "$RUNTIME/default.Dockerfile" "$RUNTIME/default.github.Dockerfile" || \
  bad "default.github.Dockerfile must remain byte-identical to legacy default.Dockerfile"
grep -qF 'Docker did not become ready' "$RUNTIME/default.github.Dockerfile" || \
  bad "GitHub runner image does not fail closed when nested Docker stays unavailable"
if grep -Eiq '^[[:space:]]*FROM[[:space:]]+gitlab/gitlab-runner' "$RUNTIME/default.gitlab.Dockerfile"; then
  bad "default.gitlab.Dockerfile must be a job image, not the runner manager"
fi
grep -qF 'Dockerfile.$CI_PROVIDER' "$ENGINE" || bad "engine does not select an editable Dockerfile by provider"
grep -qF 'default.$CI_PROVIDER.Dockerfile' "$ENGINE" || bad "engine does not select a shipped Dockerfile by provider"
grep -qF '[ "$CI_PROVIDER" = github ] && [ ! -f "$df" ] && [ -f "$CFGDIR/Dockerfile" ] && df="$CFGDIR/Dockerfile"' "$ENGINE" \
  || bad "engine does not retain the legacy unsuffixed GitHub Dockerfile fallback"
grep -qF 'Dockerfile.$suffix' "$EXEC" || bad "endpoint does not select an editable Dockerfile by provider"
grep -qF 'default.$suffix.Dockerfile' "$EXEC" || bad "endpoint does not select a shipped default by provider"
grep -qF 'Dockerfile.$crf_provider' "$IMAGE_UI" || bad "image UI does not select the provider-specific editable Dockerfile"

# Provider-specific runtime behavior belongs in explicit adapters; the engine
# owns only common lifecycle/locking/cache/network orchestration.
for adapter in "$GITHUB_ADAPTER" "$GITLAB_ADAPTER"; do
  [ -s "$adapter" ] || bad "provider adapter is missing: $adapter"
  grep -q '^[a-z]*_remote_image_host_pull_required()' "$adapter" \
    || bad "provider does not declare where remote job images must be pulled: $adapter"
done
grep -q '^provider_remote_image_host_pull_required()' "$ENGINE" \
  || bad "common provisioning does not dispatch remote-image pull ownership"
grep -q '^github_build_args()' "$GITHUB_ADAPTER" || bad "GitHub build adapter contract is missing"
grep -qF -- '--add-host "host.docker.internal:host-gateway"' "$GITHUB_ADAPTER" \
  || bad "GitHub runners do not expose a stable local farm-host address"
grep -q '^github_queued_refresh()' "$GITHUB_ADAPTER" || bad "GitHub queue adapter contract is missing"
grep -q '^gitlab_write_config()' "$GITLAB_ADAPTER" || bad "GitLab TOML adapter contract is missing"
grep -q '^gitlab_start_one()' "$GITLAB_ADAPTER" || bad "GitLab manager adapter contract is missing"
grep -q '^gitlab_validate_host_socket_manager_version()' "$GITLAB_ADAPTER" \
  || bad "GitLab host-socket manager version gate is missing"
grep -q '^gitlab_validate_manager_version()' "$GITLAB_ADAPTER" \
  || bad "GitLab all-mode Runner 16 manager-only-unregister gate is missing"
grep -q '^gitlab_verify_manager_token()' "$GITLAB_ADAPTER" \
  || bad "GitLab token/system-ID verification preflight is missing"
grep -q '^gitlab_recover_pending_probe()' "$GITLAB_ADAPTER" \
  || bad "GitLab token-probe recovery transaction is missing"
sed -n '/^gitlab_assert_no_orphan_manager_configs()/,/^}/p' "$GITLAB_ADAPTER" \
  | grep 'gitlab_recover_pending_probe || return 1' >/dev/null \
  || bad "provider lifecycle ignores an ambiguous GitLab token-probe manager"
sed -n '/^gitlab_start_one()/,/^}/p' "$GITLAB_ADAPTER" \
  | grep 'gitlab_verify_manager_token "$name"' >/dev/null \
  || bad "GitLab manager can start without verifying its token/system ID"
sed -n '/^cmd_logs_tail()/,/^}/p' "$ENGINE" | grep 'managed_runner_snapshot' >/dev/null \
  || bad "runner log reads are not ownership-gated"
for fn in gitlab_start_one gitlab_validate; do
  sed -n "/^${fn}()/,/^}/p" "$GITLAB_ADAPTER" \
    | grep 'gitlab_validate_host_socket_manager_version' >/dev/null \
    || bad "$fn bypasses the host-socket Runner 18.5 compatibility gate"
done
sed -n '/^gitlab_start_stopped()/,/^}/p' "$GITLAB_ADAPTER" \
  | grep 'gitlab_validate_manager_version "$image" runtime' >/dev/null \
  || bad "gitlab_start_stopped does not gate the immutable image it will restart"
sed -n '/^gitlab_unregister_manager()/,/^}/p' "$GITLAB_ADAPTER" \
  | grep 'gitlab_validate_manager_version "$image" unregister' >/dev/null \
  || bad "GitLab unregister can execute through a pre-16 manager image"
sed -n '/^gitlab_unregister_manager()/,/^}/p' "$GITLAB_ADAPTER" \
  | grep 'docker run --rm --network "$manager_network"' >/dev/null \
  || bad "GitLab unregister does not reuse the retired manager's Docker network"
grep -qF 'v18.5.0' "$UI" \
  || bad "GitLab host-socket minimum Runner version is missing from the UI"
grep -qF "['REGISTRY_SERVER','REGISTRY_USERNAME'].forEach(n=>setRow(n,remote||gitlab))" "$UI" \
  || bad "GitLab built-in defaults hide registry auth needed by job/service overrides"
if grep -Eq '^(github|gitlab)_[A-Za-z0-9_]+\(\)' "$ENGINE"; then
  bad "provider-specific function definitions remain in the common engine"
fi
grep -qF 'listen_address = "127.0.0.1:9252"' "$GITLAB_ADAPTER" || bad "GitLab metrics endpoint is not loopback-only"
grep -qF 'executor_host="unix:///runner-services/docker.sock"' "$GITLAB_ADAPTER" \
  || bad "GitLab DinD manager does not follow socket recreation through a directory mount"
grep -q '^gitlab_effective_pull_policy()' "$GITLAB_ADAPTER" || bad "source-aware GitLab pull-policy helper is missing"
grep -qF 'echo if-not-present' "$GITLAB_ADAPTER" || bad "built-in GitLab job image must use if-not-present pull policy"
grep -qF 'allowed_pull_policies = [%s]' "$GITLAB_ADAPTER" || bad "jobs can override the configured GitLab pull policy"
grep -qF 'allowed_images = %s' "$GITLAB_ADAPTER" || bad "GitLab allowed-image policy is not emitted"
grep -qF 'allowed_services = %s' "$GITLAB_ADAPTER" || bad "GitLab allowed-service policy is not emitted"
grep -qF 'shm_size = %s' "$GITLAB_ADAPTER" || bad "GitLab executor shared-memory policy is not emitted"
grep -q '^gitlab_ensure_system_id()' "$GITLAB_ADAPTER" || bad "per-slot GitLab system-ID persistence is missing"
grep -qF -- '--stop-signal SIGQUIT --stop-timeout "$GITLAB_SHUTDOWN_TIMEOUT"' "$GITLAB_ADAPTER" \
  || bad "GitLab manager does not persist explicit graceful Docker stop semantics"
grep -qF 'shutdown_timeout = %s' "$GITLAB_ADAPTER" \
  || bad "generated GitLab TOML does not carry the graceful shutdown timeout"
grep -qF 'unregister --name "$manager_name"' "$GITLAB_ADAPTER" \
  || bad "GitLab slot retirement does not target one persisted manager name"
if grep -qF 'unregister --all-runners' "$GITLAB_ADAPTER"; then
  bad "GitLab slot retirement can broadly unregister every config entry"
fi
grep -q '^cmd_docker_stopping_locked()' "$ENGINE" \
  || bad "common engine lacks the GitLab pre-Docker-shutdown quiesce path"
sed -n '/^cmd_docker_stopping_locked()/,/^}/p' "$ENGINE" \
  | grep -F 'provider_stop_owned_runner "$c" "$id" "$provider" &' >/dev/null \
  || bad "Docker shutdown does not signal all GitLab managers before waiting"
sed -n '/^cmd_docker_stopping_locked()/,/^}/p' "$ENGINE" \
  | grep -F 'for pid in $pids; do wait "$pid"' >/dev/null \
  || bad "Docker shutdown does not wait for every concurrently signalled manager"
grep -qF 'docker-stopping)  cmd_docker_stopping' "$ENGINE" \
  || bad "GitLab Docker-shutdown quiesce verb is not dispatched"
grep -qF 'runner-farm.sh" docker-stopping' "$STOP_EVENT" \
  || bad "Unraid stopping_docker event does not quiesce GitLab managers before sidecars"
grep -q '^github_docker_stopping_timeout()' "$GITHUB_ADAPTER" \
  || bad "GitHub adapter does not explicitly preserve its Docker-shutdown behavior"
grep -q '^gitlab_docker_stopping()' "$GITLAB_ADAPTER" \
  || bad "GitLab adapter does not own its Docker-shutdown drain behavior"
grep -qF -- '--add-host "host.docker.internal:host-gateway"' "$GITLAB_ADAPTER" \
  || bad "GitLab DinD sidecars cannot resolve the default shared-mirror endpoint"
grep -qF -- '--restart=unless-stopped' "$GITLAB_ADAPTER" \
  || bad "GitLab DinD sidecars do not survive Docker daemon restarts"
grep -qF 'name="${NAME_PREFIX}-validate-$suffix"' "$GITLAB_ADAPTER" \
  || bad "GitLab validation still uses a predictable fixed container name"
grep -qF 'net.unraid.ci-runner-farm.role=validate-job' "$GITLAB_ADAPTER" \
  || bad "GitLab validation job is not visibly plugin-labelled"
grep -qF 'firewall_prepare_replacement || return 1' "$GITLAB_ADAPTER" \
  || bad "GitLab validation clears live-fleet strict firewall policy instead of adding replacement rules"
if grep -qF 'docker rm -f "$name" "${name}-job"' "$GITLAB_ADAPTER"; then
  bad "GitLab validation unconditionally removes fixed-name containers"
fi
grep -q '^gitlab_prepare_remote_image()' "$GITLAB_ADAPTER" \
  || bad "GitLab adapter does not own policy-aware remote image preparation"
grep -q '^gitlab_remote_image_update_allowed()' "$GITLAB_ADAPTER" \
  || bad "GitLab adapter does not gate remote image-update polling by pull policy"
grep -q '^gitlab_force_forget_local()' "$GITLAB_ADAPTER" \
  || bad "GitLab adapter lacks the local-only break-glass cleanup path"
grep -q '^gitlab_scrub_retired_slot_credentials()' "$GITLAB_ADAPTER" \
  || bad "successful GitLab retirement does not scrub reusable slot credentials"
sed -n '/^gitlab_remove_runner()/,/^}/p' "$GITLAB_ADAPTER" \
  | grep 'gitlab_scrub_retired_slot_credentials' >/dev/null \
  || bad "GitLab manager removal bypasses post-success credential scrubbing"
grep -qF 'cmd_stop || return 1' "$ENGINE" \
  || bad "restart can mask a failed stop/unregister operation"
grep -qF 'cmd_recycle "$c"' "$ENGINE" \
  || bad "image auto-update bypasses validated recycle preflight"
sed -n '/^cmd_reconcile_config()/,/^}/p' "$ENGINE" | grep 'managed="$(managed_names)"' >/dev/null \
  || bad "config reconcile does not fail closed when fleet enumeration fails"
sed -n '/^cmd_reconcile_config()/,/^}/p' "$ENGINE" | grep -F 'provider_token_ready' >/dev/null \
  || bad "config reconcile can launch against an existing fleet without checking provider credentials"
sed -n '/^cmd_reconcile_config()/,/^}/p' "$ENGINE" | grep -F 'provider_validate_settings' >/dev/null \
  || bad "config reconcile can launch without validating provider settings"
sed -n '/^cmd_stop()/,/^}/p' "$ENGINE" | grep -F 'cleanup_orphan_github_validations || return 1' >/dev/null \
  || bad "Stop does not ownership-check and remove orphaned GitHub validation containers"
grep -qF "d.source==='remote'" "$IMAGE_UI" \
  || bad "image UI tells remote-provider users to build an image locally"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "provider-contract: OK — provider defaults, credentials, and Dockerfile compatibility are wired"
