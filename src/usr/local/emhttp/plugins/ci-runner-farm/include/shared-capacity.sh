#!/bin/bash
# Native lifecycle bridge. Ansible installs this root-owned activation marker
# only after the complete host inventory has been adopted by the shared broker.
shared_capacity_enabled() { [ -e "$CFGDIR/shared-capacity.enabled" ] || [ -L "$CFGDIR/shared-capacity.enabled" ]; }
shared_capacity_call() { /usr/local/sbin/qa-vm-service farm-capacity "$@"; }

# Closing starts preserves running workers while adoption inventories every owner.
# Broken symlinks also close starts; an incomplete closure must fail closed.
shared_capacity_require_starts_open() {
  if [ -e "$CFGDIR/shared-capacity.closed" ] || [ -L "$CFGDIR/shared-capacity.closed" ]; then
    err "runner starts are closed for shared capacity adoption"
    return 1
  fi
}


shared_capacity_start() {
  shared_capacity_require_starts_open || return 1
  local name="$1" id="$2"
  [ "$CI_PROVIDER" = github ] && [ "${CRF_POOL_ID:-default}" = build ] \
    || { err "shared capacity only supports the owned GitHub build pool"; return 1; }
  shared_capacity_call start "$name" "$id"
}

shared_capacity_release() {
  shared_capacity_enabled || return 0
  shared_capacity_call release "$1" "$2"
}

start_owned_container() {
  shared_capacity_require_starts_open || return 1
  if ! shared_capacity_enabled; then docker start "$2"; return $?; fi
  local pool
  pool="$(runner_pool "$1")" || return 1
  pool_activate "$pool" || return 1
  shared_capacity_start "$1" "$2"
}

# Convert the adapter's complete run argv to create, preserving hard limits,
# credentials, labels and mounts. A created container consumes no workload
# budget until the broker grants it. Unknown outcomes retain the container and
# allocation for an owner-locked retry; never fall back to an ungated start.
run_owned_github_container() {
  shared_capacity_require_starts_open || return 1
  if ! shared_capacity_enabled; then docker run "${ARGS[@]}"; return $?; fi
  local name="${NAME_PREFIX}-$1" id arg
  local create_args=()
  for arg in "${ARGS[@]}"; do
    [ "$arg" = -d ] || create_args+=("$arg")
  done
  id="$(docker create "${create_args[@]}")" || return 1
  printf '%s' "$id" | grep -qE '^[0-9a-f]{64}$' \
    || { err "Docker create returned an invalid immutable runner identity"; return 1; }
  shared_capacity_start "$name" "$id"
}

# Called under the native fleet lock. Persist closure before returning so a
# daemon tick cannot launch a replacement during complete owner adoption.
cmd_admission_close() {
  local temporary
  temporary="$(mktemp "$CFGDIR/.shared-capacity.closed.XXXXXX")" || return 1
  chmod 600 "$temporary" || { rm -f "$temporary"; return 1; }
  printf '%s\n' 'closed for shared capacity adoption' > "$temporary" || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$CFGDIR/shared-capacity.closed"
}
