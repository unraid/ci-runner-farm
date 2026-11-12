#!/usr/bin/env bash
# Build in a temporary checkout fragment, validate the generated plugin XML, and
# prove the archive contains the complete runtime tree (including provider files).
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="src/usr/local/emhttp/plugins/ci-runner-farm"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/build" "$tmp/extracted"
tar -cf - build-plg.sh go.mod go.sum cmd internal pkg VERSION CHANGELOG.md "$RUNTIME" | tar -xf - -C "$tmp/build"
(
  cd "$tmp/build"
  mkdir -p "$RUNTIME/bin"
  printf 'obsolete allocator fixture\n' > "$RUNTIME/bin/ci-runner-capacity"
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

diff -r "$tmp/build/$RUNTIME" "$tmp/extracted" >/dev/null || {
  echo "package-contents: archive does not exactly match the runtime source tree" >&2
  diff -r "$tmp/build/$RUNTIME" "$tmp/extracted" >&2 || true
  exit 1
}
diff -r --exclude=bin "$RUNTIME" "$tmp/extracted" >/dev/null
# Inspect the actual packaged executable without requiring x86 emulation on
# ARM development hosts. A shell script or a host-native Mach-O is not valid.
python3 - "$tmp/extracted/bin/ci-runner-auth" <<'PY'
import os
import struct
import sys
with open(sys.argv[1], 'rb') as handle:
    header = handle.read(64)
assert header[:6] == b'\x7fELF\x02\x01', 'authentication helper must be little-endian ELF64'
assert struct.unpack_from('<H', header, 18)[0] == 62, 'authentication helper must target amd64'
assert os.stat(sys.argv[1]).st_mode & 0o111, 'authentication helper must be executable'
PY
# Read all of the output: grep -q stops at the first match, and under pipefail
# the writer's SIGPIPE would then fail this check at random.
go version -m "$tmp/extracted/bin/ci-runner-auth" | grep -F 'go1.26.11' >/dev/null

# Execute only the generated obsolete-runtime cleanup in an isolated fixture.
# An overlay extraction must not leave the retired allocation executable callable.
python3 - "$tmp/build/ci-runner-farm.plg" "$tmp/extracted" <<'PYRETIRED'
import pathlib
import subprocess
import sys
text = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
for name in ('bin/ci-runner-capacity', 'include/shared-capacity.sh', 'include/build-demand.php'):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('obsolete fixture')
config = root / 'host-capacity.json'
config.write_text('retained policy fixture')
start = text.index('# Remove obsolete allocation runtime only;')
end = text.index('chown -R root:root', start)
subprocess.run(['bash', '-euc', 'PLGDIR="$1"\n' + text[start:end], 'retired-runtime', str(root)], check=True)
for name in ('bin/ci-runner-capacity', 'include/shared-capacity.sh', 'include/build-demand.php'):
    assert not (root / name).exists(), name
assert config.read_text() == 'retained policy fixture'
config.unlink()
assert (root / 'bin/ci-runner-auth').is_file()
PYRETIRED

# Exercise permissions from the generated install action. Archive permissions
# alone do not prove that Unraid leaves the native controller executable.
python3 - "$tmp/build/ci-runner-farm.plg" "$tmp/extracted" <<'PYMODE'
import pathlib
import subprocess
import sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.index('find "$PLGDIR" -type d -exec chmod 0755 {} +')
end = text.index('# Config defaults', start)
subprocess.run(['bash', '-euc', 'PLGDIR="$1"\n' + text[start:end], 'install-mode', sys.argv[2]], check=True)
assert pathlib.Path(sys.argv[2], 'bin/ci-runner-auth').stat().st_mode & 0o111, 'installed authentication helper must remain executable'
assert pathlib.Path(sys.argv[2], 'include/runner-job-cleanup.sh').stat().st_mode & 0o111, 'installed job hook must remain executable'
PYMODE

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
  include/runner-recommendations.sh include/runner-history.sh \
  nchan/ci_runner_farm README.md bin/ci-runner-auth
do
  [ -f "$tmp/extracted/$required" ] || {
    echo "package-contents: required runtime file missing from archive: $required" >&2
    exit 1
  }
done

echo "package-contents: OK — generated package exactly contains the complete runtime tree"
