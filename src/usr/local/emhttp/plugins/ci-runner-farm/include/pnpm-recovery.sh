#!/bin/bash
# The existing fleet lock owns every pass. Jobs publish only a fixed request.
pnpm_recovery_pending() {
  local file="$CACHE_ROOT/pnpm-store/.farm-pnpm-recovery-v1"
  [ -e "$file" ] || [ -L "$file" ]
}

pnpm_recovery_root() {
  local root spec configured=false
  [ "$CI_PROVIDER" = github ] && [ "$EPHEMERAL" = true ] || {
    err 'pnpm recovery requires ephemeral GitHub runners'; return 1;
  }
  for spec in $CACHE_MOUNTS; do
    case "$spec" in pnpm-store:*) configured=true ;; esac
  done
  [ "$configured" = true ] || { err 'pnpm recovery requires the configured shared store'; return 1; }
  root="$(crf_safe_cache_root)" || return 1
  [ -d "$root/pnpm-store" ] && [ ! -L "$root/pnpm-store" ] \
    && [ "$(realpath -e "$root/pnpm-store")" = "$root/pnpm-store" ] || return 1
  printf '%s' "$root/pnpm-store"
}

# 0 healthy, 1 positively corrupt, 2 unknown. Never turn an I/O error into repair.
pnpm_recovery_integrity() {
  local store="$1" output rc=0
  [ -f "$store/v11/index.db" ] && [ ! -L "$store/v11" ] \
    && [ ! -L "$store/v11/index.db" ] || return 2
  output="$(timeout 30 sqlite3 -readonly "$store/v11/index.db" 'PRAGMA quick_check;' 2>&1)" || rc=$?
  [ "$rc" = 0 ] && [ "$output" = ok ] && return 0
  if { [ "$rc" = 0 ] && [ -n "$output" ]; } || printf '%s' "$output" | grep -Eq 'database disk image is malformed|file is not a database'; then
    return 1
  fi
  return 2
}

# Include stopped and foreign containers and ancestor binds, not just farm labels.
pnpm_recovery_references() {
  local id="$1" store="$2" mounts
  mounts="$(docker inspect -f '{{json .Mounts}}' "$id" 2>/dev/null)" || return 2
  printf '%s' "$mounts" | php -r '
    $mounts=json_decode(stream_get_contents(STDIN),true);
    if (!is_array($mounts)) exit(2);
    $store=$argv[1];
    foreach ($mounts as $mount) {
      if (!is_array($mount) || !is_string($mount["Source"]??null)) exit(2);
      if (($mount["Type"]??"")==="tmpfs") continue;
      if ($mount["Source"]==="") exit(2);
      $source=rtrim($mount["Source"],"/");
      if ($source==="" || $source===$store || str_starts_with($source,$store."/") || str_starts_with($store,$source."/")) exit(0);
    }
    exit(1);
  ' "$store"
}

pnpm_recovery_tick() {
  local store request integrity=0 names c snapshot id provider role _index _gen pool state refs=0 ids rc quarantine fresh
  store="$(pnpm_recovery_root)" || { err 'pnpm recovery: unsafe or unsupported store; preserving the start fence'; return 1; }
  request="$store/.farm-pnpm-recovery-v1"
  [ -f "$request" ] && [ ! -L "$request" ] \
    && [ "$(stat -c %s "$request")" = 20 ] \
    && [ "$(cat "$request")" = sqlite-integrity-v1 ] || {
      err 'pnpm recovery: invalid request; preserving the start fence'; return 1;
    }
  pnpm_recovery_integrity "$store" || integrity=$?
  case "$integrity" in
    0) rm -- "$request" || return 1; log 'pnpm recovery: healthy store; stale request cleared'; return 0 ;;
    1) ;;
    *) err 'pnpm recovery: integrity unavailable; preserving the store and start fence'; return 1 ;;
  esac
  names="$(managed_names)" || return 1
  for c in $names; do
    snapshot="$(managed_runner_snapshot "$c")" || return 1
    IFS='|' read -r id provider role _index _gen <<< "$snapshot"
    rc=0; pnpm_recovery_references "$id" "$store" || rc=$?
    [ "$rc" != 2 ] || return 1
    [ "$rc" = 0 ] || continue
    [ "$provider" = github ] && [ "$role" = runner ] || return 1
    state="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)" || return 1
    case "$state" in
      exited|dead|created) ;;
      running)
        # Require an actual process observation, not the log-based idle fallback.
        if ! timeout 10 docker exec "$id" sh -c 'command -v pgrep >/dev/null || exit 2; pgrep -x Runner.Worker >/dev/null; rc=$?; [ "$rc" = 1 ] && pgrep -x Runner.Listener >/dev/null'; then
          continue
        fi ;;
      *) continue ;;
    esac
    pool="$(runner_pool "$c")" || return 1
    # Reuse the native immutable removal contract; retain warm Docker data.
    (
      # Dynamic context consumed by the native provider removal functions.
      # shellcheck disable=SC2034
      local NAME_PREFIX="$BASE_NAME_PREFIX" CRF_POOL_ID="${pool:-default}"
      # shellcheck disable=SC2034
      [ -z "$pool" ] || NAME_PREFIX="${BASE_NAME_PREFIX}-${pool}"
      remove_runner "$c" false "$id" "$provider"
    ) || return 1
    # Bound each locked pass; normal daemon ticks advance the remaining drain.
    break
  done
  ids="$(docker ps -aq --no-trunc)" || return 1
  for id in $ids; do
    rc=0; pnpm_recovery_references "$id" "$store" || rc=$?
    [ "$rc" != 2 ] || return 1
    [ "$rc" != 0 ] || refs=$((refs+1))
  done
  [ "$refs" = 0 ] || { log "pnpm recovery: waiting for $refs store consumer(s); starts remain fenced"; return 75; }
  (
    # Native installs are not locked. Zero consumers is required BEFORE this lock.
    [ ! -L "$store/.actions-pnpm-initialize.lock" ] || exit 1
    exec 9>"$store/.actions-pnpm-initialize.lock" || exit 1
    flock -w 5 9 || exit 75
    integrity=0; pnpm_recovery_integrity "$store" || integrity=$?
    [ "$integrity" = 1 ] || exit 1
    # Refuse host-side SQLite users as well. Unknown diagnostics fail closed.
    command -v fuser >/dev/null || exit 1
    rc=0; fuser "$store/v11/index.db" "$store/v11/index.db-wal" "$store/v11/index.db-shm" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || exit 75
    quarantine="${store%/pnpm-store}/pnpm-quarantine"
    [ ! -L "$quarantine" ] || exit 1
    if [ ! -d "$quarantine" ]; then mkdir -m 0700 "$quarantine" || exit 1; fi
    [ "$(realpath -e "$quarantine")" = "$quarantine" ] || exit 1
    [ "$(stat -c %d "$quarantine")" = "$(stat -c %d "$store/v11")" ] || exit 1
    quarantine="$(mktemp -d "$quarantine/recovery.XXXXXXXX")" || exit 1
    fresh="$(mktemp -d "$store/.fresh.XXXXXXXX")" || exit 1
    mkdir "$fresh/files" || exit 1
    chmod --reference="$store/v11" "$fresh" || exit 1
    chown --reference="$store/v11" "$fresh" "$fresh/files" || exit 1
    # Complete tree, including WAL/SHM/CAS; no merge, deletion or corrupt rollback.
    mv -T -- "$store/v11" "$quarantine/v11" || exit 1
    if ! mv -T -- "$fresh" "$store/v11"; then
      err 'pnpm recovery: corrupt store retained; fresh publication failed; starts remain fenced'
      exit 1
    fi
    printf '%s\n' 'sqlite-integrity-v1 quarantined; fresh native store published' > "$quarantine/result" || exit 1
    rm -- "$request" || exit 1
    log "pnpm recovery: corrupt v11 quarantined at $quarantine; fresh native initialization enabled"
  )
}

cmd_recover_pnpm() {
  local store integrity=0
  store="$(pnpm_recovery_root)" || return 1
  if ! pnpm_recovery_pending; then
    pnpm_recovery_integrity "$store" || integrity=$?
    [ "$integrity" != 0 ] || { log 'pnpm recovery: store is healthy'; return 0; }
    [ "$integrity" = 1 ] || { err 'pnpm recovery: integrity unavailable'; return 1; }
    ( umask 077; set -C; printf '%s\n' sqlite-integrity-v1 > "$store/.farm-pnpm-recovery-v1" ) || return 1
  fi
  pnpm_recovery_tick
}
