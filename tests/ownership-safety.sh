#!/usr/bin/env bash
# Destructive fixed-name operations must be authorized by one immutable Docker
# object snapshot. Exercise the real recycle and GitHub validation paths with a
# mocked Docker CLI so regressions cannot hide behind UI-only name validation.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "ownership-safety: $*" >&2; exit 1; }

run_recycle_tests() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/recycle-cfg" CRF_RUNDIR="$tmp/recycle-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"

  local_id="1111111111111111111111111111111111111111111111111111111111111111"
  mutation_log="$tmp/recycle-mutations.log"
  : > "$mutation_log"
  SNAP_MODE=unlabeled
  REMOVED=0
  RUN_FAILS=0

  docker() {
    local cmd="${1:-}" fmt="" target="" managed provider role index
    shift || true
    case "$cmd" in
      inspect)
        if [ "${1:-}" = -f ]; then
          fmt="$2"; target="$3"
          case "$fmt" in
            *net.unraid.ci-runner-farm.managed*)
              managed=true; provider=github; role=runner; index=1
              case "$SNAP_MODE" in
                unlabeled) managed='<no value>'; provider='<no value>'; role='<no value>'; index='<no value>' ;;
                wrong-provider) provider=foreign ;;
                wrong-role) role=foreign ;;
                wrong-index) index=2 ;;
                legacy) provider='<no value>'; role='<no value>' ;;
                valid) ;;
              esac
              printf '%s|%s|%s|%s|%s|abc123|/%s\n' \
                "$local_id" "$managed" "$provider" "$role" "$index" "$target"
              ;;
            '{{.Id}}')
              [ "$REMOVED" -eq 0 ] && [ "$target" = ci-runner-1 ] \
                && printf '%s\n' "$local_id" || return 1
              ;;
            '{{.Name}}')
              [ "$REMOVED" -eq 0 ] && [ "$target" = "$local_id" ] \
                && printf '/ci-runner-1\n' || return 1
              ;;
            *) printf 'mock-inspect\n' ;;
          esac
        else
          target="${1:-}"
          [ "$REMOVED" -eq 0 ] && { [ "$target" = "$local_id" ] || [ "$target" = ci-runner-1 ]; }
        fi
        ;;
      stop)
        printf 'docker stop %s\n' "$*" >> "$mutation_log"
        [ "${*: -1}" = "$local_id" ]
        ;;
      rm)
        printf 'docker rm %s\n' "$*" >> "$mutation_log"
        [ "${*: -1}" = "$local_id" ] || return 1
        REMOVED=1
        ;;
      run)
        printf 'docker run %s\n' "$*" >> "$mutation_log"
        if [ "$RUN_FAILS" -eq 1 ]; then
          printf 'docker: Error response from daemon: manifest unknown.\n' >&2
          printf 'auth: ghp_0123456789abcdefghijABCDEFGHIJ\n' >&2
          return 125
        fi
        ;;
      *) return 0 ;;
    esac
  }

  managed_names() { printf '%s\n' ci-runner-1; }
  crf_confgen() { printf 'abc123\n'; }
  provider_token_ready() { return 0; }
  provider_validate_settings() { return 0; }
  provision_base() { return 0; }
  firewall_prepare_replacement() { return 0; }
  gitlab_cleanup_orphan_sidecars() { return 0; }
  github_replacement_preflight() { return 0; }
  recycle_image_preflight() { return 0; }
  effective_image() { printf 'replacement-image\n'; }
  build_args() { ARGS=( replacement-image ); }
  github_deregister_runner_api() { printf 'provider-api %s\n' "$1" >> "$mutation_log"; }
  CI_PROVIDER=github
  NETWORK_ISOLATION=off
  IMAGE_SOURCE=builtin

  # Every incomplete/mismatched ownership contract must fail before a pull,
  # stop, remote deregistration, or Docker removal can happen.
  for SNAP_MODE in unlabeled wrong-provider wrong-role wrong-index; do
    : > "$mutation_log"; REMOVED=0
    if cmd_recycle ci-runner-1 >"$tmp/recycle-$SNAP_MODE.out" 2>/dev/null; then
      fail "recycle accepted $SNAP_MODE ownership labels"
    fi
    [ ! -s "$mutation_log" ] || fail "recycle mutated an $SNAP_MODE collision"
  done

  # Existing managed GitHub slots from before provider/role labels remain a
  # narrow upgrade-compatible form; managed+matching index are still required.
  SNAP_MODE=legacy
  legacy="$(managed_runner_snapshot ci-runner-1)" || fail "legacy managed GitHub slot was rejected"
  case "$legacy" in "$local_id|github|runner|1|abc123") ;; *) fail "legacy GitHub snapshot was not normalized" ;; esac

  # A current owned slot is stopped/removed only through its immutable ID, while
  # the provider API still receives the stable ci-runner-N identity.
  SNAP_MODE=valid
  : > "$mutation_log"; REMOVED=0
  cmd_recycle ci-runner-1 >"$tmp/recycle-valid.out" \
    || { cat "$tmp/recycle-valid.out" >&2; fail "owned recycle failed"; }
  grep -q "^docker stop --timeout 30 $local_id$" "$mutation_log" \
    || fail "recycle did not stop the immutable container ID"
  grep -q "^docker rm $local_id$" "$mutation_log" \
    || fail "recycle did not remove the immutable container ID"
  grep -q '^provider-api ci-runner-1$' "$mutation_log" \
    || fail "provider API did not retain the stable slot name"
  if grep -Eq '^docker (stop|rm).*ci-runner-1$' "$mutation_log"; then
    fail "recycle sent the mutable slot name to a destructive Docker command"
  fi

  # The replacement is started only after the old runner is gone, so a failed
  # 'docker run' must surface Docker's own reason instead of the generic message
  # alone. Docker diagnostics are untrusted, so the detail is still redacted, and
  # the JSON contract on stdout stays byte-identical for callers that parse it.
  : > "$mutation_log"; REMOVED=0; RUN_FAILS=1
  if cmd_recycle ci-runner-1 >"$tmp/recycle-runfail.out" 2>"$tmp/recycle-runfail.err"; then
    RUN_FAILS=0; fail "recycle reported success after docker run failed"
  fi
  RUN_FAILS=0
  grep -qF 'manifest unknown' "$tmp/recycle-runfail.err" \
    || fail "recycle discarded the docker run error"
  if grep -qF 'ghp_0123456789abcdefghijABCDEFGHIJ' "$tmp/recycle-runfail.err"; then
    fail "recycle logged an unredacted token from docker diagnostics"
  fi
  # exec.php consumes the verdict as the FINAL line of stdout, after the progress
  # logs, so assert that position rather than mere presence anywhere in the stream.
  [ "$(tail -n 1 "$tmp/recycle-runfail.out")" = '{"ok":false,"error":"removed but not recreated"}' ] \
    || fail "recycle changed its final-line JSON verdict on a failed replacement"
)

run_github_validate_test() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/validate-cfg" CRF_RUNDIR="$tmp/validate-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/validate-cache"
  # shellcheck source=/dev/null
  source "$ENGINE"

  MOCK_VALIDATION_ID="2222222222222222222222222222222222222222222222222222222222222222"
  docker_log="$tmp/github-validate-docker.log"
  : > "$docker_log"
  VALIDATE_NAME=""

  check_cache_root() { return 0; }
  ensure_dirs() { return 0; }
  registry_login() { return 0; }
  crf_safe_cache_root() { printf '%s\n' "$CACHE_ROOT"; }
  crf_confgen() { printf 'abc123\n'; }
  effective_image() { printf 'validation-image\n'; }
  CACHE_ROOT="$tmp/validate-cache"
  CACHE_MOUNTS=""
  DIND=false
  SHARE_DOCKER_SOCK=false
  WORK_TMPFS_SIZE=""
  RUNNER_CPUS=""
  RUNNER_MEMORY=""
  GH_REPOS="example/project"

  docker() {
    local cmd="${1:-}" fmt="" target="" prev="" arg
    shift || true
    case "$cmd" in
      run)
        for arg in "$@"; do
          [ "$prev" = --name ] && VALIDATE_NAME="$arg"
          prev="$arg"
        done
        printf 'docker run %s\n' "$*" >> "$docker_log"
        [ -n "$VALIDATE_NAME" ] || return 1
        ;;
      inspect)
        [ "${1:-}" = -f ] || return 1
        fmt="$2"; target="$3"
        case "$fmt" in
          *net.unraid.ci-runner-farm.managed*)
            [ "$target" = "$VALIDATE_NAME" ] || return 1
            printf '%s|true|github|validate|99|abc123|/%s\n' "$MOCK_VALIDATION_ID" "$VALIDATE_NAME"
            ;;
          *) printf 'mock-inspect\n' ;;
        esac
        ;;
      exec)
        printf 'docker exec %s\n' "$*" >> "$docker_log"
        [ "${1:-}" = "$MOCK_VALIDATION_ID" ]
        ;;
      rm)
        printf 'docker rm %s\n' "$*" >> "$docker_log"
        [ "${1:-}" = -f ] && [ "${2:-}" = "$MOCK_VALIDATION_ID" ]
        ;;
      *) return 0 ;;
    esac
  }

  github_validate >"$tmp/github-validate.out" \
    || { cat "$tmp/github-validate.out" >&2; fail "GitHub validation failed"; }
  printf '%s' "$VALIDATE_NAME" | grep -qE '^ci-runner-validate-[0-9a-f]{12}$' \
    || fail "GitHub validation did not use a randomized container name"
  grep -q 'net.unraid.ci-runner-farm.provider=github' "$docker_log" \
    || fail "GitHub validation container lacks its provider label"
  grep -q 'net.unraid.ci-runner-farm.role=validate' "$docker_log" \
    || fail "GitHub validation container lacks its validation-role label"
  grep -q "^docker rm -f $MOCK_VALIDATION_ID$" "$docker_log" \
    || fail "GitHub validation did not remove its immutable container ID"
  if grep -Eq 'docker rm -f ci-runner-validate($| )' "$docker_log"; then
    fail "GitHub validation attempted to remove the old fixed name"
  fi

  # Directory preparation and registry authentication are validation gates, not
  # best-effort setup. Force the later path to be reachable so an implementation
  # that discards either failure cannot pass this regression test.
  github_build_args() { ARGS=( validation-image ); }
  ensure_dirs() { return 1; }
  : > "$docker_log"
  if github_validate >"$tmp/github-validate-ensure-fail.out" 2>&1; then
    fail "GitHub validation succeeded after directory setup failed"
  fi
  [ ! -s "$docker_log" ] || fail "GitHub validation reached Docker after directory setup failed"

  ensure_dirs() { return 0; }
  registry_login() { return 1; }
  : > "$docker_log"
  if github_validate >"$tmp/github-validate-login-fail.out" 2>&1; then
    fail "GitHub validation succeeded after registry login failed"
  fi
  [ ! -s "$docker_log" ] || fail "GitHub validation reached Docker after registry login failed"
)

run_log_ownership_tests() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/log-cfg" CRF_RUNDIR="$tmp/log-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"

  log_id="3333333333333333333333333333333333333333333333333333333333333333"
  docker_calls="$tmp/log-docker.calls"; : > "$docker_calls"
  LOG_OWNED=0
  docker() {
    if [ "${1:-}" = inspect ] && [ "${2:-}" = -f ]; then
      if [ "$LOG_OWNED" = 1 ]; then
        printf '%s|true|github|runner|1|abc123|/ci-runner-1\n' "$log_id"
      else
        printf '%s|<no value>|<no value>|<no value>|<no value>|<no value>|/ci-runner-1\n' "$log_id"
      fi
      return 0
    fi
    if [ "${1:-}" = logs ]; then
      printf 'docker %s\n' "$*" >> "$docker_calls"
      printf 'owned runner log\n'
      return 0
    fi
    return 1
  }

  if cmd_logs_tail ci-runner-1 150 >/dev/null 2>&1; then
    fail "log tail accepted an unowned fixed-name collision"
  fi
  [ ! -s "$docker_calls" ] || fail "unowned log request reached docker logs"

  LOG_OWNED=1
  cmd_logs_tail ci-runner-1 150 > "$tmp/owned-runner.log" \
    || fail "owned runner log request failed"
  grep -q "^docker logs --tail 150 $log_id$" "$docker_calls" \
    || fail "runner logs were read through the mutable fixed name instead of immutable ID"
  grep -q '^owned runner log$' "$tmp/owned-runner.log" \
    || fail "owned runner logs were not returned"
)

run_orphan_validation_cleanup_tests() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/orphan-validate-cfg" CRF_RUNDIR="$tmp/orphan-validate-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"

  orphan_id="4444444444444444444444444444444444444444444444444444444444444444"
  orphan_name=ci-runner-validate-abcdef123456
  orphan_index=99
  orphan_enum_fail=0
  orphan_log="$tmp/orphan-validate-docker.log"; : > "$orphan_log"

  docker() {
    local cmd="${1:-}" fmt target
    shift || true
    case "$cmd" in
      ps)
        [ "$orphan_enum_fail" -eq 0 ] || return 1
        printf '%s\n' "$orphan_name"
        ;;
      inspect)
        [ "${1:-}" = -f ] || return 1
        fmt="$2"; target="$3"
        case "$fmt" in
          *net.unraid.ci-runner-farm.managed*)
            printf '%s|true|github|validate|%s|abc123|/%s\n' \
              "$orphan_id" "$orphan_index" "$target"
            ;;
          *) return 1 ;;
        esac
        ;;
      rm)
        printf 'docker rm %s\n' "$*" >> "$orphan_log"
        [ "${1:-}" = -f ] && [ "${2:-}" = "$orphan_id" ]
        ;;
      *) return 1 ;;
    esac
  }

  cleanup_orphan_github_validations \
    || fail "owned orphaned GitHub validation container was not cleaned"
  grep -qx "docker rm -f $orphan_id" "$orphan_log" \
    || fail "orphaned GitHub validation was not removed through its immutable ID"

  : > "$orphan_log"; orphan_index=1
  if cleanup_orphan_github_validations >/dev/null 2>&1; then
    fail "orphan cleanup accepted a validation container with the wrong index"
  fi
  [ ! -s "$orphan_log" ] || fail "wrong-index validation collision reached docker rm"

  orphan_index=99; orphan_name=ci-runner-validate-fixed
  if cleanup_orphan_github_validations >/dev/null 2>&1; then
    fail "orphan cleanup accepted a non-random validation container name"
  fi
  [ ! -s "$orphan_log" ] || fail "unexpected validation name reached docker rm"

  orphan_name=ci-runner-validate-abcdef123456; orphan_enum_fail=1
  if cleanup_orphan_github_validations >/dev/null 2>&1; then
    fail "orphan cleanup treated Docker enumeration failure as an empty result"
  fi
  [ ! -s "$orphan_log" ] || fail "enumeration failure reached docker rm"
)

run_lifecycle_failure_tests() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/lifecycle-cfg" CRF_RUNDIR="$tmp/lifecycle-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"

  life_id1="5555555555555555555555555555555555555555555555555555555555555555"
  life_id2="6666666666666666666666666666666666666666666666666666666666666666"
  life_mode=one
  life_log="$tmp/lifecycle-mutations.log"; : > "$life_log"
  managed_names() {
    case "$life_mode" in
      enum-fail) return 1 ;;
      none) return 0 ;;
      one|inspect-fail) printf '%s\n' ci-runner-1 ;;
      two) printf '%s\n' ci-runner-1 ci-runner-2 ;;
    esac
  }
  managed_runner_snapshot() {
    [ "$life_mode" != inspect-fail ] || return 1
    case "$1" in
      ci-runner-1) printf '%s|github|runner|1|old-generation\n' "$life_id1" ;;
      ci-runner-2) printf '%s|github|runner|2|old-generation\n' "$life_id2" ;;
      *) return 1 ;;
    esac
  }
  crf_confgen() { printf '%s\n' current-generation; }
  github_remove_runner() {
    printf 'remove %s %s %s\n' "$1" "${CRF_REMOVE_ID:-missing}" "${CRF_REMOVE_PROVIDER:-missing}" >> "$life_log"
    [ "$1" != ci-runner-2 ]
  }
  docker() {
    if [ "${1:-}" = inspect ] && [ "${2:-}" = -f ]; then
      case "$3" in
        '{{.State.Status}}') printf '%s\n' exited ;;
        '{{if .State.Health}}{{.State.Health.Status}}{{end}}') printf '%s\n' healthy ;;
        *) return 1 ;;
      esac
      return 0
    fi
    return 1
  }

  life_mode=inspect-fail
  if remove_runner ci-runner-1 >/dev/null 2>&1; then
    fail "remove_runner accepted a slot whose ownership snapshot failed"
  fi
  [ ! -s "$life_log" ] || fail "failed ownership snapshot reached a provider removal adapter"

  life_mode=one
  remove_runner ci-runner-1 || fail "owned removal snapshot was rejected"
  grep -qx "remove ci-runner-1 $life_id1 github" "$life_log" \
    || fail "remove_runner did not bind immutable ID/provider into the adapter transaction"

  life_mode=enum-fail
  if count_stale_runners >/dev/null 2>&1; then
    fail "stale count treated Docker enumeration failure as zero"
  fi
  life_mode=inspect-fail
  if count_stale_runners >/dev/null 2>&1; then
    fail "stale count ignored an ownership/inspect failure"
  fi

  : > "$life_log"; life_mode=two
  if reap_dead_runners >/dev/null 2>&1; then
    fail "dead-runner reap hid a provider removal failure"
  fi
  grep -qx "remove ci-runner-1 $life_id1 github" "$life_log" \
    || fail "dead-runner reap skipped the first owned slot"
  grep -qx "remove ci-runner-2 $life_id2 github" "$life_log" \
    || fail "dead-runner reap did not aggregate the later slot failure"

  AUTOSCALE=true
  reap_dead_runners() { return 0; }
  provider_call() { return 1; }
  cmd_scale() { printf 'unsafe scale\n' >> "$life_log"; }
  : > "$life_log"
  if autoscale_tick >/dev/null 2>&1; then
    fail "autoscale accepted failed provider fleet counts"
  fi
  [ ! -s "$life_log" ] || fail "autoscale mutated capacity after count failure"

  IMAGEUPDATE_PENDING="$tmp/lifecycle-imageupdate.pending"
  printf '%s\n' ci-runner-7 > "$IMAGEUPDATE_PENDING"
  life_mode=enum-fail
  if imageupdate_rollover false >/dev/null 2>&1; then
    fail "image rollover treated fleet enumeration failure as completion"
  fi
  grep -qx ci-runner-7 "$IMAGEUPDATE_PENDING" \
    || fail "image rollover discarded pending state after enumeration failure"

  life_mode=none
  current_count() { return 1; }
  if imageupdate_rollover false >/dev/null 2>&1; then
    fail "image rollover reported completion when final fleet verification failed"
  fi
  grep -qx ci-runner-7 "$IMAGEUPDATE_PENDING" \
    || fail "image rollover cleared pending state before final verification"
)

run_reconcile_gate_tests() (
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/reconcile-cfg" CRF_RUNDIR="$tmp/reconcile-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"

  gate_log="$tmp/reconcile-gate.log"
  gate_fleet=""
  gate_enum_ok=1
  gate_token_ok=0
  gate_settings_ok=1
  managed_names() {
    [ "$gate_enum_ok" -eq 1 ] || return 1
    [ -z "$gate_fleet" ] || printf '%s\n' "$gate_fleet"
  }
  provider_token_ready() {
    printf '%s\n' token >> "$gate_log"
    [ "$gate_token_ok" -eq 1 ]
  }
  provider_token_name() { printf '%s\n' 'provider token'; }
  provider_validate_settings() {
    printf '%s\n' settings >> "$gate_log"
    [ "$gate_settings_ok" -eq 1 ]
  }
  reconcile_start() { printf '%s\n' start >> "$gate_log"; }
  NETWORK_ISOLATION=off

  : > "$gate_log"
  cmd_reconcile_config >/dev/null \
    || fail "empty farm could not save valid provider settings before credentials"
  if grep -q '^token$' "$gate_log"; then
    fail "empty-fleet settings save unnecessarily required provider credentials"
  fi
  [ "$(tr '\n' ' ' < "$gate_log")" = 'settings start ' ] \
    || fail "empty-fleet reconcile did not validate settings before launching"

  : > "$gate_log"; gate_fleet=ci-runner-1; gate_token_ok=0
  if cmd_reconcile_config >/dev/null 2>&1; then
    fail "existing-fleet reconcile launched without destination credentials"
  fi
  grep -qx token "$gate_log" || fail "existing-fleet reconcile skipped its credential check"
  if grep -q '^start$' "$gate_log"; then fail "credential failure still launched reconcile worker"; fi

  : > "$gate_log"; gate_token_ok=1; gate_settings_ok=0
  if cmd_reconcile_config >/dev/null 2>&1; then
    fail "existing-fleet reconcile launched with invalid provider settings"
  fi
  if grep -q '^start$' "$gate_log"; then fail "settings failure still launched reconcile worker"; fi

  : > "$gate_log"; gate_enum_ok=0; gate_settings_ok=1
  if cmd_reconcile_config >/dev/null 2>&1; then
    fail "config reconcile treated fleet enumeration failure as empty"
  fi
  [ ! -s "$gate_log" ] || fail "enumeration failure reached validation or worker launch"
)

run_recycle_tests
run_github_validate_test
run_log_ownership_tests
run_orphan_validation_cleanup_tests
run_lifecycle_failure_tests
run_reconcile_gate_tests
echo "ownership-safety: OK — lifecycle cleanup and mutation use verified immutable IDs and fail-closed fleet snapshots"
