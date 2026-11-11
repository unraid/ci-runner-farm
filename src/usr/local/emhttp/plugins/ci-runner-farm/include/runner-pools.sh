#!/bin/bash
# Pure runner-pool configuration helpers.
#
# Safe to source from tests. These helpers validate literal values loaded by
# the allowlisted configuration reader. They do not access Docker or GitHub.

POOL_HARD_MAX=64
POOL_MAX_COUNT=8
POOL_CONFIG_MAX_BYTES=16384
POOL_LABEL_MAX_BYTES=63
POOL_CONFIG_ERROR=""
POOL_RECORDS=""

pool_error() {
  POOL_CONFIG_ERROR="$1"
  return 1
}

pool_id_valid() {
  printf '%s' "$1" | grep -qE '^[a-z]([a-z0-9-]{0,22}[a-z0-9])?$'
}

pool_uint_valid() {
  case "$1" in
    0|[1-9]|[1-9][0-9]) [ "$1" -le "$POOL_HARD_MAX" ] ;;
    *) return 1 ;;
  esac
}

pool_positive_uint_valid() {
  pool_uint_valid "$1" && [ "$1" -gt 0 ]
}

pool_label_valid() {
  [ -n "$1" ] && [ "${#1}" -le "$POOL_LABEL_MAX_BYTES" ] \
    && printf '%s' "$1" | grep -qE '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'
}

pool_labels_normalize() {
  local raw="$1" label out="" seen="," oldifs
  case "$raw" in
    '') printf '\n'; return 0 ;;
    ','*|*','|*',,'*) return 1 ;;
  esac
  oldifs="$IFS"; IFS=','
  # shellcheck disable=SC2086 # strict comma grammar is validated above
  set -- $raw
  IFS="$oldifs"
  for label in "$@"; do
    pool_label_valid "$label" || return 1
    case "$seen" in *",$label,"*) return 1 ;; esac
    seen="${seen}${label},"
    out="${out}${out:+,}${label}"
  done
  printf '%s\n' "$out"
}

pool_cpu_valid() {
  [ "$1" = inherit ] && return 0
  printf '%s' "$1" | grep -qE '^(0\.[0-9]{1,3}|[1-9][0-9]*(\.[0-9]{1,3})?)$'
}

pool_memory_valid() {
  [ "$1" = inherit ] && return 0
  printf '%s' "$1" | grep -qiE '^[1-9][0-9]*(b|k|kb|ki|kib|m|mb|mi|mib|g|gb|gi|gib|t|tb|ti|tib)?$'
}

pool_image_valid() {
  local image="$1"
  [ "$image" = builtin ] && return 0
  [ -n "$image" ] && [ "${#image}" -le 255 ] || return 1
  case "$image" in
    -*|*[$'\r\n\t ']*|*\|*|*\;*) return 1 ;;
  esac
  printf '%s' "$image" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
}

# V3 record:
# v3|id|routing-label|additional-labels|fixed|min|max|idle|cpus|memory|image
pool_record_normalize() {
  local rec="$1" version id routing additional fixed min max idle cpus memory image extra labels oldifs
  oldifs="$IFS"; IFS='|' read -r version id routing additional fixed min max idle cpus memory image extra <<EOF
$rec
EOF
  IFS="$oldifs"
  [ "$version" = v3 ] && [ -z "${extra:-}" ] && [ -n "$image" ] || {
    pool_error "Pool '$rec' must have exactly eleven V3 fields."
    return 1
  }
  pool_id_valid "$id" || { pool_error "Pool id '$id' is invalid."; return 1; }
  case "$id" in default|invalid) pool_error "Pool id '$id' is reserved."; return 1 ;; esac
  routing="$(printf '%s' "$routing" | tr '[:upper:]' '[:lower:]')"
  pool_label_valid "$routing" || { pool_error "Pool '$id' routing label is invalid."; return 1; }
  labels="$(pool_labels_normalize "$additional")" || {
    pool_error "Pool '$id' additional labels are invalid or duplicated."
    return 1
  }
  case ",$labels," in *",$routing,"*) pool_error "Pool '$id' repeats its routing label."; return 1 ;; esac
  pool_positive_uint_valid "$fixed" || { pool_error "Pool '$id' fixed capacity is invalid."; return 1; }
  pool_uint_valid "$min" || { pool_error "Pool '$id' minimum is invalid."; return 1; }
  pool_positive_uint_valid "$max" || { pool_error "Pool '$id' maximum is invalid."; return 1; }
  pool_uint_valid "$idle" || { pool_error "Pool '$id' idle target is invalid."; return 1; }
  [ "$min" -le "$max" ] || { pool_error "Pool '$id' minimum exceeds its maximum."; return 1; }
  [ "$idle" -le "$max" ] || { pool_error "Pool '$id' idle target exceeds its maximum."; return 1; }
  cpus="$(printf '%s' "$cpus" | tr '[:upper:]' '[:lower:]')"
  memory="$(printf '%s' "$memory" | tr '[:upper:]' '[:lower:]')"
  pool_cpu_valid "$cpus" || { pool_error "Pool '$id' CPU claim is invalid."; return 1; }
  pool_memory_valid "$memory" || { pool_error "Pool '$id' memory claim is invalid."; return 1; }
  pool_image_valid "$image" || { pool_error "Pool '$id' image reference is invalid."; return 1; }
  printf 'v3|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$id" "$routing" "$labels" "$fixed" "$min" "$max" "$idle" "$cpus" "$memory" "$image"
}

# Validate one complete immutable snapshot.
# Usage: pool_config_validate <single|pools> <serialized records> <repo|org> [github|gitlab]
pool_config_validate() {
  local mode="${1:-}" raw="${2:-}" scope="${3:-}" provider="${4:-github}" rec normalized id routing image
  local count=0 sum_fixed=0 sum_max=0 ids=" " routings=" " oldifs
  POOL_CONFIG_ERROR=""
  POOL_RECORDS=""

  case "$mode" in
    single) return 0 ;;
    pools) ;;
    *) pool_error "Runner mode must be single or pools."; return 1 ;;
  esac
  if [ "$provider" = github ] && [ "$scope" != org ]; then
    pool_error "GitHub runner pools require Organization scope."
    return 1
  fi
  [ -n "$raw" ] || { pool_error "Runner pools mode requires at least one pool."; return 1; }
  [ "${#raw}" -le "$POOL_CONFIG_MAX_BYTES" ] || { pool_error "Runner pool configuration is too large."; return 1; }
  case "$raw" in
    *[$'\r\n\t']*|*\'*|*\"*|*\\*) pool_error "Runner pools contain unsupported characters."; return 1 ;;
    ';'*|*';'|*';;'*) pool_error "Runner pool entries cannot be empty."; return 1 ;;
  esac

  oldifs="$IFS"; IFS=';'
  # shellcheck disable=SC2086 # strict semicolon grammar is validated above
  set -- $raw
  IFS="$oldifs"
  [ "$#" -le "$POOL_MAX_COUNT" ] || { pool_error "At most $POOL_MAX_COUNT runner pools are supported."; return 1; }
  for rec in "$@"; do
    normalized="$(pool_record_normalize "$rec")" || return 1
    id="$(printf '%s' "$normalized" | cut -d'|' -f2)"
    routing="$(printf '%s' "$normalized" | cut -d'|' -f3)"
    image="$(printf '%s' "$normalized" | cut -d'|' -f11)"
    case "$ids" in *" $id "*) pool_error "Pool id '$id' is duplicated."; return 1 ;; esac
    case "$routings" in *" $routing "*) pool_error "Routing label '$routing' is duplicated."; return 1 ;; esac
    ids="${ids}${id} "; routings="${routings}${routing} "
    sum_fixed=$((sum_fixed + $(printf '%s' "$normalized" | cut -d'|' -f5)))
    sum_max=$((sum_max + $(printf '%s' "$normalized" | cut -d'|' -f7)))
    count=$((count + 1))
    POOL_RECORDS="${POOL_RECORDS}${POOL_RECORDS:+;}${normalized}"
    [ -n "$image" ] || return 1
  done
  [ "$count" -gt 0 ] || { pool_error "Runner pools mode requires at least one pool."; return 1; }
  [ "$sum_fixed" -le "$POOL_HARD_MAX" ] || { pool_error "Fixed capacity exceeds $POOL_HARD_MAX."; return 1; }
  [ "$sum_max" -le "$POOL_HARD_MAX" ] || { pool_error "Maximum capacity exceeds $POOL_HARD_MAX."; return 1; }
}

pool_mode_enabled() { [ "${RUNNER_MODE:-single}" = pools ]; }

pool_records() {
  pool_config_validate "${RUNNER_MODE:-single}" "${RUNNER_POOLS:-}" "${GH_SCOPE:-repo}" "${CI_PROVIDER:-github}" || return 1
  if pool_mode_enabled; then
    printf '%s\n' "$POOL_RECORDS" | tr ';' '\n'
  else
    printf 'single|default|legacy||%s|%s|%s|%s|inherit|inherit|%s\n' \
      "${RUNNER_COUNT:-4}" "${AUTOSCALE_MIN:-2}" "${AUTOSCALE_MAX:-16}" \
      "${AUTOSCALE_MIN_IDLE:-2}" "${IMAGE:-builtin}"
  fi
}

pool_record() {
  local want="$1" rec
  while IFS= read -r rec; do
    [ "$(printf '%s' "$rec" | cut -d'|' -f2)" = "$want" ] && { printf '%s\n' "$rec"; return 0; }
  done < <(pool_records)
  return 1
}

pool_field() { pool_record "$1" | cut -d'|' -f"$2"; }
pool_routing_label() { pool_field "$1" 3; }
pool_additional_labels() { pool_field "$1" 4; }
pool_fixed() { pool_field "$1" 5; }
pool_min() { pool_field "$1" 6; }
pool_max() { pool_field "$1" 7; }
pool_idle() { pool_field "$1" 8; }
pool_cpus() { pool_field "$1" 9; }
pool_memory() { pool_field "$1" 10; }
pool_image() { pool_field "$1" 11; }

pool_effective_labels() {
  local routing additional
  if [ "$1" = default ] && ! pool_mode_enabled; then printf '%s\n' "${RUNNER_LABELS:-}"; return; fi
  routing="$(pool_routing_label "$1")" || return 1
  additional="$(pool_additional_labels "$1")" || return 1
  printf '%s%s\n' "$routing" "${additional:+,$additional}"
}

# Optional execution settings stay separate from the eleven V3 capacity fields.
# Omitting a field inherits the farm setting; an explicit empty value clears it.
# Values are literal data, never shell assignments or commands.
pool_context_mounts_valid() {
  local kind="$1" value="$2" item source destination mode
  [ -n "$value" ] || return 0
  case "$value" in ' '*|*' '|*'  '*|*[$'\r\n\t']*) return 1 ;; esac
  for item in $value; do
    if [ "$kind" = cache_mounts ]; then
      [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]] || return 1
      source="${item%%:*}"; destination="${item#*:}"
      case "$source" in .|..) return 1 ;; esac
    else
      [[ "$item" =~ ^/mnt/user/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+:/mnt/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*:(ro|rw)$ ]] || return 1
      source="${item%%:*}"; destination="${item#*:}"; mode="${destination##*:}"
      destination="${destination%:*}"
      case "$source" in */./*|*/../*|*/.|*/..) return 1 ;; esac
      [ "$mode" = ro ] || [ "$mode" = rw ] || return 1
    fi
    case "$destination" in */./*|*/../*|*/.|*/..) return 1 ;; esac
  done
}

pool_context_validate() {
  local raw="${RUNNER_POOL_CONTEXTS:-}" record id entry key value seen=' ' ids=' '
  local -a records=() fields=()
  [ -n "$raw" ] || return 0
  pool_mode_enabled || { pool_error 'Pool execution contexts require named pools.'; return 1; }
  [ "${CI_PROVIDER:-github}" = github ] && [ "${GH_SCOPE:-repo}" = org ] \
    || { pool_error 'Pool execution contexts require GitHub organization scope.'; return 1; }
  [ "${#raw}" -le "$POOL_CONFIG_MAX_BYTES" ] || { pool_error 'Pool execution contexts are too large.'; return 1; }
  case "$raw" in *[$'\r\n\t']*|*\'*|*\"*|*\\*|';'*|*';'|*';;'*)
    pool_error 'Pool execution contexts contain unsupported characters.'; return 1 ;;
  esac
  IFS=';' read -r -a records <<< "$raw"
  [ "${#records[@]}" -le "$POOL_MAX_COUNT" ] || { pool_error 'Too many pool execution contexts.'; return 1; }
  for record in "${records[@]}"; do
    case "$record" in *'|'|*'||'*) pool_error 'Pool execution context has an empty field.'; return 1 ;; esac
    IFS='|' read -r -a fields <<< "$record"
    [ "${fields[0]:-}" = v1 ] && [ "${#fields[@]}" -ge 3 ] && [ "${#fields[@]}" -le 5 ] \
      || { pool_error 'Pool execution contexts require v1, a pool id and named settings.'; return 1; }
    id="${fields[1]}"
    if ! pool_id_valid "$id" || ! pool_record "$id" >/dev/null; then
      pool_error 'Pool execution context names an unknown pool.'; return 1
    fi
    case "$ids" in *" $id "*) pool_error 'Pool execution context repeats a pool.'; return 1 ;; esac
    ids="$ids$id "; seen=' '
    for entry in "${fields[@]:2}"; do
      [[ "$entry" = *=* ]] || { pool_error 'Pool execution settings require named values.'; return 1; }
      key="${entry%%=*}"; value="${entry#*=}"
      case "$seen" in *" $key "*) pool_error 'Pool execution setting is repeated.'; return 1 ;; esac
      seen="$seen$key "
      case "$key" in
        runner_group)
          [ "${CI_PROVIDER:-github}" = github ] && [ "${GH_SCOPE:-repo}" = org ] \
            || { pool_error 'Pool runner groups require GitHub organization scope.'; return 1; }
          if [ -n "$value" ]; then
            [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]{0,99}$ && "$value" != *' ' ]] \
              || { pool_error 'Invalid pool runner group.'; return 1; }
          fi ;;
        cache_mounts|user_share_mounts)
          pool_context_mounts_valid "$key" "$value" \
            || { pool_error 'Invalid pool mount setting.'; return 1; } ;;
        *) pool_error 'Unknown pool execution setting.'; return 1 ;;
      esac
    done
  done
}

pool_context_value() {
  local wanted="$1" key="$2" record entry
  local -a records=() fields=()
  IFS=';' read -r -a records <<< "${RUNNER_POOL_CONTEXTS:-}"
  for record in "${records[@]}"; do
    IFS='|' read -r -a fields <<< "$record"
    [ "${fields[1]:-}" = "$wanted" ] || continue
    for entry in "${fields[@]:2}"; do
      [ "${entry%%=*}" = "$key" ] || continue
      printf '%s' "${entry#*=}"
      return 0
    done
  done
  return 1
}

pool_configured_target() {
  if [ "${AUTOSCALE:-false}" = true ]; then pool_min "$1"; else pool_fixed "$1"; fi
}

pool_state_generation() {
  local rec
  rec="$(pool_record "$1")" || return 1
  printf '%s' "${RUNNER_MODE:-single}|${AUTOSCALE:-false}|$rec" | sha256sum | cut -c1-12
}
