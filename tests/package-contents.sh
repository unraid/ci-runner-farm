#!/usr/bin/env bash
# Build in a temporary checkout fragment, validate the generated plugin XML, and
# prove the archive contains the complete runtime tree (including provider files).
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="src/usr/local/emhttp/plugins/ci-runner-farm"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/build" "$tmp/extracted"
tar -cf - build-plg.sh VERSION CHANGELOG.md "$RUNTIME" | tar -xf - -C "$tmp/build"
(
  cd "$tmp/build"
  DATE=2026.01.02.0304 BUILD_NUMBER=7 INTERNAL_VERSION=0.0.0 REPO=unraid/ci-runner-farm \
    bash ./build-plg.sh >/dev/null
  python3 -c 'import xml.etree.ElementTree as ET; ET.parse("ci-runner-farm.plg")'
  plg_md5="$(sed -n 's/^<!ENTITY packageMD5[[:space:]]*"\([0-9a-f]*\)">$/\1/p' ci-runner-farm.plg)"
  if command -v md5sum >/dev/null 2>&1; then
    tgz_md5="$(md5sum ci-runner-farm.tgz | cut -d' ' -f1)"
  else
    tgz_md5="$(md5 -q ci-runner-farm.tgz)"
  fi
  [ "${#plg_md5}" -eq 32 ] && [ "$plg_md5" = "$tgz_md5" ] || {
    echo "package-contents: generated packageMD5 ($plg_md5) does not match archive ($tgz_md5)" >&2
    exit 1
  }
  tar -xzf ci-runner-farm.tgz -C "$tmp/extracted"
)

diff -r "$RUNTIME" "$tmp/extracted" >/dev/null || {
  echo "package-contents: archive does not exactly match the runtime source tree" >&2
  diff -r "$RUNTIME" "$tmp/extracted" >&2 || true
  exit 1
}

# Validate the actual generated package-manager action, not only its source
# template: strict error handling must stop before the success banner when fleet
# stop, runtime deletion, or cached-package deletion fails.
generated_plg="$tmp/build/ci-runner-farm.plg"
remove_block="$(awk '
  /<FILE Run="\/bin\/bash" Method="remove">/ { emit=1 }
  emit { print }
  emit && /<\/FILE>/ { exit }
' "$generated_plg")"
[ -n "$remove_block" ] || {
  echo "package-contents: generated plugin has no remove action" >&2
  exit 1
}
for required_remove_line in \
  'set -euo pipefail' \
  'if ! "$PLGDIR/include/runner-farm.sh" stop' \
  'crf_bound_boot_log "$CFGDIR/boot.log"' \
  'cleanup engine is missing and Docker is unavailable' \
  'cleanup engine is missing and Docker ownership enumeration failed' \
  'cleanup engine is missing and GitLab executor ownership enumeration failed' \
  'cleanup engine is missing while plugin-owned Docker resources still exist' \
  'if ! rm -rf -- "$PLGDIR" || [ -e "$PLGDIR" ]; then' \
  'if ! rm -f -- "$CFGDIR"/ci-runner-farm-*.tgz; then'
do
  printf '%s\n' "$remove_block" | grep -qF "$required_remove_line" || {
    echo "package-contents: generated remove action is missing: $required_remove_line" >&2
    exit 1
  }
done
cleanup_line="$(printf '%s\n' "$remove_block" | grep -nF 'if ! rm -f -- "$CFGDIR"/ci-runner-farm-*.tgz' | head -1 | cut -d: -f1 || true)"
success_line="$(printf '%s\n' "$remove_block" | grep -nF 'ci-runner-farm removed. Config + credentials left' | head -1 | cut -d: -f1 || true)"
[ -n "$cleanup_line" ] && [ -n "$success_line" ] && [ "$cleanup_line" -lt "$success_line" ] || {
  echo "package-contents: generated remove action can report success before cleanup completes" >&2
  exit 1
}

for required in \
  RunnerFarm.page RunnerFarmDashboard.page RunnerFarmFleet.page RunnerFarmImage.page RunnerFarmSettings.page \
  default.cfg default.Dockerfile default.github.Dockerfile default.gitlab.Dockerfile \
  event/docker_started event/stopping_docker include/runner-farm.sh include/exec.php include/crf-core.php \
  include/boot-log.sh include/encoding.php include/providers/github.sh include/providers/gitlab.sh \
  nchan/ci_runner_farm README.md
do
  [ -f "$tmp/extracted/$required" ] || {
    echo "package-contents: required runtime file missing from archive: $required" >&2
    exit 1
  }
done

echo "package-contents: OK — generated package exactly contains the complete runtime tree"
