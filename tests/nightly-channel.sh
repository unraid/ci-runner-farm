#!/usr/bin/env bash
# Validate the moving nightly descriptor without touching canonical artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -cf - build-plg.sh VERSION CHANGELOG.md src | tar -xf - -C "$tmp"

(
  cd "$tmp"
  CHANNEL=nightly \
    DATE=2026.01.02.0304 \
    BUILD_NUMBER=7 \
    INTERNAL_VERSION=1.10.3-nightly.7 \
    NIGHTLY_SHA=0123456789abcdef0123456789abcdef01234567 \
    REPO=unraid/ci-runner-farm \
    bash ./build-plg.sh >/dev/null

  test -f ci-runner-farm-nightly.plg
  test -f ci-runner-farm-nightly.tgz
  python3 - <<'PY'
import re
import xml.etree.ElementTree as ET

text = open("ci-runner-farm-nightly.plg", encoding="utf-8").read()
root = ET.parse("ci-runner-farm-nightly.plg").getroot()
assert root.attrib["name"] == "ci-runner-farm"
assert "ci-runner-farm-nightly" in text
assert root.attrib["pluginURL"].endswith("/releases/download/nightly/ci-runner-farm-nightly.plg")
assert '<!ENTITY packageName   "ci-runner-farm-nightly.tgz">' in text
assert '<!ENTITY packageURL    "https://github.com/unraid/ci-runner-farm/releases/download/nightly/ci-runner-farm-nightly.tgz">' in text
assert "Nightly build of main commit 0123456789abcdef0123456789abcdef01234567." in text
assert "Containerized GitHub Actions runner farm for Unraid." not in text
md5 = re.search(r'^<!ENTITY packageMD5\s+"([0-9a-f]{32})">$', text, re.MULTILINE).group(1)
PY

  plg_md5="$(md5sum ci-runner-farm-nightly.tgz | cut -d' ' -f1)"
  grep -q "<!ENTITY packageMD5[[:space:]]*\"$plg_md5\">" ci-runner-farm-nightly.plg
)

grep -qF 'runs-on: [self-hosted, unraid, build]' .github/workflows/nightly.yml
grep -qF 'CHANNEL: nightly' .github/workflows/nightly.yml
grep -qF 'refs/tags/nightly' .github/workflows/nightly.yml
grep -qF 'ci-runner-farm-nightly.plg' .github/workflows/nightly.yml
grep -qF 'ci-runner-farm-nightly.tgz' .github/workflows/nightly.yml
grep -qF 'ci-runner-farm-nightly.json' .github/workflows/nightly.yml
grep -qF 'release_base="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases/download/nightly"' .github/workflows/nightly.yml
grep -qF 'contents: write' .github/workflows/nightly.yml
grep -qF 'self-hosted-runner:' .github/actionlint.yaml
grep -qF -- '- unraid' .github/actionlint.yaml
grep -qF -- '- build' .github/actionlint.yaml
grep -qF 'releases/download/nightly/' .lycheeignore
grep -qF '<Name>CI Runner Farm - Nightly</Name>' community-applications/ci-runner-farm-nightly.xml
grep -qF '<Beta>True</Beta>' community-applications/ci-runner-farm-nightly.xml
grep -qF 'releases/download/nightly/ci-runner-farm-nightly.plg' community-applications/ci-runner-farm-nightly.xml
grep -qF 'installplg' install-nightly.sh

echo "nightly-channel: OK — descriptor, package, CA entry, and farm workflow are wired"
