#!/usr/bin/env bash
# Changelog text must remain valid XML when rendered into the plugin descriptor.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/build"
cp build-plg.sh VERSION "$tmp/build/"
cp -R src "$tmp/build/"
(
  cd "$tmp/build"
  printf '%s\n' \
    '# Changelog' \
    '## [fixture]' \
    '* Render && <parser> > output.' \
    > CHANGELOG.md
  DATE=2026.01.02.0304 BUILD_NUMBER=7 INTERNAL_VERSION=0.0.0 REPO=unraid/ci-runner-farm \
    bash ./build-plg.sh >/dev/null
  grep -qF '&amp;&amp; &lt;parser&gt; &gt; output.' ci-runner-farm.plg \
    || { echo "xml-escape: changelog text was not XML-escaped" >&2; exit 1; }
  python3 -c 'import xml.etree.ElementTree as ET; root = ET.parse("ci-runner-farm.plg").getroot(); changes = root.find("CHANGES").text or ""; assert "Render && <parser> > output." in changes'
)

echo "xml-escape: PASS"
