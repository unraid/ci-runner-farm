#!/bin/bash
# Assemble an Unraid .plg + its .tgz package from src/. The plugin file tree is
# tarred into ci-runner-farm.tgz, and the .plg downloads that package by URL and
# verifies it by MD5 (the standard Unraid <FILE> URL/MD5 pattern) — no inline
# base64 payload. Only the .plg is committed (its version stamp must be frozen at
# the tag); the .tgz is rebuilt REPRODUCIBLY at publish (see make_tgz), so the
# uploaded package always matches the packageMD5 the committed .plg advertises.
#
# Versioning (mirrors the other Unraid plugins we publish via release-please):
#   INTERNAL_VERSION  SemVer source of truth (from .release-please-manifest.json),
#                     e.g. 0.1.0. Becomes the <pluginVersion> entity and the
#                     vX.Y.Z release tag. Defaults to the VERSION file, then 0.0.0.
#   BUILD_NUMBER      Monotonic build counter (CI passes $GITHUB_RUN_NUMBER).
#                     Defaults to 0 for local dev builds.
#   DATE              YYYY.MM.DD.HHMM build stamp. Defaults to now (UTC).
#   REPO              owner/name on GitHub, used for pluginURL + support URL.
#
# The Unraid plugin-manager <version> ("external" version) is
#   YYYY.MM.DD.HHMM.BUILD-INTERNAL  e.g. 2026.06.24.1530.42-0.1.0
# which sorts chronologically in the plugin manager while still pinning the
# SemVer release it was cut from. pluginURL points at the GitHub release asset
# so Unraid's "check for updates" always resolves the newest published .plg.
set -euo pipefail
cd "$(dirname "$0")"

NAME="ci-runner-farm"
OUT="${NAME}.plg"
SRCDIR="src/usr/local/emhttp/plugins/${NAME}"
TGZ="${NAME}.tgz"
REPO="${REPO:-unraid/ci-runner-farm}"

# Build the .tgz package REPRODUCIBLY: byte-identical output (=> identical MD5)
# across CI runs from the same source, so the publish job can rebuild the package
# the committed .plg's packageMD5 pins — no need to carry the binary in git.
# git checkout stamps fresh mtimes, so pinning --mtime is essential; we also pin
# order + ownership and use gzip -n (drops the gzip timestamp). BSD tar (macOS
# dev) can't pin all of these, but local builds are never published — every
# release asset is built by CI on GNU tar. Package ONLY the plugin dir contents
# (never /usr or a root '.' entry that could clobber system-dir perms on extract;
# the install step extracts --no-same-owner and chowns root:root regardless).
make_tgz() {
  local opts=()
  if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
    opts=(--sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner)
  fi
  # ${opts[@]+...} keeps this safe under `set -u` when opts is empty (bash 3.2).
  tar ${opts[@]+"${opts[@]}"} -cf - -C "$SRCDIR" . | gzip -9n > "$TGZ"
}

# `build-plg.sh --tgz-only` just (re)builds the package — used by the release
# jobs to regenerate the exact bytes the committed .plg already advertises.
if [ "${1:-}" = "--tgz-only" ]; then make_tgz; echo "built $TGZ ($(wc -c < "$TGZ" | tr -d ' ') bytes)"; exit 0; fi

# Internal SemVer: explicit env wins, else the VERSION file, else 0.0.0 (dev).
INTERNAL_VERSION="${INTERNAL_VERSION:-$( [ -f VERSION ] && tr -d '[:space:]' < VERSION || echo '0.0.0' )}"
INTERNAL_VERSION="${INTERNAL_VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
DATE="${DATE:-$(date -u +%Y.%m.%d.%H%M)}"

# Validate the pieces so a bad release input fails the build, not the install.
[[ "$DATE" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}$ ]] || { echo "DATE must be YYYY.MM.DD.HHMM: $DATE" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be numeric: $BUILD_NUMBER" >&2; exit 1; }
[[ "$INTERNAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "INTERNAL_VERSION must be SemVer: $INTERNAL_VERSION" >&2; exit 1; }

VERSION="${DATE}.${BUILD_NUMBER}-${INTERNAL_VERSION}"
RELEASE_TAG="v${INTERNAL_VERSION}"
PLUGIN_URL="https://github.com/${REPO}/releases/latest/download/${NAME}.plg"
SUPPORT_URL="https://github.com/${REPO}/issues"

# The package is published as a release asset under a version-pinned name so an
# old .plg never resolves a newer release's package. pluginURL stays "latest/"
# (update checks find the newest .plg); packageURL is tag-pinned (each .plg
# fetches exactly its own package). The .tgz itself is NOT committed — CI rebuilds
# it reproducibly at publish (see make_tgz above); only the .plg is committed.
PACKAGE_NAME="${NAME}-${VERSION}.tgz"
PACKAGE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${PACKAGE_NAME}"

# Portable MD5 (md5sum on Linux/CI, md5 on macOS/BSD dev boxes).
md5_of() { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }

# Changelog body for the <CHANGES> block: pull the newest CHANGELOG.md section
# if present, else a generic line. Kept plain so the plugin manager renders it.
changes="- Containerized GitHub Actions runner farm for Unraid."
if [ -f CHANGELOG.md ]; then
  section="$(awk '/^## /{n++; if(n==2) exit} n==1 && !/^## /' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
  [ -n "$section" ] && changes="$section"
fi

make_tgz
PACKAGE_MD5="$(md5_of "$TGZ")"

cat > "$OUT" <<PLG
<?xml version='1.0' standalone='yes'?>
<!DOCTYPE PLUGIN [
<!ENTITY name          "${NAME}">
<!ENTITY author        "Lime Technology">
<!ENTITY version       "${VERSION}">
<!ENTITY pluginVersion "${INTERNAL_VERSION}">
<!ENTITY releaseTag    "${RELEASE_TAG}">
<!ENTITY pluginURL     "${PLUGIN_URL}">
<!ENTITY packageName   "${PACKAGE_NAME}">
<!ENTITY packageURL    "${PACKAGE_URL}">
<!ENTITY packageMD5    "${PACKAGE_MD5}">
<!ENTITY plgdir        "/usr/local/emhttp/plugins/&name;">
<!ENTITY cfgdir        "/boot/config/plugins/&name;">
]>
<PLUGIN name="&name;"
        author="&author;"
        version="&version;"
        pluginURL="&pluginURL;"
        min="6.12.0"
        support="${SUPPORT_URL}"
        icon="docker">

<CHANGES>
### &version;
${changes}
</CHANGES>

<!-- plugin package: Unraid downloads it to flash and verifies the MD5 -->
<FILE Name="&cfgdir;/&packageName;">
<URL>&packageURL;</URL>
<MD5>&packageMD5;</MD5>
</FILE>

<!-- install (entities are NOT expanded inside CDATA, so use literal paths) -->
<FILE Run="/bin/bash">
<INLINE><![CDATA[
set -e
PLGDIR="/usr/local/emhttp/plugins/${NAME}"
CFGDIR="/boot/config/plugins/${NAME}"
mkdir -p "\$CFGDIR" "\$PLGDIR"
# Sweep any older package versions off flash, keeping this build's package.
find "\$CFGDIR" -maxdepth 1 -name '${NAME}-*.tgz' ! -name '${PACKAGE_NAME}' -delete 2>/dev/null || true
# Extract ONLY into the plugin dir; --no-same-owner forces root ownership;
# --no-overwrite-dir leaves existing dir metadata alone. System dirs untouched.
# The .tgz is kept on flash so the on-boot reinstall works without a download.
tar -xzf "\$CFGDIR/${PACKAGE_NAME}" --no-same-owner --no-overwrite-dir -C "\$PLGDIR"
chown -R root:root "\$PLGDIR"
find "\$PLGDIR" -type d -exec chmod 0755 {} +
find "\$PLGDIR" -type f -exec chmod 0644 {} +
chmod 0755 "\$PLGDIR/include/runner-farm.sh"
# Unraid's emhttp_event executes these on Docker service start/stop — must be +x
[ -d "\$PLGDIR/event" ] && find "\$PLGDIR/event" -type f -exec chmod 0755 {} +
# Config defaults are NOT seeded to flash — the settings page and runner-farm.sh
# both fall back to built-in defaults, so flash only ever holds what the user set.
[ -f "\$CFGDIR/Dockerfile" ] || cp "\$PLGDIR/default.Dockerfile" "\$CFGDIR/Dockerfile"
( docker pull myoung34/github-runner:latest >/dev/null 2>&1 & ) || true
# Bring the fleet + autoscaler up. Runs on manual install AND on every boot
# (rc.local reinstalls plugins), detached so it waits for dockerd+array without
# blocking. No-op until a GitHub token is configured.
( nohup "\$PLGDIR/include/runner-farm.sh" boot-autostart >>"\$CFGDIR/boot.log" 2>&1 & ) || true
echo ""
echo "+=============================================================+"
echo "| ci-runner-farm ${VERSION} installed.                         "
echo "| Settings > Utilities > CI Runner Farm                        "
echo "| Set a GitHub PAT, then Start (or Validate without a token).  "
echo "+=============================================================+"
]]></INLINE>
</FILE>

<!-- remove -->
<FILE Run="/bin/bash" Method="remove">
<INLINE><![CDATA[
PLGDIR="/usr/local/emhttp/plugins/${NAME}"
CFGDIR="/boot/config/plugins/${NAME}"
"\$PLGDIR/include/runner-farm.sh" stop 2>/dev/null || true
rm -rf "\$PLGDIR"
# The downloaded package is just a cache; drop it. Config + token stay.
rm -f "\$CFGDIR"/${NAME}-*.tgz
echo "ci-runner-farm removed. Config + token left in /boot/config/plugins/${NAME} (delete manually to purge)."
]]></INLINE>
</FILE>

</PLUGIN>
PLG

echo "built $OUT + $TGZ (version $VERSION, tag $RELEASE_TAG, package $(wc -c < "$TGZ" | tr -d ' ') bytes, md5 $PACKAGE_MD5)"
