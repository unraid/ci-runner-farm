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
#   * Choose the candidate whose CPUs the farm's other live containers are
#     using least. With a recent CPU usage sample (see crf_cpu_usage_rates), a
#     block scores its occupants' measured usage plus half the usage on its SMT
#     sibling CPUs, in steps of a quarter core so idle runners count as zero.
#     Ties, and every placement without a usage sample, fall back to counting
#     the cpusets that overlap the block; remaining ties go to the earliest
#     preferred block. Soft CPU admission can overcommit the host, so an
#     overcommitted runner shares the least-loaded block instead of being
#     refused. Ephemeral runners are placed again after every job, so placement
#     keeps following the load without moving running containers.
# Any problem (a missing or fractional CPU limit, a limit larger than the host,
# unreadable topology, or an unreadable container inventory) logs a warning and
# yields no cpuset, so the runner starts unpinned exactly as with pinning off.
#
# Safe to source from tests. Callers provide log() and MANAGED_LABEL.

# Upper bound for a CPU number accepted from sysfs or a container's cpuset.
CRF_CPU_NUMBER_LIMIT=8192
# A usage rate needs a sample at least this old and at most this old (ms).
CRF_CPU_USAGE_MIN_WINDOW=5000
CRF_CPU_USAGE_MAX_AGE=300000
# A new sample replaces the current one only when that one is this old (ms).
CRF_CPU_USAGE_REFRESH=10000

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

# Print "id cpuset" for every other live managed container that has a cpuset.
# A container that disappears between listing and inspection holds no CPUs.
crf_cpu_pinning_load() {
  local exclude="$1" names container line id cpuset
  names="$(docker ps -a --filter "label=${MANAGED_LABEL}" \
    --filter status=created --filter status=running --filter status=paused --filter status=restarting \
    --format '{{.Names}}')" || return 1
  for container in $names; do
    [ "$container" != "$exclude" ] || continue
    line="$(docker inspect --format '{{.Id}} {{.HostConfig.CpusetCpus}}' "$container" 2>/dev/null)" || continue
    read -r id cpuset <<< "$line"
    [[ "$id" =~ ^[0-9a-f]{64}$ ]] || continue
    [ -z "$cpuset" ] || printf '%s %s\n' "$id" "$cpuset"
  done
}

# ---- recent CPU usage of live managed containers ---------------------------
# Print "id usage_usec" for each live managed container whose cgroup v2
# cpu.stat is readable under CRF_CGROUP_ROOT (default /sys/fs/cgroup), for the
# cgroupfs and systemd Docker cgroup drivers.
crf_cpu_usage_now() {
  local root="${CRF_CGROUP_ROOT:-/sys/fs/cgroup}" ids id file usage
  ids="$(docker ps -q --no-trunc --filter "label=${MANAGED_LABEL}" \
    --filter status=running --filter status=paused --filter status=restarting)" || return 1
  for id in $ids; do
    [[ "$id" =~ ^[0-9a-f]{64}$ ]] || continue
    for file in "$root/docker/$id/cpu.stat" "$root/system.slice/docker-$id.scope/cpu.stat"; do
      [ -r "$file" ] || continue
      usage="$(awk '$1 == "usage_usec" { print $2; exit }' "$file" 2>/dev/null)"
      [[ "$usage" =~ ^[0-9]{1,18}$ ]] && printf '%s %s\n' "$id" "$usage"
      break
    done
  done
}

# Wall clock in milliseconds; whole seconds where date lacks %N.
crf_cpu_usage_clock_ms() {
  local now
  now="$(date +%s%3N 2>/dev/null)"
  [[ "$now" =~ ^[0-9]{13,16}$ ]] || now="$(date +%s)000"
  printf '%s\n' "$now"
}

# The sample files hold a millisecond timestamp line, then "id usage_usec" lines.
crf_cpu_usage_sample_age() {
  local ts now
  [ -f "$1" ] || return 1
  IFS= read -r ts < "$1" || return 1
  [[ "$ts" =~ ^[0-9]{13,16}$ ]] || return 1
  now="$(crf_cpu_usage_clock_ms)"
  [ "$ts" -le "$now" ] || return 1
  printf '%s\n' "$((now - ts))"
}

# Record a usage sample, keeping the previous one, at most every
# CRF_CPU_USAGE_REFRESH ms. The ticks call this so placement always finds a
# sample that ends a window of useful length. Takes an optional snapshot from
# crf_cpu_usage_now so a caller that already read the cgroups need not repeat it.
crf_cpu_usage_refresh() {
  local current="$RUNDIR/cpu-usage.sample" age snapshot tmp
  if age="$(crf_cpu_usage_sample_age "$current")" && [ "$age" -lt "$CRF_CPU_USAGE_REFRESH" ]; then
    return 0
  fi
  if [ "$#" -gt 0 ]; then snapshot="$1"; else snapshot="$(crf_cpu_usage_now)" || return 1; fi
  tmp="$(mktemp "$RUNDIR/cpu-usage.XXXXXX" 2>/dev/null)" || return 1
  if ! { printf '%s\n' "$(crf_cpu_usage_clock_ms)"; [ -z "$snapshot" ] || printf '%s\n' "$snapshot"; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if [ -f "$current" ]; then mv -f "$current" "$current.prev" || { rm -f "$tmp"; return 1; }; fi
  mv -f "$tmp" "$current"
}

# Print "id millicores" for the containers in snapshot $1 (from
# crf_cpu_usage_now), measured from the newest sample that is between
# CRF_CPU_USAGE_MIN_WINDOW and CRF_CPU_USAGE_MAX_AGE ms old. Returns non-zero
# when no container has a rate.
crf_cpu_usage_rates() {
  local snapshot="$1" sample age chosen="" window
  [ -n "$snapshot" ] || return 1
  for sample in "$RUNDIR/cpu-usage.sample" "$RUNDIR/cpu-usage.sample.prev"; do
    age="$(crf_cpu_usage_sample_age "$sample")" || continue
    if [ "$age" -ge "$CRF_CPU_USAGE_MIN_WINDOW" ] && [ "$age" -le "$CRF_CPU_USAGE_MAX_AGE" ]; then
      chosen="$sample"; window="$age"; break
    fi
  done
  [ -n "$chosen" ] || return 1
  # Microseconds of CPU per millisecond of wall time are thousandths of a core.
  awk -v window="$window" '
    FNR == 1 && NR == 1 { next }
    NR == FNR { then[$1] = $2; next }
    ($1 in then) && $2 >= then[$1] { printf "%s %d\n", $1, ($2 - then[$1]) / window; found = 1 }
    END { exit !found }' "$chosen" - <<< "$snapshot"
}

crf_cpu_pinning_warn() {
  log "warning: CPU pinning skipped for $1: $2; starting it unpinned" >&2
}

# Print the cpuset for container $2 with a whole-number CPU limit $1. Prints
# nothing and returns non-zero after a warning when the runner must start
# unpinned. The container's own previous cpuset never counts as load, so a
# recreated runner is placed as if its slot were free.
crf_cpu_pinning_cpuset() {
  local choice
  choice="$(crf_cpu_pinning_choose "$@")" || return 1
  printf '%s\n' "${choice%% *}"
}

# Print "cpuset millicores measured" for the block crf_cpu_pinning_cpuset would
# choose: the sibling-weighted recent CPU use of its occupants in thousandths
# of a core, and measured=1 when that use comes from a usage sample (0 when
# placement fell back to counting cpusets).
crf_cpu_pinning_choose() {
  local n="$1" name="$2" topology online candidates cpusets cpuset cpus cpu block score best="" best_score=0
  local rates="" snapshot id rate usage raw best_usage=0 best_raw=0 core size inside sibling measured=false
  local -A load=() rate_of=() cpus_of=() core_of=() core_cpus=() in_block=()
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
  while read -r id cpuset; do
    [ -n "$cpuset" ] || continue
    cpus="$(crf_cpu_list_expand "$cpuset")" || continue
    cpus_of[$id]="$cpus"
    for cpu in $cpus; do load[$cpu]=$(( ${load[$cpu]:-0} + 1 )); done
  done <<< "$cpusets"
  # Measured usage, when a recent sample covers any pinned container, ranks
  # blocks first. Without one, every block scores zero and the count decides.
  if snapshot="$(crf_cpu_usage_now 2>/dev/null)"; then
    if [ "${#cpus_of[@]}" -gt 0 ] && rates="$(crf_cpu_usage_rates "$snapshot" 2>/dev/null)"; then
      while read -r id rate; do rate_of[$id]="$rate"; done <<< "$rates"
      for id in "${!cpus_of[@]}"; do [ -z "${rate_of[$id]+x}" ] || measured=true; done
    fi
    crf_cpu_usage_refresh "$snapshot" >/dev/null 2>&1 || true
  fi
  if [ "$measured" = true ]; then
    while read -r cpu _ core; do
      core_of[$cpu]="$core"; core_cpus[$core]+="${core_cpus[$core]:+ }$cpu"
    done <<< "$topology"
  fi
  while IFS= read -r block; do
    score=0
    for cpu in $block; do score=$((score + ${load[$cpu]:-0})); done
    usage=0; raw=0
    if [ "$measured" = true ]; then
      in_block=()
      for cpu in $block; do in_block[$cpu]=1; done
      # Each container's usage is spread evenly over its own cpuset; CPUs that
      # are SMT siblings of the block, but outside it, count half. A container
      # without a rate yet (created since the sample) counts as fully busy, so
      # a burst of starts does not pile onto the few idle blocks.
      for id in "${!cpus_of[@]}"; do
        size=0; inside=0; sibling=0
        for cpu in ${cpus_of[$id]}; do
          size=$((size + 1))
          if [ -n "${in_block[$cpu]+x}" ]; then
            inside=$((inside + 1))
          elif [ -n "${core_of[$cpu]+x}" ]; then
            for core in ${core_cpus[${core_of[$cpu]}]}; do
              if [ -n "${in_block[$core]+x}" ]; then sibling=$((sibling + 1)); break; fi
            done
          fi
        done
        rate="${rate_of[$id]-$((size * 1000))}"
        usage=$((usage + (rate * inside * 2 + rate * sibling) / (size * 2)))
      done
      raw="$usage"
      usage=$(((usage + 125) / 250))
    fi
    if [ -z "$best" ] || [ "$usage" -lt "$best_usage" ] \
      || { [ "$usage" -eq "$best_usage" ] && [ "$score" -lt "$best_score" ]; }; then
      best="$block"; best_score="$score"; best_usage="$usage"; best_raw="$raw"
    fi
  done <<< "$candidates"
  printf '%s %s %s\n' "$(crf_cpu_list_compress "$best")" "$best_raw" "$([ "$measured" = true ] && echo 1 || echo 0)"
}
