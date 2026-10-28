#!/bin/bash
# Opt-in CPU pinning placement for runner containers (CPU_PINNING=true).
#
# A CPU quota (--cpus) limits how much CPU time a runner may use, but tools that
# size their parallelism from the CPU affinity mask (nproc, make -j, test and
# bundler worker pools) still see every host CPU. They start one worker per host
# CPU, and the runner then spends most scheduling periods throttled while host
# cores sit idle. Pinning the runner to a cpuset as large as its CPU limit makes
# those tools, and containers started by the runner's nested Docker daemon, see
# the right CPU count. The quota stays: capacity accounting reads each runner's
# CPU cost back from it, so pinning adds --cpuset-cpus and never replaces --cpus.
#
# Placement depends only on the host topology and the cpusets held by the
# farm's other live containers:
#   * Read online CPUs, SMT siblings, and L3 cache domains from sysfs under
#     CRF_SYSFS_ROOT (default /sys), so tests can supply a fake tree.
#   * Within each L3 domain (the CPU package when no L3 is exposed), order CPUs
#     as the first SMT thread of each core, then the remaining sibling threads,
#     and cut that order into consecutive blocks of N CPUs. A trailing partial
#     block is dropped. When no single domain can hold N CPUs, the whole host is
#     treated as one domain.
#   * Prefer blocks of first threads before blocks that include sibling threads,
#     interleaving domains block by block, so a few runners each get their own
#     physical cores spread across caches.
#   * Choose the candidate whose CPUs are least used by other managed
#     containers; ties go to the earliest preferred block. Soft CPU admission can
#     overcommit the host, so an overcommitted runner shares the least-loaded
#     block instead of being refused.
# Any problem (a missing or fractional CPU limit, a limit larger than the host,
# unreadable topology, or an unreadable container inventory) logs a warning and
# yields no cpuset, so the runner starts unpinned exactly as with pinning off.
#
# Safe to source from tests. Callers provide log() and MANAGED_LABEL.

# Upper bound for a CPU number accepted from sysfs or a container's cpuset.
CRF_CPU_NUMBER_LIMIT=8192

# Read the first line of one sysfs attribute.
crf_sysfs_read() {
  local value=""
  [ -r "$1" ] || return 1
  IFS= read -r value < "$1" || [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# Expand a kernel CPU list such as "0-3,8,10-11" into space-separated numbers.
crf_cpu_list_expand() {
  local list="$1" part low high cpu out=""
  local -a parts=()
  [[ "$list" =~ ^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$ ]] || return 1
  IFS=, read -r -a parts <<< "$list"
  for part in "${parts[@]}"; do
    low=$((10#${part%-*})); high=$((10#${part#*-}))
    [ "$low" -le "$high" ] && [ "$high" -lt "$CRF_CPU_NUMBER_LIMIT" ] || return 1
    for ((cpu = low; cpu <= high; cpu++)); do out+="${out:+ }$cpu"; done
  done
  printf '%s\n' "$out"
}

# Compress CPU numbers into a kernel CPU list, for example "4 5 20 21" -> "4-5,20-21".
crf_cpu_list_compress() {
  local cpu start="" previous="" out=""
  # shellcheck disable=SC2086  # $1 is a whitespace-separated list of integers
  for cpu in $(printf '%s\n' $1 | sort -n -u); do
    if [ -n "$start" ] && [ "$cpu" -eq $((previous + 1)) ]; then previous="$cpu"; continue; fi
    if [ -n "$start" ]; then
      out+="${out:+,}$start"; [ "$previous" = "$start" ] || out+="-$previous"
    fi
    start="$cpu"; previous="$cpu"
  done
  if [ -n "$start" ]; then
    out+="${out:+,}$start"; [ "$previous" = "$start" ] || out+="-$previous"
  fi
  printf '%s\n' "$out"
}

# Print "cpu domain core" for every online CPU. The domain is the lowest CPU of
# the CPU's L3 cache, or its package when no L3 is exposed. The core is the
# lowest CPU of its SMT sibling set, or package and core ID on older kernels.
crf_cpu_topology() {
  local base="${CRF_SYSFS_ROOT:-/sys}/devices/system/cpu" online cpus cpu dir value core package index level domain
  online="$(crf_sysfs_read "$base/online")" || return 1
  cpus="$(crf_cpu_list_expand "$online")" || return 1
  [ -n "$cpus" ] || return 1
  for cpu in $cpus; do
    dir="$base/cpu$cpu"
    if value="$(crf_sysfs_read "$dir/topology/thread_siblings_list")" \
      || value="$(crf_sysfs_read "$dir/topology/core_cpus_list")"; then
      value="$(crf_cpu_list_expand "$value")" || return 1
      core="${value%% *}"
    elif core="$(crf_sysfs_read "$dir/topology/core_id")" \
      && package="$(crf_sysfs_read "$dir/topology/physical_package_id")"; then
      [[ "$core" =~ ^[0-9]{1,9}$ && "$package" =~ ^-?[0-9]{1,9}$ ]] || return 1
      core="p${package}c${core}"
    else
      return 1
    fi
    domain=""
    for index in "$dir"/cache/index*; do
      level="$(crf_sysfs_read "$index/level")" || continue
      [ "$level" = 3 ] || continue
      value="$(crf_sysfs_read "$index/shared_cpu_list")" || return 1
      value="$(crf_cpu_list_expand "$value")" || return 1
      domain="l3:${value%% *}"
      break
    done
    if [ -z "$domain" ]; then
      package="$(crf_sysfs_read "$dir/topology/physical_package_id")" || package=0
      [[ "$package" =~ ^-?[0-9]{1,9}$ ]] || return 1
      domain="package:$package"
    fi
    printf '%s %s %s\n' "$cpu" "$domain" "$core"
  done
}

# Read "cpu domain core" lines on stdin and print every candidate block of $1
# CPUs, one space-separated block per line, most preferred first.
crf_cpu_pinning_candidates() {
  local n="$1" line cpu domain core cpu_domain rank=0 tier block_index start
  local -a lines=() domains=() ordered=() keyed=()
  local -A core_first=() domain_min=() first_thread=() tier_count=()
  mapfile -t lines
  for line in "${lines[@]}"; do
    read -r cpu domain core <<< "$line"
    if [ -z "${core_first[$core]+x}" ] || [ "$cpu" -lt "${core_first[$core]}" ]; then core_first[$core]="$cpu"; fi
    if [ -z "${domain_min[$domain]+x}" ] || [ "$cpu" -lt "${domain_min[$domain]}" ]; then domain_min[$domain]="$cpu"; fi
  done
  for core in "${!core_first[@]}"; do first_thread[${core_first[$core]}]=1; done
  mapfile -t domains < <(for domain in "${!domain_min[@]}"; do
    printf '%s %s\n' "${domain_min[$domain]}" "$domain"
  done | sort -n | cut -d' ' -f2-)
  for domain in "${domains[@]}"; do
    # First threads ascending, then the remaining sibling threads ascending.
    mapfile -t ordered < <(for line in "${lines[@]}"; do
      read -r cpu cpu_domain _ <<< "$line"
      [ "$cpu_domain" = "$domain" ] || continue
      if [ -n "${first_thread[$cpu]+x}" ]; then printf '0 %s\n' "$cpu"; else printf '1 %s\n' "$cpu"; fi
    done | sort -k1,1n -k2,2n | cut -d' ' -f2)
    tier_count=([0]=0 [1]=0)
    for ((start = 0; start + n <= ${#ordered[@]}; start += n)); do
      tier=0
      for cpu in "${ordered[@]:start:n}"; do [ -n "${first_thread[$cpu]+x}" ] || tier=1; done
      block_index="${tier_count[$tier]}"; tier_count[$tier]=$((block_index + 1))
      keyed+=("$tier $block_index $rank ${ordered[*]:start:n}")
    done
    rank=$((rank + 1))
  done
  [ "${#keyed[@]}" -gt 0 ] || return 0
  printf '%s\n' "${keyed[@]}" | sort -k1,1n -k2,2n -k3,3n | cut -d' ' -f4-
}

# Print the cpuset of every other live managed container, one per line. A
# container that disappears between listing and inspection holds no CPUs.
crf_cpu_pinning_load() {
  local exclude="$1" names container cpuset
  names="$(docker ps -a --filter "label=${MANAGED_LABEL}" \
    --filter status=created --filter status=running --filter status=paused --filter status=restarting \
    --format '{{.Names}}')" || return 1
  for container in $names; do
    [ "$container" != "$exclude" ] || continue
    cpuset="$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$container" 2>/dev/null)" || continue
    [ -z "$cpuset" ] || printf '%s\n' "$cpuset"
  done
}

crf_cpu_pinning_warn() {
  log "warning: CPU pinning skipped for $1: $2; starting it unpinned" >&2
}

# Print the cpuset for container $2 with a whole-number CPU limit $1. Prints
# nothing and returns non-zero after a warning when the runner must start
# unpinned. The container's own previous cpuset never counts as load, so a
# recreated runner is placed as if its slot were free.
crf_cpu_pinning_cpuset() {
  local n="$1" name="$2" topology online candidates cpusets cpuset cpus cpu block score best="" best_score=0
  local -A load=()
  if ! [[ "$n" =~ ^[1-9][0-9]{0,3}$ ]]; then
    crf_cpu_pinning_warn "$name" "pinning needs a whole-number CPU limit"
    return 1
  fi
  if ! topology="$(crf_cpu_topology 2>/dev/null)" || [ -z "$topology" ]; then
    crf_cpu_pinning_warn "$name" "the host CPU topology could not be read"
    return 1
  fi
  online="$(printf '%s\n' "$topology" | wc -l | tr -d ' ')"
  if [ "$n" -gt "$online" ]; then
    crf_cpu_pinning_warn "$name" "the CPU limit $n exceeds the $online online host CPUs"
    return 1
  fi
  candidates="$(printf '%s\n' "$topology" | crf_cpu_pinning_candidates "$n")"
  if [ -z "$candidates" ]; then
    candidates="$(printf '%s\n' "$topology" | awk '{ print $1, "host", $3 }' | crf_cpu_pinning_candidates "$n")"
  fi
  if [ -z "$candidates" ]; then
    crf_cpu_pinning_warn "$name" "no block of $n host CPUs is available"
    return 1
  fi
  if ! cpusets="$(crf_cpu_pinning_load "$name")"; then
    crf_cpu_pinning_warn "$name" "the cpusets of other managed containers could not be read"
    return 1
  fi
  while IFS= read -r cpuset; do
    [ -n "$cpuset" ] || continue
    cpus="$(crf_cpu_list_expand "$cpuset")" || continue
    for cpu in $cpus; do load[$cpu]=$(( ${load[$cpu]:-0} + 1 )); done
  done <<< "$cpusets"
  while IFS= read -r block; do
    score=0
    for cpu in $block; do score=$((score + ${load[$cpu]:-0})); done
    if [ -z "$best" ] || [ "$score" -lt "$best_score" ]; then best="$block"; best_score="$score"; fi
  done <<< "$candidates"
  crf_cpu_list_compress "$best"
}
