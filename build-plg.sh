#!/bin/bash
# Assemble a self-contained Unraid .plg from src/. The plugin file tree is
# tarred, base64-encoded, and embedded inline, so the .plg installs with no
# external hosting (ideal for direct install via `installplg`).
set -euo pipefail
cd "$(dirname "$0")"

NAME="ci-runner-farm"
VERSION="$(date +%Y.%m.%d)"
OUT="${NAME}.plg"

PAYLOAD="$(cd src && tar -cz . | base64)"

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
mkdir -p "\$CFGDIR"
base64 -d "\$CFGDIR/payload.b64" | tar -xz -C /
rm -f "\$CFGDIR/payload.b64"
chmod +x "\$PLGDIR/include/runner-farm.sh"
[ -f "\$CFGDIR/config.cfg" ] || cp "\$PLGDIR/default.cfg" "\$CFGDIR/config.cfg"
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
