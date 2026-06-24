#!/bin/bash
# Assemble a self-contained Unraid .plg from src/. The plugin file tree is
# tarred, base64-encoded, and embedded inline, so the .plg installs with no
# external hosting (ideal for direct install via `installplg`).
set -euo pipefail
cd "$(dirname "$0")"

NAME="ci-runner-farm"
VERSION="$(date +%Y.%m.%d.%H%M)"
OUT="${NAME}.plg"

# Package ONLY the plugin dir contents (never /usr or a root '.' entry that
# could clobber system-dir perms/ownership on extract), and bake root:root
# ownership into the archive so even a raw extract lands as root.
PAYLOAD="$(tar -cz --uid 0 --gid 0 --uname root --gname root -C "src/usr/local/emhttp/plugins/${NAME}" . | base64)"

cat > "$OUT" <<PLG
<?xml version='1.0' standalone='yes'?>
<!DOCTYPE PLUGIN [
<!ENTITY name    "${NAME}">
<!ENTITY author  "Lime Technology">
<!ENTITY version "${VERSION}">
<!ENTITY plgdir  "/usr/local/emhttp/plugins/&name;">
<!ENTITY cfgdir  "/boot/config/plugins/&name;">
]>
<PLUGIN name="&name;" author="&author;" version="&version;" min="6.12.0">

<CHANGES>
### &version;
- Containerized GitHub Actions build-runner farm for Unraid.
- Multiple concurrent runners (no VM), resource-capped, warm shared caches on a fast pool, host docker.sock for service containers.
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

echo "built $OUT (version $VERSION, payload $(echo "$PAYLOAD" | wc -c) b64 bytes)"
