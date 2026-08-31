#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "dev-package: FAIL: $*" >&2
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

md5_of() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | cut -d' ' -f1
  else
    md5 -q "$1"
  fi
}

file_state() {
  if [ -f "$1" ]; then
    printf 'file:%s\n' "$(sha256_of "$1")"
  elif [ -e "$1" ]; then
    printf 'other\n'
  else
    printf 'absent\n'
  fi
}

manifest_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)[sys.argv[2]]
print(value)
PY
}

before_plg="$(file_state ci-runner-farm.plg)"
before_tgz="$(file_state ci-runner-farm.tgz)"
log="$(mktemp "${TMPDIR:-/tmp}/ci-runner-farm-dev-package.XXXXXX")"
trap 'rm -f -- "$log"' EXIT HUP INT TERM

run_dev() {
  DATE=2026.08.04.1234 \
    BUILD_NUMBER=0 \
    INTERNAL_VERSION=1.8.0 \
    bash ./build-plg.sh --dev
}

if ! tar --version 2>/dev/null | grep -qi 'gnu tar'; then
  if run_dev >"$log" 2>&1; then
    fail "--dev succeeded without GNU tar"
  fi
  grep -qi 'requires GNU tar' "$log" || fail "missing GNU tar failure message"
  [ "$(file_state ci-runner-farm.plg)" = "$before_plg" ] || fail "failed --dev changed ci-runner-farm.plg"
  [ "$(file_state ci-runner-farm.tgz)" = "$before_tgz" ] || fail "failed --dev changed ci-runner-farm.tgz"
  echo "dev-package: SKIP positive artifact checks (GNU tar unavailable; fail-closed behavior passed)"
  exit 0
fi

run_dev >"$log"
[ "$(file_state ci-runner-farm.plg)" = "$before_plg" ] || fail "--dev changed canonical ci-runner-farm.plg"
[ "$(file_state ci-runner-farm.tgz)" = "$before_tgz" ] || fail "--dev changed canonical ci-runner-farm.tgz"

out="tmp/dev-package"
manifest="$out/manifest.json"
plg="$out/ci-runner-farm.plg"
[ -f "$manifest" ] || fail "manifest.json is missing"
[ -f "$plg" ] || fail "ci-runner-farm.plg is missing"

python3 - "$manifest" <<'PY' || fail "manifest schema or serialization is invalid"
import json
import re
import sys

path = sys.argv[1]
raw = open(path, encoding="utf-8").read()
data = json.loads(raw)
keys = [
    "schema", "name", "mode", "version", "plugin_file", "package_file",
    "package_md5", "package_sha256", "source_path", "runtime_root",
]
assert list(data) == keys
assert raw == json.dumps(data, separators=(",", ":")) + "\n"
assert data["schema"] == 1
assert data["name"] == "ci-runner-farm"
assert data["mode"] == "dev"
assert data["plugin_file"] == "ci-runner-farm.plg"
assert data["runtime_root"] == "src/usr/local/emhttp/plugins/ci-runner-farm"
assert re.fullmatch(r"[0-9a-f]{32}", data["package_md5"])
assert re.fullmatch(r"[0-9a-f]{64}", data["package_sha256"])
assert re.fullmatch(
    r"2026\.08\.04\.1234\.0-1\.8\.0-jcuratec\.gitlab\.dev\.[0-9a-f]{12}",
    data["version"],
)
assert data["package_file"] == f"ci-runner-farm-jcuratec-dev-{data['version']}.tgz"
assert data["source_path"] == f"/boot/config/ci-runner-farm-dev/artifacts/{data['package_file']}"
PY

version="$(manifest_field "$manifest" version)"
package_name="$(manifest_field "$manifest" package_file)"
package_md5="$(manifest_field "$manifest" package_md5)"
package_sha="$(manifest_field "$manifest" package_sha256)"
source_path="$(manifest_field "$manifest" source_path)"
package="$out/$package_name"

[ -f "$package" ] || fail "$package_name is missing"
[ "$package_md5" = "$(md5_of "$package")" ] || fail "manifest MD5 does not match package"
[ "$package_sha" = "$(sha256_of "$package")" ] || fail "manifest SHA256 does not match package"
case "$version" in
  *"jcuratec.gitlab.dev.${package_sha:0:12}"*) ;;
  *) fail "dev version is not bound to the first 12 package SHA256 characters" ;;
esac

entry_count="$(find "$out" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
[ "$entry_count" = 3 ] || fail "dev output must contain exactly three artifacts"

python3 - "$plg" "$package_name" "$package_md5" "$package_sha" "$source_path" <<'PY' \
  || fail "development PLG contract check failed"
import re
import sys
import xml.etree.ElementTree as ET

path, package, md5, sha256, source = sys.argv[1:]
text = open(path, encoding="utf-8").read()
ET.parse(path)
assert "pluginURL" not in text
assert "packageURL" not in text
assert "<URL>" not in text
assert "base64" not in text.lower()
assert '<!ENTITY author        "j-curatec local dev">' in text
assert 'support="https://github.com/j-curatec/ci-runner-farm/issues"' in text
assert "Local development build from the j-curatec GitLab-provider working tree." in text
assert "Adds CI_PROVIDER=github|gitlab while retaining the GitHub provider." in text
assert "has no automatic update URL." in text
assert f'<!ENTITY packageName   "{package}">' in text
assert f'<FILE Name="/tmp/&packageName;">' in text
assert f'<LOCAL>{source}</LOCAL>' in text
assert f'<!ENTITY packageMD5    "{md5}">' in text
assert f'<!ENTITY packageSHA256 "{sha256}">' in text
assert '<SHA256>&packageSHA256;</SHA256>' in text
assert f'PKG="/tmp/{package}"' in text
assert f'EXPECTED_PACKAGE_SHA256="{sha256}"' in text
verify = text.index('actual_package_sha256="$(sha256sum "$PKG"')
extract = text.index('tar -xzf "$PKG"')
remove = text.index('rm -f -- "$PKG"', extract)
assert verify < extract < remove
assert 'find "$CFGDIR" -maxdepth 1 -name \'ci-runner-farm-*.tgz\'' not in text
assert 'rm -f -- "$CFGDIR"/ci-runner-farm-*.tgz' not in text
assert not re.search(r'rm\s+[^\n]*?/boot/config/ci-runner-farm-dev', text)
assert "External dev artifacts and rollback packages are installer-owned and retained." in text
PY

extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-farm-dev-extract.XXXXXX")"
mode_fixture="$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-farm-dev-modes.XXXXXX")"
trap 'rm -f -- "$log"; rm -rf -- "$extract_dir" "$mode_fixture"' EXIT HUP INT TERM
tar -xzf "$package" -C "$extract_dir"
diff -r "src/usr/local/emhttp/plugins/ci-runner-farm" "$extract_dir" >/dev/null \
  || fail "package contents differ from the runtime source tree"

# A checkout made with umask 0002 can contain group-writable files. The Linux
# check environment uses umask 0022, so the renderer must preserve source modes
# while it copies the tree or its reproducible archive hash changes.
mkdir -p "$mode_fixture"
tar -cf - build-plg.sh VERSION CHANGELOG.md src | tar -xf - -C "$mode_fixture"
chmod -R g+w "$mode_fixture"
(
  cd "$mode_fixture"
  umask 022
  DATE=2026.08.04.1234 \
    BUILD_NUMBER=0 \
    INTERNAL_VERSION=1.8.0 \
    bash ./build-plg.sh --dev >/dev/null
)
[ -f "$mode_fixture/tmp/dev-package/manifest.json" ] \
  || fail "development build failed when source files were group-writable"

while IFS= read -r entry; do
  case "$entry" in
    /*|../*|*/../*) fail "unsafe package path: $entry" ;;
  esac
  trimmed="${entry%/}"
  base="${trimmed##*/}"
  case "$base" in
    token|gitlab-runner-token|gitlab-api-token|registry-token|gitlab-ca.crt|ci-runner-farm.cfg|config.toml|config.json|.runner_system_id)
      fail "credential or persisted configuration included in package: $entry"
      ;;
  esac
done < <(tar -tzf "$package")

first_manifest_sha="$(sha256_of "$manifest")"
first_plg_sha="$(sha256_of "$plg")"
first_package_sha="$(sha256_of "$package")"
run_dev >"$log"
[ "$first_manifest_sha" = "$(sha256_of "$manifest")" ] || fail "manifest is not deterministic"
[ "$first_plg_sha" = "$(sha256_of "$plg")" ] || fail "PLG is not deterministic"
[ "$first_package_sha" = "$(sha256_of "$package")" ] || fail "package is not deterministic"
[ "$(file_state ci-runner-farm.plg)" = "$before_plg" ] || fail "second --dev changed canonical ci-runner-farm.plg"
[ "$(file_state ci-runner-farm.tgz)" = "$before_tgz" ] || fail "second --dev changed canonical ci-runner-farm.tgz"

echo "dev-package: PASS"
