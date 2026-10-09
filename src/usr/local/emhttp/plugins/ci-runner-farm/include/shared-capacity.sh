#!/bin/bash
# Native lifecycle bridge. Ansible installs this root-owned activation marker
# only after the complete host inventory has been adopted by the shared broker.
shared_capacity_enabled() {
  [ -e "$CFGDIR/shared-capacity.enabled" ] || [ -L "$CFGDIR/shared-capacity.enabled" ] && return 0
  local status=0
  shared_capacity_config_required || status=$?
  # Only positively legacy metadata may bypass admission or fenced release.
  # Removing the activation marker never removes durable broker ownership.
  [ "$status" -ne 1 ]
}

shared_capacity_config_required() {
  php -r '
    $dir="/boot/config/plugins/qa-vm-service/";
    $required=false;
    foreach (["host-policy.json","runner-integration.json"] as $name) {
      $file=$dir.$name;
      if (!file_exists($file) && !is_link($file)) continue;
      if (is_link($file) || !is_file($file) || fileowner($file)!==0 || (fileperms($file)&0022) || filesize($file)>16777216) exit(2);
      try { $document=json_decode(file_get_contents($file),true,512,JSON_THROW_ON_ERROR); }
      catch (Throwable $error) { exit(2); }
      if (!is_array($document)) exit(2);
      if ($name==="host-policy.json") {
        $required=$required || isset($document["providerConfig"]["sharedCapacity"]);
      } else {
        $required=$required || isset($document["sharedAdmission"]);
      }
    }
    exit($required ? 0 : 1);
  '
}
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
    if ($root!==$planned || !preg_match("~\\A/mnt/[A-Za-z0-9_./-]+\\z~",$root)) exit(1);
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
  [ "$CI_PROVIDER" = github ] && shared_capacity_build_pool "${CRF_POOL_ID:-default}" \
    || { err "shared capacity only supports owned GitHub build size pools"; return 1; }
  local rc
  if shared_capacity_call start "$name" "$id"; then return 0; else rc=$?; fi
  [ "$rc" -eq 76 ] || return "$rc"
  # Only the provider may authorize removal of an uncharged, never-started
  # owner. Its stable pending request survives removal and fresh creation.
  shared_capacity_call refresh-queued "$name" "$id" || return 1
  github_start_one "${name##*-}" "$name"
}

shared_capacity_prepare_release() {
  shared_capacity_enabled || return 0
  shared_capacity_call prepare-release "$1" "$2"
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

# Size classes use existing named-pool routing. The native provider attests and
# charges exact Docker limits under the single aggregate build budget.
shared_capacity_build_pool() {
  case "$1" in build) return 0 ;; build-*) pool_id_valid "$1" ;; *) return 1 ;; esac
}

# Floors and aggregate slot count belong to the protected host contract, not
# this plugin version. All three documents must describe the same policy.
shared_capacity_build_limits() {
  php -r '
    $dir="/boot/config/plugins/qa-vm-service/";
    foreach (["host-policy.json","host-plan.json","runner-integration.json"] as $name) {
      $file=$dir.$name;
      if (is_link($file) || !is_file($file) || fileowner($file)!==0 || (fileperms($file)&0022) || filesize($file)>16777216) exit(1);
      try { $documents[$name]=json_decode(file_get_contents($file),true,512,JSON_THROW_ON_ERROR); }
      catch (Throwable $error) { exit(1); }
    }
    function canonical($value) {
      if (!is_array($value)) return $value;
      foreach ($value as $key=>$item) $value[$key]=canonical($item);
      if (!array_is_list($value)) ksort($value);
      return $value;
    }
    $active=$documents["host-policy.json"]["providerConfig"]["sharedCapacity"] ?? null;
    $planned=$documents["host-plan.json"]["manifest"]["providerConfig"]["sharedCapacity"] ?? null;
    $integration=$documents["runner-integration.json"];
    if (!is_array($active) || !is_array($planned)) exit(1);
    // Go emits the optional zero overhead in signed plans. Omission has the
    // same typed value; all other differences and scalar type drift reject.
    foreach ([&$active,&$planned] as &$shared) {
      if (!array_key_exists("guestOverheadMiB",$shared)) $shared["guestOverheadMiB"]=0;
    }
    unset($shared);
    if (canonical($active)!==canonical($planned) || !($integration["sharedAdmission"]["elastic"] ?? false) ||
        canonical($integration["sharedAdmission"]["policy"] ?? null)!==canonical($active["policy"]) ||
        ($integration["buildOnly"] ?? false)!==($active["buildOnly"] ?? false)) exit(1);
    $root=$documents["host-policy.json"]["providerConfig"]["stateRoot"] ?? "";
    if ($root!==($documents["host-plan.json"]["manifest"]["providerConfig"]["stateRoot"] ?? null) ||
        ($integration["sharedAdmission"]["ledgerPath"] ?? null)!==$root."/state/shared-capacity.bolt" ||
        !preg_match("~\\A/mnt/[A-Za-z0-9_./-]+\\z~",$root)) exit(1);
    foreach (explode("/",$root) as $part) if ($part==="." || $part==="..") exit(1);
    $pool=$active["policy"]["pools"]["build"] ?? [];
    $values=[$pool["minimum"] ?? null,$pool["maximum"] ?? null,$pool["cost"]["memoryMiB"] ?? null,$pool["cost"]["vcpus"] ?? null];
    foreach ($values as $value) if (!is_int($value) || $value<1) exit(1);
    if ($values[0]>$values[1] || $values[1]>64 || $values[2]<12288 || $values[2]>16384 || $values[3]>64) exit(1);
    echo implode("|",$values);
  '
}

shared_capacity_memory_mib() {
  local value="${1,,}"
  case "$value" in
    *gib) value="${value%gib}"; printf '%s' "$((value * 1024))" ;;
    *gi) value="${value%gi}"; printf '%s' "$((value * 1024))" ;;
    *gb) value="${value%gb}"; printf '%s' "$((value * 1024))" ;;
    *g) value="${value%g}"; printf '%s' "$((value * 1024))" ;;
    *mib) printf '%s' "${value%mib}" ;;
    *mi) printf '%s' "${value%mi}" ;;
    *mb) printf '%s' "${value%mb}" ;;
    *m) printf '%s' "${value%m}" ;;
    *) return 1 ;;
  esac
}

shared_capacity_validate_pools() {
  local rec pool minimum maximum cpus memory total=0 other routing labels default_label
  local limits floor slots default_memory default_cpus os_class
  limits="$(shared_capacity_build_limits)" || return 1
  IFS='|' read -r floor slots default_memory default_cpus <<< "$limits"
  pool_record build >/dev/null || return 1
  [ "$(pool_min build)" -eq "$floor" ] || return 1
  while IFS= read -r rec; do
    IFS='|' read -r _ pool _ _ _ minimum maximum _ cpus memory _ <<< "$rec"
    shared_capacity_build_pool "$pool" || return 1
    labels="$(pool_effective_labels "$pool")" || return 1
    [ "$cpus" = inherit ] && cpus="$RUNNER_CPUS"
    [ "$memory" = inherit ] && memory="$RUNNER_MEMORY"
    printf '%s' "$cpus" | grep -qE '^[1-9][0-9]*$' || return 1
    [ -n "$memory" ] && pool_memory_valid "$memory" && [ "$memory" != inherit ] || return 1
    os_class=false
    if [ "$pool" != build ]; then
      # OS classes may share only the specialization labels, and only at or
      # above the default OS hard limits. Unsized OS jobs remain safe on them.
      case ",$(pool_effective_labels build)," in
        *,os-build,*)
          if [ "$cpus" -ge "$default_cpus" ] && [ "$(shared_capacity_memory_mib "$memory")" -ge "$default_memory" ]; then
            case ",$labels," in *,os-build,*)
              case ",$labels," in *,kvm,*)
                case ",$labels," in *,os-artifact-share,*) os_class=true ;; esac
              esac
            esac
          fi
          ;;
      esac
      while IFS= read -r default_label; do
        [ -z "$default_label" ] && continue
        # Platform labels describe every class; scheduling labels stay isolated.
        case "$default_label" in self-hosted|linux|x64) continue ;; esac
        if [ "$os_class" = true ]; then
          case "$default_label" in os-build|kvm|os-artifact-share) continue ;; esac
        fi
        case ",$labels," in *",$default_label,"*) return 1 ;; esac
      done < <(pool_effective_labels build | tr ',' '\n')
    fi
    while IFS= read -r other; do
      [ "$other" = "$pool" ] && continue
      routing="$(pool_routing_label "$other")" || return 1
      if [ "$os_class" = true ] && [ "$other" = build ] && [ "$routing" = os-build ]; then continue; fi
      case ",$labels," in *",$routing,"*) return 1 ;; esac
    done < <(pool_records | cut -d'|' -f2)
    [ "$pool" = build ] || [ "$minimum" -eq 0 ] || return 1
    if [ "${ELASTIC_POOLS:-false}" = true ]; then
      # Ceilings may overlap: native admission counts all classes against the
      # aggregate protected maximum and actual RAM/CPU, before any start.
      [ "$CI_PROVIDER" = github ] || return 1
      [ "$maximum" -le "$slots" ] || return 1
    else
      total=$((total + maximum))
      [ "$total" -le "$slots" ] || return 1
    fi
    if [ "$pool" = build ]; then
      [ "$cpus" -eq "$default_cpus" ] && [ "$(shared_capacity_memory_mib "$memory")" -eq "$default_memory" ] || return 1
    fi
  done < <(pool_records)
}
