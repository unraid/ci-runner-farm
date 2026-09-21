#!/usr/bin/env bash
# Install the currently published CI Runner Farm nightly on one or more Unraid
# hosts. The nightly descriptor is a separate CA-listed preview artifact built
# from the same source tree. It preserves the stable runtime/config contract,
# so this is a channel switch, not a second fleet installation.
set -euo pipefail

PLUGIN_URL="${NIGHTLY_PLUGIN_URL:-https://github.com/unraid/ci-runner-farm/releases/download/nightly/ci-runner-farm-nightly.plg}"
MANIFEST_URL="${NIGHTLY_MANIFEST_URL:-https://github.com/unraid/ci-runner-farm/releases/download/nightly/ci-runner-farm-nightly.json}"

usage() {
  echo "usage: ./install-nightly.sh root@unraid-host [root@unraid-host ...]" >&2
  exit 2
}

[ "$#" -gt 0 ] || usage
command -v curl >/dev/null 2>&1 || { echo "install-nightly: curl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "install-nightly: python3 is required" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "install-nightly: ssh is required" >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { echo "install-nightly: scp is required" >&2; exit 1; }

for host in "$@"; do
  case "$host" in
    root@[A-Za-z0-9]*) ;;
    *) echo "install-nightly: host must be root@ followed by a simple SSH hostname or IPv4 address: $host" >&2; exit 2 ;;
  esac
  case "${host#root@}" in
    *[!A-Za-z0-9._-]*|'') echo "install-nightly: unsafe host: $host" >&2; exit 2 ;;
  esac
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-farm-nightly.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
plugin="$tmp/ci-runner-farm-nightly.plg"
manifest="$tmp/ci-runner-farm-nightly.json"

curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
  --output "$manifest" "$MANIFEST_URL"
curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
  --output "$plugin" "$PLUGIN_URL"

python3 - "$manifest" "$plugin" "$PLUGIN_URL" <<'PY'
import hashlib
import json
import sys
import xml.etree.ElementTree as ET

manifest_path, plugin_path, expected_url = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    data = json.load(stream)
if data.get("channel") != "nightly":
    raise SystemExit("install-nightly: release manifest is not the nightly channel")
if data.get("plugin_url") != expected_url:
    raise SystemExit("install-nightly: manifest/plugin URL mismatch")
if not isinstance(data.get("commit"), str) or len(data["commit"]) != 40:
    raise SystemExit("install-nightly: manifest has no full source commit")
plugin_sha = hashlib.sha256(open(plugin_path, "rb").read()).hexdigest()
if plugin_sha != data.get("plugin_sha256"):
    raise SystemExit("install-nightly: plugin SHA-256 does not match the nightly manifest")
root = ET.parse(plugin_path).getroot()
if root.tag != "PLUGIN" or root.attrib.get("name") != "ci-runner-farm":
    raise SystemExit("install-nightly: descriptor is not the CI Runner Farm plugin")
if root.attrib.get("pluginURL") != expected_url:
    raise SystemExit("install-nightly: descriptor points at a different channel")
PY

for host in "$@"; do
  echo "[nightly] staging ${host}"
  remote_stage="$(ssh -- "$host" "umask 077; mktemp -d /tmp/ci-runner-farm-nightly.XXXXXX")"
  case "$remote_stage" in
    /tmp/ci-runner-farm-nightly.*) ;;
    *) echo "install-nightly: unsafe remote staging path from $host: $remote_stage" >&2; exit 1 ;;
  esac
  case "${remote_stage#/tmp/ci-runner-farm-nightly.}" in
    ''|*[!A-Za-z0-9]*) echo "install-nightly: unsafe remote staging path from $host: $remote_stage" >&2; exit 1 ;;
  esac
  cleanup_stage() { ssh -- "$host" "rm -rf -- '$remote_stage'" >/dev/null 2>&1 || true; }
  trap cleanup_stage EXIT HUP INT TERM
  scp -- "$plugin" "$host:$remote_stage/ci-runner-farm-nightly.plg"
  ssh -- "$host" /bin/bash -s -- "$remote_stage/ci-runner-farm-nightly.plg" <<'REMOTE'
set -euo pipefail
plugin="$1"
[ "$(id -u)" = 0 ] || { echo "install-nightly: root SSH access is required" >&2; exit 1; }
command -v installplg >/dev/null 2>&1 || { echo "install-nightly: installplg is unavailable" >&2; exit 1; }
installplg "$plugin"
REMOTE
  trap - EXIT HUP INT TERM
  ssh -- "$host" "rm -rf -- '$remote_stage'"
  echo "[nightly] installed on ${host}"
done
