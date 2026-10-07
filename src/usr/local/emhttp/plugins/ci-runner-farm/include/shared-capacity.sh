#!/bin/bash
# Native lifecycle bridge. Ansible installs this root-owned activation marker
# only after the complete host inventory has been adopted by the shared broker.
shared_capacity_enabled() { [ -e "$CFGDIR/shared-capacity.enabled" ] || [ -L "$CFGDIR/shared-capacity.enabled" ]; }
shared_capacity_call() {
  local state_root
  state_root="$(php -r '
    $dir="/boot/config/plugins/qa-vm-service/";
    foreach (["host-policy.json","host-plan.json"] as $name) {
      $file=$dir.$name;
      if (is_link($file) || !is_file($file) || fileowner($file)!==0 || (fileperms($file)&0022) || filesize($file)>16777216) exit(1);
      $documents[$name]=json_decode(file_get_contents($file),true,512,JSON_THROW_ON_ERROR);
    }
    $root=$documents["host-policy.json"]["providerConfig"]["stateRoot"] ?? "";
    $planned=$documents["host-plan.json"]["manifest"]["providerConfig"]["stateRoot"] ?? "";
    if ($root!==$planned || !preg_match("~^/mnt/[A-Za-z0-9_./-]+$~",$root)) exit(1);
    foreach (explode("/",$root) as $part) if ($part==="." || $part==="..") exit(1);
    echo $root;
  ')" || { err "shared capacity requires a matching protected provider policy and plan"; return 1; }
  /usr/local/sbin/qa-vm-service --state-root "$state_root" farm-capacity "$@"
}

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
  local rc
  if shared_capacity_call start "$name" "$id"; then return 0; else rc=$?; fi
  [ "$rc" -eq 76 ] || return "$rc"
  # Only the provider may authorize removal of an uncharged, never-started
  # owner. Its stable pending request survives removal and fresh creation.
  shared_capacity_call refresh-queued "$name" "$id" || return 1
  github_start_one "${name##*-}" "$name"
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
  mv -f "$temporary" "$CFGDIR/shared-capacity.closed" || return 1
  sync -f "$CFGDIR"
}

# Provider coordinator verifies all owners and persists fences before opening.
cmd_shared_adopt() { shared_capacity_call adopt; }
cmd_shared_activate() { shared_capacity_call activate; }

cmd_shared_prepare() { shared_capacity_call prepare; }

# The selected repository list is public routing data, never a credential. Org
# farms normally leave GH_REPOS empty; use the reviewed paired-owner config so
# poison detection does not silently scan zero repositories in shared mode.
shared_capacity_poison_scan() {
  local configured="$GH_REPOS" repositories
  if [ -z "$configured" ]; then
    repositories="$(php -r '
      $file="/boot/config/plugins/qa-vm-service/runner-integration.json";
      if (is_link($file) || !is_file($file)) exit(1);
      $config=json_decode(file_get_contents($file),true,512,JSON_THROW_ON_ERROR);
      if (($config["organization"] ?? "") !== $argv[1]) exit(1);
      $repos=$config["runnerGroupRepositories"] ?? [];
      if (!$repos) exit(1);
      foreach ($repos as $repo) {
        if (!preg_match("~^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$~",$repo)) exit(1);
        if (explode("/",$repo)[0] !== $argv[1]) exit(1);
      }
      echo implode(" ",$repos);
    ' "$GH_OWNER")" || return 1
    GH_REPOS="$repositories"
  fi
  local rc=0
  provider_build_poison_scan || rc=$?
  GH_REPOS="$configured"
  return "$rc"
}
