#!/bin/bash
# Native lifecycle bridge. Ansible installs this root-owned activation marker
# only after the complete host inventory has been adopted by the shared broker.
shared_capacity_enabled() { [ -e "$CFGDIR/shared-capacity.enabled" ] || [ -L "$CFGDIR/shared-capacity.enabled" ]; }
shared_capacity_call() { /usr/local/sbin/qa-vm-service farm-capacity "$@"; }

shared_capacity_start() {
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
