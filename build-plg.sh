#!/bin/bash
# Assemble a self-contained Unraid .plg from src/. The plugin file tree is
# tarred, base64-encoded, and embedded inline, so the .plg installs with no
# external file hosting — Community Applications (or `installplg`) only ever
# fetches the single .plg, which carries everything it needs.
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
REPO="${REPO:-unraid/ci-runner-farm}"

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

# Changelog body for the <CHANGES> block: pull the newest CHANGELOG.md section
# if present, else a generic line. Kept plain so the plugin manager renders it.
changes="- Containerized GitHub Actions runner farm for Unraid."
if [ -f CHANGELOG.md ]; then
  section="$(awk '/^## /{n++; if(n==2) exit} n==1 && !/^## /' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
  [ -n "$section" ] && changes="$section"
fi

# Package ONLY the plugin dir contents (never /usr or a root '.' entry that
# could clobber system-dir perms/ownership on extract). No owner flags here so
# the build is portable across GNU tar (CI) and BSD tar (macOS); the install
# step extracts with --no-same-owner and chowns root:root, so archive ownership
# is irrelevant either way.
PAYLOAD="$(tar -cz -C "src/usr/local/emhttp/plugins/${NAME}" . | base64)"

cat > "$OUT" <<PLG
<?xml version='1.0' standalone='yes'?>
<!DOCTYPE PLUGIN [
<!ENTITY name          "${NAME}">
<!ENTITY author        "Lime Technology">
<!ENTITY version       "${VERSION}">
<!ENTITY pluginVersion "${INTERNAL_VERSION}">
<!ENTITY releaseTag    "${RELEASE_TAG}">
<!ENTITY pluginURL     "${PLUGIN_URL}">
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

<!-- base64 payload of the plugin file tree -->
<FILE Name="&cfgdir;/payload.b64">
<INLINE><![CDATA[
${PAYLOAD}
]]></INLINE>
</FILE>

<!-- install (entities are NOT expanded inside CDATA, so use literal paths) -->
<FILE Run="/bin/bash">
<INLINE><![CDATA[
set -e
PLGDIR="/usr/local/emhttp/plugins/${NAME}"
CFGDIR="/boot/config/plugins/${NAME}"
mkdir -p "\$CFGDIR" "\$PLGDIR"
# Extract ONLY into the plugin dir; --no-same-owner forces root ownership;
# --no-overwrite-dir leaves existing dir metadata alone. System dirs untouched.
base64 -d "\$CFGDIR/payload.b64" | tar -xz --no-same-owner --no-overwrite-dir -C "\$PLGDIR"
rm -f "\$CFGDIR/payload.b64"
chown -R root:root "\$PLGDIR"
find "\$PLGDIR" -type d -exec chmod 0755 {} +
find "\$PLGDIR" -type f -exec chmod 0644 {} +
chmod 0755 "\$PLGDIR/include/runner-farm.sh"
[ -f "\$CFGDIR/config.cfg" ] || cp "\$PLGDIR/default.cfg" "\$CFGDIR/config.cfg"
chmod 0644 "\$CFGDIR/config.cfg"
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
"\$PLGDIR/include/runner-farm.sh" stop 2>/dev/null || true
rm -rf "\$PLGDIR"
echo "ci-runner-farm removed. Config + token left in /boot/config/plugins/${NAME} (delete manually to purge)."
]]></INLINE>
</FILE>

</PLUGIN>
PLG

echo "built $OUT (version $VERSION, tag $RELEASE_TAG, payload $(echo "$PAYLOAD" | wc -c | tr -d ' ') b64 bytes)"
