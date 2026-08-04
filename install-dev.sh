#!/usr/bin/env bash
# Persist a `build-plg.sh --dev` bundle on a disposable Unraid development host.
# The live runtime is replaced by deploy.sh before any boot-time descriptor is
# changed.  Rollback restores only flash artifacts and deliberately requires a
# reboot instead of overlaying an old runtime onto the running system.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/tmp/dev-package"
MANIFEST="$BUNDLE_DIR/manifest.json"
PLUGIN="$BUNDLE_DIR/ci-runner-farm.plg"

usage() {
  cat >&2 <<'EOF'
usage: ./install-dev.sh root@unraid-host
       ./install-dev.sh --rollback root@unraid-host
EOF
  exit 2
}

die() { printf 'install-dev: %s\n' "$*" >&2; exit 1; }

ACTION=install
case "$#:${1:-}" in
  1:*) HOST="$1" ;;
  2:--rollback) ACTION=rollback; HOST="$2" ;;
  *) usage ;;
esac

# Keep HOST usable as one opaque ssh argument and as an scp/tar peer.  In
# particular, reject options, ports, IPv6 brackets, whitespace, and shell
# syntax.  Unraid administration for these paths must be performed as root.
case "$HOST" in
  root@[A-Za-z0-9]* ) ;;
  *) die "host must be root@ followed by a simple SSH hostname or IPv4 address" ;;
esac
case "${HOST#root@}" in
  *[!A-Za-z0-9._-]*|'') die "unsafe host: $HOST" ;;
esac

command -v ssh >/dev/null 2>&1 || die "ssh is required"

validate_bundle() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required to validate the development bundle"
  [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || die "missing regular manifest: $MANIFEST"
  [ -f "$PLUGIN" ] && [ ! -L "$PLUGIN" ] || die "missing regular plugin descriptor: $PLUGIN"

  local values
  if ! values="$(python3 - "$MANIFEST" "$PLUGIN" "$BUNDLE_DIR" <<'PY'
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

manifest_path, plugin_path, bundle_dir = sys.argv[1:]

def fail(message):
    raise SystemExit("install-dev: bundle validation failed: " + message)

try:
    with open(manifest_path, "r", encoding="utf-8") as stream:
        manifest = json.load(stream)
except (OSError, ValueError) as exc:
    fail(f"invalid manifest JSON: {exc}")

keys = {
    "schema", "name", "mode", "version", "plugin_file", "package_file",
    "package_md5", "package_sha256", "source_path", "runtime_root",
}
if not isinstance(manifest, dict) or set(manifest) != keys:
    fail("manifest fields do not exactly match schema 1")
if type(manifest["schema"]) is not int or manifest["schema"] != 1:
    fail("schema must be integer 1")
for key in keys - {"schema"}:
    if not isinstance(manifest[key], str):
        fail(f"{key} must be a string")
if manifest["name"] != "ci-runner-farm" or manifest["mode"] != "dev":
    fail("manifest is not a ci-runner-farm development bundle")
if manifest["plugin_file"] != "ci-runner-farm.plg":
    fail("unexpected plugin_file")
if manifest["runtime_root"] != "src/usr/local/emhttp/plugins/ci-runner-farm":
    fail("unexpected runtime_root")
if not re.fullmatch(r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}\.[0-9]+-[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", manifest["version"]):
    fail("unsafe external version")
expected_package = f'ci-runner-farm-jcuratec-dev-{manifest["version"]}.tgz'
if manifest["package_file"] != expected_package or os.path.basename(expected_package) != expected_package:
    fail("package_file does not match the external version")
if not re.fullmatch(r"[0-9a-f]{32}", manifest["package_md5"]):
    fail("package_md5 must be lowercase hexadecimal")
if not re.fullmatch(r"[0-9a-f]{64}", manifest["package_sha256"]):
    fail("package_sha256 must be lowercase hexadecimal")
expected_source = "/boot/config/ci-runner-farm-dev/artifacts/" + expected_package
if manifest["source_path"] != expected_source:
    fail("source_path is outside the dedicated development artifact directory")

package_path = os.path.join(bundle_dir, expected_package)
if not os.path.isfile(package_path) or os.path.islink(package_path):
    fail("versioned package is missing, non-regular, or a symlink")

def digest(path, algorithm):
    value = hashlib.new(algorithm)
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

if digest(package_path, "md5") != manifest["package_md5"]:
    fail("package MD5 does not match the manifest")
if digest(package_path, "sha256") != manifest["package_sha256"]:
    fail("package SHA-256 does not match the manifest")

try:
    tree = ET.parse(plugin_path)
except (OSError, ET.ParseError) as exc:
    fail(f"invalid plugin XML: {exc}")
root = tree.getroot()
if root.tag != "PLUGIN" or root.attrib.get("name") != manifest["name"]:
    fail("plugin root/name does not match the manifest")
if root.attrib.get("version") != manifest["version"]:
    fail("plugin version does not match the manifest")
package_nodes = [node for node in root.findall("FILE") if "Name" in node.attrib]
if len(package_nodes) != 1:
    fail("plugin must contain exactly one named package FILE")
node = package_nodes[0]
if node.attrib.get("Name") != "/tmp/" + manifest["package_file"]:
    fail("plugin package FILE does not use the isolated temporary destination")
local_node = node.find("LOCAL")
if local_node is None or (local_node.text or "").strip() != manifest["source_path"]:
    fail("plugin package LOCAL source does not match manifest source_path")
md5_node = node.find("MD5")
if md5_node is None or (md5_node.text or "").strip() != manifest["package_md5"]:
    fail("plugin package MD5 does not match the manifest")
sha_node = node.find("SHA256")
if sha_node is None or (sha_node.text or "").strip() != manifest["package_sha256"]:
    fail("plugin package SHA-256 does not match the manifest")

raw = open(plugin_path, "r", encoding="utf-8").read()
for entity, expected in (
    ("version", manifest["version"]),
    ("packageName", manifest["package_file"]),
    ("packageMD5", manifest["package_md5"]),
):
    matches = re.findall(rf'^<!ENTITY {entity}[ \t]+"([^"]*)">$', raw, re.MULTILINE)
    if matches != [expected]:
        fail(f"plugin {entity} entity is missing or ambiguous")

print("\t".join((
    manifest["package_file"], manifest["package_sha256"],
    digest(plugin_path, "sha256"), digest(manifest_path, "sha256"),
)))
PY
)"; then
    exit 1
  fi
  IFS=$'\t' read -r PACKAGE_FILE PACKAGE_SHA256 PLUGIN_SHA256 MANIFEST_SHA256 <<< "$values"
  [ -n "$PACKAGE_FILE" ] && [ -n "$PACKAGE_SHA256" ] && [ -n "$PLUGIN_SHA256" ] && [ -n "$MANIFEST_SHA256" ] \
    || die "bundle validator returned an incomplete result"
  PACKAGE="$BUNDLE_DIR/$PACKAGE_FILE"
}

if [ "$ACTION" = install ]; then
  validate_bundle

  # This is intentionally the first remote mutation.  deploy.sh holds the
  # engine lock, proves every fleet resource inactive, and swaps the live tree
  # atomically.  A failure must leave flash persistence untouched.
  bash "$SCRIPT_DIR/deploy.sh" "$HOST"

  REMOTE_STAGE="$(ssh -- "$HOST" "umask 077; mktemp -d /tmp/ci-runner-farm-dev.XXXXXX")" \
    || die "could not create remote upload directory"
  case "$REMOTE_STAGE" in
    /tmp/ci-runner-farm-dev.* ) ;;
    *) die "remote host returned an unsafe upload directory" ;;
  esac
  case "${REMOTE_STAGE#/tmp/ci-runner-farm-dev.}" in
    ''|*[!A-Za-z0-9]*) die "remote host returned an unsafe upload directory" ;;
  esac
  cleanup_stage() {
    ssh -- "$HOST" "rm -rf -- '$REMOTE_STAGE'" >/dev/null 2>&1 || true
  }
  trap cleanup_stage EXIT HUP INT TERM

  tar -C "$BUNDLE_DIR" -cf - manifest.json ci-runner-farm.plg "$PACKAGE_FILE" \
    | ssh -- "$HOST" "tar -xf - -C '$REMOTE_STAGE'"

  ssh -- "$HOST" /bin/bash -s -- \
    "$REMOTE_STAGE" "$PACKAGE_FILE" "$PACKAGE_SHA256" "$PLUGIN_SHA256" "$MANIFEST_SHA256" <<'REMOTE_INSTALL'
set -euo pipefail
stage="$1"
package_name="$2"
package_sha256="$3"
plugin_sha256="$4"
manifest_sha256="$5"

fail() { printf 'install-dev remote: %s\n' "$*" >&2; exit 1; }
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
entity_value() {
  local file="$1" entity="$2" values count
  values="$(sed -n "s/^<!ENTITY ${entity}[[:space:]]*\"\([^\"]*\)\">$/\\1/p" "$file")"
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$values"
}
regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

case "$stage" in /tmp/ci-runner-farm-dev.*) ;; *) fail "unsafe upload directory" ;; esac
case "${stage#/tmp/ci-runner-farm-dev.}" in ''|*[!A-Za-z0-9]*) fail "unsafe upload directory" ;; esac
case "$package_name" in ci-runner-farm-*.tgz) ;; *) fail "unsafe package basename" ;; esac
case "$package_name" in *[!A-Za-z0-9._-]*) fail "unsafe package basename" ;; esac
case "$package_sha256:$plugin_sha256:$manifest_sha256" in
  *[!0-9a-f:]* ) fail "unsafe SHA-256 argument" ;;
esac
[ "${#package_sha256}" = 64 ] && [ "${#plugin_sha256}" = 64 ] && [ "${#manifest_sha256}" = 64 ] \
  || fail "invalid SHA-256 length"
[ "$(id -u)" = 0 ] || fail "root SSH access is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is unavailable"
command -v flock >/dev/null 2>&1 || fail "flock is unavailable"

uploaded_package="$stage/$package_name"
uploaded_plugin="$stage/ci-runner-farm.plg"
uploaded_manifest="$stage/manifest.json"
for uploaded in "$uploaded_package" "$uploaded_plugin" "$uploaded_manifest"; do
  regular_file "$uploaded" || fail "uploaded bundle contains a missing, non-regular, or symlinked file"
done
[ "$(sha256_of "$uploaded_package")" = "$package_sha256" ] || fail "uploaded package SHA-256 mismatch"
[ "$(sha256_of "$uploaded_plugin")" = "$plugin_sha256" ] || fail "uploaded plugin SHA-256 mismatch"
[ "$(sha256_of "$uploaded_manifest")" = "$manifest_sha256" ] || fail "uploaded manifest SHA-256 mismatch"

canonical_plg=/boot/config/plugins/ci-runner-farm.plg
canonical_cfg=/boot/config/plugins/ci-runner-farm
dev_root=/boot/config/ci-runner-farm-dev
rollback="$dev_root/rollback"
artifacts="$dev_root/artifacts"
umask 077
mkdir -p "$dev_root"
[ -d "$dev_root" ] && [ ! -L "$dev_root" ] || fail "development state root is unsafe"
chmod 0700 "$dev_root"
exec 9>"$dev_root/transaction.lock"
flock -w 20 9 || fail "another development install/rollback transaction is active"

validate_baseline() {
  [ -d "$rollback" ] && [ ! -L "$rollback" ] || fail "rollback baseline is not a regular directory"
  [ "$(stat -c '%a' "$rollback")" = 700 ] || fail "rollback baseline mode is not 0700"
  regular_file "$rollback/state" || fail "rollback baseline state is missing or unsafe"
  local state name expected actual
  state="$(cat "$rollback/state")"
  case "$state" in
    absent)
      [ ! -e "$rollback/ci-runner-farm.plg" ] && [ ! -L "$rollback/ci-runner-farm.plg" ] \
        || fail "absent baseline unexpectedly contains a descriptor"
      ;;
    present)
      regular_file "$rollback/ci-runner-farm.plg" || fail "baseline descriptor is missing or unsafe"
      regular_file "$rollback/package-name" || fail "baseline package name is missing or unsafe"
      regular_file "$rollback/descriptor.sha256" || fail "baseline descriptor hash is missing or unsafe"
      regular_file "$rollback/package.sha256" || fail "baseline package hash is missing or unsafe"
      name="$(cat "$rollback/package-name")"
      case "$name" in ci-runner-farm-*.tgz) ;; *) fail "baseline package name is unsafe" ;; esac
      case "$name" in */*|*' '*) fail "baseline package name is unsafe" ;; esac
      regular_file "$rollback/packages/$name" || fail "baseline package is missing or unsafe"
      [ "$(entity_value "$rollback/ci-runner-farm.plg" packageName)" = "$name" ] \
        || fail "baseline descriptor/package mismatch"
      expected="$(cat "$rollback/descriptor.sha256")"; actual="$(sha256_of "$rollback/ci-runner-farm.plg")"
      [ "$expected" = "$actual" ] || fail "baseline descriptor hash mismatch"
      expected="$(cat "$rollback/package.sha256")"; actual="$(sha256_of "$rollback/packages/$name")"
      [ "$expected" = "$actual" ] || fail "baseline package hash mismatch"
      ;;
    *) fail "rollback baseline state is ambiguous" ;;
  esac
}

if [ -e "$rollback" ] || [ -L "$rollback" ]; then
  validate_baseline
else
  rollback_tmp="$(mktemp -d "$dev_root/.rollback.XXXXXX")"
  chmod 0700 "$rollback_tmp"
  if [ -e "$canonical_plg" ] || [ -L "$canonical_plg" ]; then
    regular_file "$canonical_plg" || fail "canonical plugin descriptor is not a regular file"
    baseline_name="$(entity_value "$canonical_plg" packageName)" \
      || fail "canonical plugin packageName is missing or ambiguous"
    case "$baseline_name" in ci-runner-farm-*.tgz) ;; *) fail "canonical package name is unsafe" ;; esac
    case "$baseline_name" in */*|*' '*) fail "canonical package name is unsafe" ;; esac
    baseline_package="$canonical_cfg/$baseline_name"
    regular_file "$baseline_package" \
      || fail "canonical descriptor's exact cached package is unavailable; refusing an incomplete baseline"
    mkdir "$rollback_tmp/packages"
    cp -- "$canonical_plg" "$rollback_tmp/ci-runner-farm.plg"
    cp -- "$baseline_package" "$rollback_tmp/packages/$baseline_name"
    printf '%s\n' present >"$rollback_tmp/state"
    printf '%s\n' "$baseline_name" >"$rollback_tmp/package-name"
    sha256_of "$rollback_tmp/ci-runner-farm.plg" >"$rollback_tmp/descriptor.sha256"
    sha256_of "$rollback_tmp/packages/$baseline_name" >"$rollback_tmp/package.sha256"
  else
    printf '%s\n' absent >"$rollback_tmp/state"
  fi
  find "$rollback_tmp" -type d -exec chmod 0700 {} +
  find "$rollback_tmp" -type f -exec chmod 0600 {} +
  mv -- "$rollback_tmp" "$rollback"
  validate_baseline
fi

# If a baseline already existed, refuse to replace an unrelated descriptor.
# A recognized development descriptor must exactly match one of the immutable
# copies retained beside its externally persisted package.
known_dev_descriptor() {
  local current_sha candidate
  regular_file "$canonical_plg" || return 1
  current_sha="$(sha256_of "$canonical_plg")"
  [ -d "$artifacts" ] && [ ! -L "$artifacts" ] || return 1
  for candidate in "$artifacts"/ci-runner-farm-*.plg; do
    regular_file "$candidate" || continue
    [ "$(sha256_of "$candidate")" = "$current_sha" ] && return 0
  done
  return 1
}

baseline_state="$(cat "$rollback/state")"
if [ -e "$canonical_plg" ] || [ -L "$canonical_plg" ]; then
  regular_file "$canonical_plg" || fail "canonical plugin descriptor is unsafe"
  if [ "$baseline_state" = present ] \
     && [ "$(sha256_of "$canonical_plg")" = "$(cat "$rollback/descriptor.sha256")" ]; then
    :
  elif known_dev_descriptor; then
    :
  else
    fail "canonical descriptor is neither the baseline nor a retained development descriptor"
  fi
elif [ "$baseline_state" != absent ]; then
  fail "canonical descriptor disappeared after a present baseline was recorded"
fi

if [ -e "$artifacts" ] || [ -L "$artifacts" ]; then
  [ -d "$artifacts" ] && [ ! -L "$artifacts" ] || fail "development artifact directory is unsafe"
else
  mkdir "$artifacts"
fi
chmod 0700 "$artifacts"

commit_artifact() {
  local source="$1" destination="$2" expected="$3" tmp
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    regular_file "$destination" || fail "artifact destination is unsafe: $destination"
    [ "$(sha256_of "$destination")" = "$expected" ] \
      || fail "artifact basename already exists with different bytes: $destination"
    return 0
  fi
  tmp="$(mktemp "$artifacts/.commit.XXXXXX")"
  cp -- "$source" "$tmp"
  chmod 0600 "$tmp"
  [ "$(sha256_of "$tmp")" = "$expected" ] || fail "artifact changed during commit"
  mv -- "$tmp" "$destination"
  [ "$(sha256_of "$destination")" = "$expected" ] || fail "committed artifact verification failed"
}

# The package is the boot-time source and therefore commits first.  The
# retained descriptor/manifest are provenance records; the canonical plugin
# descriptor is not changed until plugin install succeeds below.
commit_artifact "$uploaded_package" "$artifacts/$package_name" "$package_sha256"
dev_plugin_name="${package_name%.tgz}.plg"
dev_manifest_name="${package_name%.tgz}.manifest.json"
commit_artifact "$uploaded_plugin" "$artifacts/$dev_plugin_name" "$plugin_sha256"
commit_artifact "$uploaded_manifest" "$artifacts/$dev_manifest_name" "$manifest_sha256"

command -v plugin >/dev/null 2>&1 || fail "Unraid plugin command is unavailable"
plugin install "$uploaded_plugin"

regular_file "$canonical_plg" || fail "plugin install did not persist the canonical descriptor"
[ "$(sha256_of "$canonical_plg")" = "$plugin_sha256" ] \
  || fail "canonical descriptor verification failed after plugin install"
[ "$(sha256_of "$artifacts/$package_name")" = "$package_sha256" ] \
  || fail "external development package changed during plugin install"
printf 'install-dev remote: development descriptor installed; rollback baseline retained at %s\n' "$rollback"
REMOTE_INSTALL

  trap - EXIT HUP INT TERM
  cleanup_stage
  printf 'install-dev: development bundle installed on %s\n' "$HOST"
  exit 0
fi

# Rollback intentionally operates entirely from the verified flash baseline.
# It never installs or overlays the baseline's old runtime.
ssh -- "$HOST" /bin/bash -s <<'REMOTE_ROLLBACK'
set -euo pipefail
fail() { printf 'install-dev remote: %s\n' "$*" >&2; exit 1; }
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
entity_value() {
  local file="$1" entity="$2" values count
  values="$(sed -n "s/^<!ENTITY ${entity}[[:space:]]*\"\([^\"]*\)\">$/\\1/p" "$file")"
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$values"
}
[ "$(id -u)" = 0 ] || fail "root SSH access is required"
command -v docker >/dev/null 2>&1 || fail "Docker is unavailable"
command -v flock >/dev/null 2>&1 || fail "flock is unavailable"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is unavailable"

canonical_plg=/boot/config/plugins/ci-runner-farm.plg
canonical_cfg=/boot/config/plugins/ci-runner-farm
dev_root=/boot/config/ci-runner-farm-dev
rollback="$dev_root/rollback"
artifacts="$dev_root/artifacts"
engine=/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
regular_file "$engine" && [ -x "$engine" ] || fail "current cleanup engine is unavailable or unsafe"

# Stop through the currently deployed engine.  Suppress its potentially broad
# diagnostics rather than risk echoing credentials supplied by an external
# command; the engine's own restricted boot log remains available on the host.
if ! "$engine" stop >/dev/null 2>&1; then
  fail "current engine Stop failed; no rollback files were changed"
fi

rundir=/var/local/emhttp/ci-runner-farm
if ! mkdir -p "$rundir" 2>/dev/null; then
  rundir=/boot/config/plugins/ci-runner-farm
  mkdir -p "$rundir" || fail "cannot create the fleet lock directory"
fi
exec 8>"$rundir/fleet.lock"
flock -w 20 8 || fail "fleet is busy after Stop"

docker_names() {
  local description="$1"; shift
  local names
  names="$(docker ps -a "$@" --format '{{.Names}}' 2>/dev/null)" \
    || fail "cannot enumerate $description"
  [ -z "$names" ] || fail "$description remain after Stop"
}
docker_names "runner managers" \
  --filter 'label=net.unraid.ci-runner-farm.managed=true'
docker_names "GitLab DinD sidecars" \
  --filter 'label=net.unraid.ci-runner-farm.sidecar=true' \
  --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
  --filter 'label=net.unraid.ci-runner-farm.role=dind'
docker_names "GitLab host-socket jobs/helpers/services" \
  --filter 'label=com.gitlab.gitlab-runner.managed=true' \
  --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
  --filter 'label=net.unraid.ci-runner-farm.slot'
docker_names "registry mirrors" \
  --filter 'label=net.unraid.ci-runner-farm.resource=true' \
  --filter 'label=net.unraid.ci-runner-farm.role=mirror'
docker_names "GitHub validation containers" \
  --filter 'label=net.unraid.ci-runner-farm.managed=true' \
  --filter 'label=net.unraid.ci-runner-farm.provider=github' \
  --filter 'label=net.unraid.ci-runner-farm.role=validate'
docker_names "GitLab validation jobs" \
  --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' \
  --filter 'label=net.unraid.ci-runner-farm.role=validate-job' \
  --filter 'label=net.unraid.ci-runner-farm.slot'
all_names="$(docker ps -a --format '{{.Names}}' 2>/dev/null)" \
  || fail "cannot enumerate Docker names for legacy mirror verification"
if printf '%s\n' "$all_names" | grep -qxF ci-runner-mirror; then
  fail "fixed-name registry mirror remains after Stop"
fi
daemon_status=0
pgrep -f '[r]unner-farm.sh (autoscale-daemon|imageupdate-daemon|reconcile-drain|boot-autostart)' >/dev/null 2>&1 \
  || daemon_status=$?
case "$daemon_status" in
  0) fail "CI Runner Farm background daemon remains after Stop" ;;
  1) ;;
  *) fail "cannot verify CI Runner Farm background daemon state" ;;
esac

[ -d "$rollback" ] && [ ! -L "$rollback" ] || fail "rollback baseline is unavailable or unsafe"
[ "$(stat -c '%a' "$rollback")" = 700 ] || fail "rollback baseline mode is not 0700"
regular_file "$rollback/state" || fail "rollback baseline state is unavailable or unsafe"
state="$(cat "$rollback/state")"
case "$state" in absent|present) ;; *) fail "rollback baseline state is ambiguous" ;; esac

known_dev_descriptor() {
  local current_sha candidate
  regular_file "$canonical_plg" || return 1
  current_sha="$(sha256_of "$canonical_plg")"
  [ -d "$artifacts" ] && [ ! -L "$artifacts" ] || return 1
  for candidate in "$artifacts"/ci-runner-farm-*.plg; do
    regular_file "$candidate" || continue
    [ "$(sha256_of "$candidate")" = "$current_sha" ] && return 0
  done
  return 1
}

baseline_name=
baseline_descriptor_sha=
baseline_package_sha=
if [ "$state" = present ]; then
  regular_file "$rollback/ci-runner-farm.plg" || fail "baseline descriptor is unavailable or unsafe"
  regular_file "$rollback/package-name" || fail "baseline package name is unavailable or unsafe"
  regular_file "$rollback/descriptor.sha256" || fail "baseline descriptor hash is unavailable or unsafe"
  regular_file "$rollback/package.sha256" || fail "baseline package hash is unavailable or unsafe"
  baseline_name="$(cat "$rollback/package-name")"
  case "$baseline_name" in ci-runner-farm-*.tgz) ;; *) fail "baseline package name is unsafe" ;; esac
  case "$baseline_name" in */*|*' '*) fail "baseline package name is unsafe" ;; esac
  regular_file "$rollback/packages/$baseline_name" || fail "baseline package is unavailable or unsafe"
  [ "$(entity_value "$rollback/ci-runner-farm.plg" packageName)" = "$baseline_name" ] \
    || fail "baseline descriptor/package mismatch"
  baseline_descriptor_sha="$(cat "$rollback/descriptor.sha256")"
  baseline_package_sha="$(cat "$rollback/package.sha256")"
  [ "$(sha256_of "$rollback/ci-runner-farm.plg")" = "$baseline_descriptor_sha" ] \
    || fail "baseline descriptor hash mismatch"
  [ "$(sha256_of "$rollback/packages/$baseline_name")" = "$baseline_package_sha" ] \
    || fail "baseline package hash mismatch"
fi

if [ "$state" = present ]; then
  if regular_file "$canonical_plg" \
     && [ "$(sha256_of "$canonical_plg")" = "$baseline_descriptor_sha" ]; then
    : # Idempotent rollback after a previous successful restore.
  elif known_dev_descriptor; then
    mkdir -p "$canonical_cfg"
    destination="$canonical_cfg/$baseline_name"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      regular_file "$destination" || fail "canonical baseline package destination is unsafe"
      [ "$(sha256_of "$destination")" = "$baseline_package_sha" ] \
        || fail "canonical baseline package basename contains different bytes"
    else
      package_tmp="$(mktemp "$canonical_cfg/.rollback-package.XXXXXX")"
      cp -- "$rollback/packages/$baseline_name" "$package_tmp"
      chmod 0644 "$package_tmp"
      [ "$(sha256_of "$package_tmp")" = "$baseline_package_sha" ] || fail "baseline package changed during restore"
      mv -- "$package_tmp" "$destination"
    fi
    descriptor_tmp="$(mktemp /boot/config/plugins/.ci-runner-farm.plg.XXXXXX)"
    cp -- "$rollback/ci-runner-farm.plg" "$descriptor_tmp"
    chmod 0644 "$descriptor_tmp"
    [ "$(sha256_of "$descriptor_tmp")" = "$baseline_descriptor_sha" ] || fail "baseline descriptor changed during restore"
    mv -- "$descriptor_tmp" "$canonical_plg"
  else
    fail "canonical descriptor is not a retained development descriptor; refusing rollback"
  fi
  [ "$(sha256_of "$canonical_plg")" = "$baseline_descriptor_sha" ] || fail "restored descriptor verification failed"
  [ "$(sha256_of "$canonical_cfg/$baseline_name")" = "$baseline_package_sha" ] || fail "restored package verification failed"
else
  if [ -e "$canonical_plg" ] || [ -L "$canonical_plg" ]; then
    known_dev_descriptor || fail "canonical descriptor is not a retained development descriptor; refusing removal"
    rm -f -- "$canonical_plg"
  fi
  [ ! -e "$canonical_plg" ] && [ ! -L "$canonical_plg" ] || fail "failed to remove development descriptor"
fi

printf 'install-dev remote: flash rollback verified. Reboot is required; this script did not reboot.\n'
printf 'install-dev remote: external development artifacts remain at %s until explicitly reviewed.\n' "$artifacts"
REMOTE_ROLLBACK

printf 'install-dev: rollback staged on %s; reboot is required and was not performed\n' "$HOST"
