#!/usr/bin/env bash
# CPU pinning placement and runner argv contract. Fake sysfs trees describe the
# host topology and a stub Docker inventory supplies the cpusets of other managed
# containers, so placement order, overcommit sharing, mixed sizes, the explicit
# unpinned fallback, and the upgrade-safe fingerprint run without a real host.
# shellcheck disable=SC2034,SC2329  # engine globals and stubs are read by sourced functions
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config"
export CRF_RUNDIR="$tmp/run"
export CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

fail() { printf 'CPU PINNING FAIL: %s\n' "$*" >&2; exit 1; }

# ---- fake sysfs ------------------------------------------------------------
# add_cpu ROOT CPU SIBLINGS L3_LIST: one CPU with SMT siblings, an L1 cache
# that must be ignored, and an optional L3 cache.
add_cpu() {
  local dir="$1/devices/system/cpu/cpu$2"
  mkdir -p "$dir/topology" "$dir/cache/index0"
  printf '%s\n' "$3" > "$dir/topology/thread_siblings_list"
  printf '0\n' > "$dir/topology/physical_package_id"
  printf '1\n' > "$dir/cache/index0/level"
  printf '%s\n' "$3" > "$dir/cache/index0/shared_cpu_list"
  if [ -n "$4" ]; then
    mkdir -p "$dir/cache/index3"
    printf '3\n' > "$dir/cache/index3/level"
    printf '%s\n' "$4" > "$dir/cache/index3/shared_cpu_list"
  fi
}

# 16 cores / 32 threads: CPU N and N+16 are SMT siblings; two L3 domains.
smt_host="$tmp/sys-smt"
mkdir -p "$smt_host/devices/system/cpu"
printf '0-31\n' > "$smt_host/devices/system/cpu/online"
for cpu in $(seq 0 31); do
  core=$((cpu % 16))
  if [ "$core" -lt 8 ]; then l3='0-7,16-23'; else l3='8-15,24-31'; fi
  add_cpu "$smt_host" "$cpu" "$core,$((core + 16))" "$l3"
done

# 8 CPUs, no SMT, one L3 domain.
flat_host="$tmp/sys-flat"
mkdir -p "$flat_host/devices/system/cpu"
printf '0-7\n' > "$flat_host/devices/system/cpu/online"
for cpu in $(seq 0 7); do add_cpu "$flat_host" "$cpu" "$cpu" '0-7'; done

# Older kernel shape: no sibling lists and no L3, two packages. Core and
# package IDs identify threads; packages stand in for cache domains.
package_host="$tmp/sys-package"
mkdir -p "$package_host/devices/system/cpu"
printf '0-3\n' > "$package_host/devices/system/cpu/online"
for cpu in 0 1 2 3; do
  mkdir -p "$package_host/devices/system/cpu/cpu$cpu/topology"
  printf '%s\n' "$((cpu % 2))" > "$package_host/devices/system/cpu/cpu$cpu/topology/core_id"
  printf '%s\n' "$((cpu / 2))" > "$package_host/devices/system/cpu/cpu$cpu/topology/physical_package_id"
done

# ---- stub Docker inventory -------------------------------------------------
# One "name status cpuset" line per container ("-" = no cpuset). The stub
# honors the label and status filters, so placement must ask for live managed
# containers only.
CONTAINERS="$tmp/containers"
DOCKER_LOG="$tmp/docker.log"
DOCKER_PS_FAIL=0
: > "$CONTAINERS"; : > "$DOCKER_LOG"
docker() {
  printf '%s\n' "$*" >> "$DOCKER_LOG"
  case "$1" in
    ps)
      [ "$DOCKER_PS_FAIL" = 0 ] || return 1
      local arg previous="" label="" statuses=" "
      for arg in "$@"; do
        if [ "$previous" = --filter ]; then
          case "$arg" in label=*) label="${arg#label=}" ;; status=*) statuses+="${arg#status=} " ;; esac
        fi
        previous="$arg"
      done
      [ "$label" = "$MANAGED_LABEL" ] || return 0
      awk -v statuses="$statuses" 'statuses == " " || index(statuses, " " $2 " ") { print $1 }' "$CONTAINERS"
      ;;
    inspect)
      [ "$2" = --format ] && [ "$3" = '{{.HostConfig.CpusetCpus}}' ] || return 1
      awk -v name="$4" '$1 == name { print ($3 == "-" ? "" : $3); found = 1 } END { exit !found }' "$CONTAINERS"
      ;;
    run) printf '%s\n' "${@:2}" > "$tmp/run.argv" ;;
    create)
      printf '%s\n' "${@:2}" > "$tmp/create.argv"
      printf '%064d\n' 0
      ;;
    *) return 1 ;;
  esac
}

# place N NAME: choose a cpuset and record NAME as a running holder of it.
place() {
  local cpuset
  cpuset="$(crf_cpu_pinning_cpuset "$1" "$2" 2>>"$tmp/warnings")" || return 1
  printf '%s running %s\n' "$2" "${cpuset:--}" >> "$CONTAINERS"
  printf '%s\n' "$cpuset"
}
expect_place() {
  local got
  got="$(place "$1" "$2")" || fail "$2 (N=$1) was not placed"
  [ "$got" = "$3" ] || fail "$2 (N=$1) placed on '$got', expected '$3'"
}
reset_host() { export CRF_SYSFS_ROOT="$1"; : > "$CONTAINERS"; : > "$tmp/warnings"; }

# ---- list helpers ------------------------------------------------------------
[ "$(crf_cpu_list_expand '0-3,8,10-11')" = '0 1 2 3 8 10 11' ] || fail "CPU list expansion changed"
[ "$(crf_cpu_list_compress '21 4 20 5 9')" = '4-5,9,20-21' ] || fail "CPU list compression changed"
for bad in '' '3-1' '1,,2' 'a' '0-3 ' '8192'; do
  if crf_cpu_list_expand "$bad" >/dev/null 2>&1; then fail "malformed CPU list '$bad' was accepted"; fi
done

# ---- 16C/32T, two L3 domains -------------------------------------------------
reset_host "$smt_host"
[ "$(crf_cpu_topology | sed -n '1p;17p')" = $'0 l3:0 0\n16 l3:0 0' ] || fail "SMT topology parse changed"
# The first four runners get distinct physical cores, alternating L3 domains.
expect_place 4 ci-runner-build-1 0-3
# A recreated runner never counts its own previous cpuset as load.
[ "$(crf_cpu_pinning_cpuset 4 ci-runner-build-1 2>/dev/null)" = 0-3 ] \
  || fail "recreated container counted its own previous cpuset"
expect_place 4 ci-runner-build-2 8-11
expect_place 4 ci-runner-build-3 4-7
expect_place 4 ci-runner-build-4 12-15
grep -q 'ps -a --filter label=net.unraid.ci-runner-farm.managed=true' "$DOCKER_LOG" \
  || fail "placement did not scope load to farm-managed containers"
# The next four use the sibling threads, again alternating domains.
expect_place 4 ci-runner-build-5 16-19
expect_place 4 ci-runner-build-6 24-27
expect_place 4 ci-runner-build-7 20-23
expect_place 4 ci-runner-build-8 28-31
# Overcommit shares the least-loaded block; ties go to the earliest preference.
expect_place 4 ci-runner-build-9 0-3
expect_place 4 ci-runner-build-10 8-11
expect_place 4 ci-runner-build-11 4-7
[ ! -s "$tmp/warnings" ] || fail "successful placement emitted warnings: $(cat "$tmp/warnings")"

# Stopped containers and unpinned containers hold no CPUs.
reset_host "$smt_host"
printf '%s\n' 'old-exited exited 0-3' 'unpinned running -' 'queued created 8-11' 'frozen paused 4-7' >> "$CONTAINERS"
expect_place 4 ci-runner-build-1 0-3
expect_place 4 ci-runner-build-2 12-15

# Mixed 2- and 4-CPU runners share one load map.
reset_host "$smt_host"
expect_place 4 ci-runner-build-1 0-3
expect_place 2 ci-runner-build-small-1 8-9
expect_place 4 ci-runner-build-2 4-7
expect_place 2 ci-runner-build-small-2 10-11
expect_place 4 ci-runner-build-3 12-15
expect_place 2 ci-runner-build-small-3 16-17

# A limit larger than any L3 domain falls back to one host-wide domain.
reset_host "$smt_host"
expect_place 20 ci-runner-build-xl-1 0-19

# ---- 8 CPUs, no SMT, one L3 ---------------------------------------------------
reset_host "$flat_host"
expect_place 2 ci-runner-1 0-1
expect_place 2 ci-runner-2 2-3
expect_place 2 ci-runner-3 4-5
expect_place 2 ci-runner-4 6-7
expect_place 2 ci-runner-5 0-1
reset_host "$flat_host"
# A trailing partial block (CPUs 6-7 for N=3) is never a candidate.
expect_place 3 ci-runner-1 0-2
expect_place 3 ci-runner-2 3-5
expect_place 3 ci-runner-3 0-2
expect_place 8 ci-runner-4 0-7

# ---- package domains from core and package IDs --------------------------------
reset_host "$package_host"
expect_place 1 ci-runner-1 0
expect_place 1 ci-runner-2 2
expect_place 1 ci-runner-3 1
expect_place 1 ci-runner-4 3

# ---- degraded paths: warn and start unpinned -------------------------------------
expect_unpinned() {
  local n="$1" reason="$2" out rc=0
  : > "$tmp/warnings"
  out="$(crf_cpu_pinning_cpuset "$n" ci-runner-7 2>"$tmp/warnings")" || rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] || fail "degraded placement ($reason) returned '$out'"
  grep -qF "warning: CPU pinning skipped for ci-runner-7: $reason; starting it unpinned" "$tmp/warnings" \
    || fail "degraded placement did not warn '$reason': $(cat "$tmp/warnings")"
}
reset_host "$tmp/missing-sysfs"
expect_unpinned 4 'the host CPU topology could not be read'
reset_host "$flat_host"
expect_unpinned 9 'the CPU limit 9 exceeds the 8 online host CPUs'
expect_unpinned 2.5 'pinning needs a whole-number CPU limit'
expect_unpinned '' 'pinning needs a whole-number CPU limit'
expect_unpinned 0 'pinning needs a whole-number CPU limit'
# Online CPUs without per-CPU topology are unreadable, not a flat host.
mkdir -p "$tmp/sys-partial/devices/system/cpu/cpu0"
printf '0-31\n' > "$tmp/sys-partial/devices/system/cpu/online"
reset_host "$tmp/sys-partial"
expect_unpinned 4 'the host CPU topology could not be read'
reset_host "$smt_host"
DOCKER_PS_FAIL=1
expect_unpinned 4 'the cpusets of other managed containers could not be read'
DOCKER_PS_FAIL=0

# ---- runner argv and fingerprint ---------------------------------------------------
# Disabled pinning must keep today's fingerprint byte-for-byte so existing
# slots are not drained on upgrade; the chosen cpuset never enters it.
reset_host "$smt_host"
CACHE_ROOT="$tmp/cache"; CACHE_MOUNTS=''; USER_SHARE_MOUNTS=''; SHARED_CACHE_ROOT=''
mkdir -p "$CACHE_ROOT"
GH_SCOPE=org; GH_OWNER='example-owner'; GH_REPOS=''; RUNNER_GROUP=''
RUNNER_LABELS='self-hosted,build'; RUNNER_CPUS='4'; RUNNER_MEMORY='8g'
IMAGE_SOURCE=builtin; IMAGE=''; WORK_TMPFS_SIZE='2g'; DIND=false; SHARE_DOCKER_SOCK=false
SHARED_IMAGE_CACHE=false; NETWORK_ISOLATION=off; EPHEMERAL=false; RUN_AS_ROOT=false; ACCESS_TOKEN=''
host() { printf 'mockhost\n'; }
runner_host_service_ipv4() { printf '192.0.2.10\n'; }
github_kvm_gid() { return 1; }
shared_capacity_enabled() { return 1; }
legacy_confgen="$(printf '%s\0' '' "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" "$RUNNER_GROUP" "$RUNNER_LABELS" \
  "$EPHEMERAL" "$RUNNER_CPUS" "$RUNNER_MEMORY" "$WORK_TMPFS_SIZE" "$CACHE_MOUNTS" \
  "$USER_SHARE_MOUNTS" \
  "$DIND" "$SHARE_DOCKER_SOCK" "$RUN_AS_ROOT" "$IMAGE_SOURCE" "$IMAGE" \
  "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" \
  "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" | sha256sum | cut -c1-12)"
[ "$CPU_PINNING" = false ] || fail "CPU pinning is not off by default"
[ "$(crf_confgen)" = "$legacy_confgen" ] || fail "disabled CPU pinning changed the runner fingerprint"
CPU_PINNING=true
enabled_confgen="$(crf_confgen)"
[ "$enabled_confgen" != "$legacy_confgen" ] || fail "enabling CPU pinning did not change the runner fingerprint"
printf '%s\n' 'other running 0-15' >> "$CONTAINERS"
[ "$(crf_confgen)" = "$enabled_confgen" ] || fail "the chosen cpuset leaked into the runner fingerprint"
RUNNER_CPUS='2.5'
[ "$(crf_confgen)" = "$(CPU_PINNING=false crf_confgen)" ] \
  || fail "pinning that cannot apply to a fractional limit changed the fingerprint"
RUNNER_CPUS='4'
: > "$CONTAINERS"

args_of() { printf '%s\n' "${ARGS[@]}"; }
CPU_PINNING=false
: > "$DOCKER_LOG"
NO_REGISTER=1 github_build_args 1 ci-runner-build-1 2>"$tmp/build.err" || fail "disabled argv build failed: $(cat "$tmp/build.err")"
args_of | grep -qx -- '--cpus=4' || fail "disabled pinning dropped --cpus"
if args_of | grep -q -- '--cpuset-cpus'; then fail "disabled pinning added --cpuset-cpus"; fi
if grep -q '^ps ' "$DOCKER_LOG"; then fail "disabled pinning inspected the container inventory"; fi
CPU_PINNING=true
NO_REGISTER=1 github_build_args 1 ci-runner-build-1 2>"$tmp/build.err" || fail "enabled argv build failed: $(cat "$tmp/build.err")"
args_of | grep -qx -- '--cpus=4' || fail "enabled pinning dropped --cpus"
args_of | grep -qx -- '--cpuset-cpus=0-3' || fail "enabled pinning did not add --cpuset-cpus=0-3"
args_of | grep -qx -- 'net.unraid.ci-runner-farm.cpuset=0-3' || fail "enabled pinning did not label the cpuset"
args_of | grep -qx -- "net.unraid.ci-runner-farm.confgen=$enabled_confgen" || fail "enabled argv carries a different fingerprint"
# Both container start paths receive the same argv.
run_owned_github_container 1 >/dev/null || fail "docker run path failed"
grep -qx -- '--cpuset-cpus=0-3' "$tmp/run.argv" || fail "docker run did not receive --cpuset-cpus"
grep -qx -- '--cpus=4' "$tmp/run.argv" || fail "docker run did not receive --cpus"
shared_capacity_enabled() { return 0; }
shared_capacity_start() { return 0; }
run_owned_github_container 1 >/dev/null || fail "shared docker create path failed"
grep -qx -- '--cpuset-cpus=0-3' "$tmp/create.argv" || fail "docker create did not receive --cpuset-cpus"
grep -qx -- '--cpus=4' "$tmp/create.argv" || fail "docker create did not receive --cpus"
shared_capacity_enabled() { return 1; }
# A fractional limit keeps the quota, warns, and starts unpinned.
RUNNER_CPUS='2.5'
NO_REGISTER=1 github_build_args 1 ci-runner-build-1 2>"$tmp/build.err" || fail "fractional argv build failed"
args_of | grep -qx -- '--cpus=2.5' || fail "fractional limit dropped --cpus"
if args_of | grep -q -- '--cpuset-cpus'; then fail "fractional limit added --cpuset-cpus"; fi
grep -qF 'warning: CPU pinning skipped for ci-runner-build-1: pinning needs a whole-number CPU limit' "$tmp/build.err" \
  || fail "fractional limit did not warn"

echo "cpu-pinning: OK — topology-aware placement, overcommit sharing, unpinned fallback, and argv/fingerprint contract"
