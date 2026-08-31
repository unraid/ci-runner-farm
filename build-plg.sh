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

# Build an explicitly local-only plugin descriptor and package without touching
# the canonical release artifacts in the repository root. The development PLG
# uses Unraid's <LOCAL> package source so it cannot accidentally fetch or publish
# a GitHub release asset. Its content-addressed version makes separate source
# states unambiguous while keeping repeat builds deterministic.
build_dev_package() {
  if ! tar --version 2>/dev/null | grep -qi 'gnu tar'; then
    echo "build-plg.sh --dev requires GNU tar for deterministic package bytes" >&2
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || {
    echo "build-plg.sh --dev requires python3" >&2
    return 1
  }
  command -v sha256sum >/dev/null 2>&1 || {
    echo "build-plg.sh --dev requires sha256sum" >&2
    return 1
  }

  local base_internal dev_internal dev_build dev_date dev_version
  local dev_workdir render_dir raw_tgz rendered_tgz package_sha package_md5
  local package_name source_path stage_dir output_dir

  base_internal="${INTERNAL_VERSION:-$( [ -f VERSION ] && tr -d '[:space:]' < VERSION || echo '0.0.0' )}"
  base_internal="${base_internal:-0.0.0}"
  dev_build="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
  dev_date="${DATE:-$(date -u +%Y.%m.%d.%H%M)}"

  [[ "$dev_date" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}$ ]] || {
    echo "DATE must be YYYY.MM.DD.HHMM: $dev_date" >&2
    return 1
  }
  [[ "$dev_build" =~ ^[0-9]+$ ]] || {
    echo "BUILD_NUMBER must be numeric: $dev_build" >&2
    return 1
  }
  [[ "$base_internal" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || {
    echo "INTERNAL_VERSION must be SemVer: $base_internal" >&2
    return 1
  }

  mkdir -p tmp
  dev_workdir="$(mktemp -d "tmp/.${NAME}-dev-package.XXXXXX")"
  DEV_PACKAGE_WORKDIR="$dev_workdir"
  trap 'rm -rf -- "$DEV_PACKAGE_WORKDIR"' EXIT HUP INT TERM

  raw_tgz="$dev_workdir/${NAME}.tgz"
  TGZ="$raw_tgz"
  make_tgz
  package_sha="$(sha256sum "$raw_tgz" | cut -d' ' -f1)"
  [[ "$package_sha" =~ ^[0-9a-f]{64}$ ]] || {
    echo "failed to calculate package SHA256" >&2
    return 1
  }

  if [[ "$base_internal" == *-* ]]; then
    dev_internal="${base_internal}.jcuratec.gitlab.dev.${package_sha:0:12}"
  else
    dev_internal="${base_internal}-jcuratec.gitlab.dev.${package_sha:0:12}"
  fi
  dev_version="${dev_date}.${dev_build}-${dev_internal}"
  package_name="${NAME}-jcuratec-dev-${dev_version}.tgz"
  source_path="/boot/config/${NAME}-dev/artifacts/${package_name}"

  # Reuse the production renderer from a disposable copy. Calling it without
  # --dev exercises the exact current release template while keeping its output
  # and the root ci-runner-farm.plg/ci-runner-farm.tgz completely isolated.
  render_dir="$dev_workdir/render"
  mkdir -p "$render_dir/$SRCDIR"
  cp build-plg.sh "$render_dir/build-plg.sh"
  [ ! -f VERSION ] || cp VERSION "$render_dir/VERSION"
  [ ! -f CHANGELOG.md ] || cp CHANGELOG.md "$render_dir/CHANGELOG.md"
  cp -R "$SRCDIR"/. "$render_dir/$SRCDIR/"
  (
    cd "$render_dir"
    DATE="$dev_date" \
      BUILD_NUMBER="$dev_build" \
      INTERNAL_VERSION="$dev_internal" \
      REPO="j-curatec/ci-runner-farm" \
      bash ./build-plg.sh >/dev/null
  )
  rendered_tgz="$render_dir/${NAME}.tgz"
  if [ "$(sha256sum "$rendered_tgz" | cut -d' ' -f1)" != "$package_sha" ]; then
    echo "development package changed while rendering its descriptor" >&2
    return 1
  fi

  if command -v md5sum >/dev/null 2>&1; then
    package_md5="$(md5sum "$raw_tgz" | cut -d' ' -f1)"
  else
    package_md5="$(md5 -q "$raw_tgz")"
  fi

  stage_dir="$dev_workdir/output"
  mkdir -p "$stage_dir"
  cp "$raw_tgz" "$stage_dir/$package_name"

  DEV_PACKAGE_NAME="$package_name" \
    DEV_PACKAGE_SHA256="$package_sha" \
    DEV_SOURCE_PATH="$source_path" \
    python3 - "$render_dir/${NAME}.plg" "$stage_dir/${NAME}.plg" <<'PY'
import os
import re
import sys

source, destination = sys.argv[1:]
package = os.environ["DEV_PACKAGE_NAME"]
sha256 = os.environ["DEV_PACKAGE_SHA256"]
source_path = os.environ["DEV_SOURCE_PATH"]
text = open(source, encoding="utf-8").read()


def replace_once(old, new, label):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"cannot render dev PLG: expected one {label}, found {count}")
    text = text.replace(old, new, 1)


def sub_once(pattern, replacement, label, flags=0):
    global text
    text, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"cannot render dev PLG: expected one {label}, found {count}")


sub_once(r'<!ENTITY author\s+"[^"]*">', '<!ENTITY author        "j-curatec local dev">', "author entity")
sub_once(r'^<!ENTITY pluginURL\s+"[^"]*">\n', '', "pluginURL entity", re.MULTILINE)
sub_once(r'<!ENTITY packageName\s+"[^"]*">', f'<!ENTITY packageName   "{package}">', "package name entity")
sub_once(r'^<!ENTITY packageURL\s+"[^"]*">\n', '', "packageURL entity", re.MULTILINE)
sub_once(
    r'(<!ENTITY packageMD5\s+"[^"]*">\n)',
    rf'\1<!ENTITY packageSHA256 "{sha256}">\n',
    "package MD5 entity",
)
sub_once(r'^\s*pluginURL="&pluginURL;"\n', '', "pluginURL attribute", re.MULTILINE)
sub_once(
    r'support="[^"]*"',
    'support="https://github.com/j-curatec/ci-runner-farm/issues"',
    "support attribute",
)
sub_once(
    r'<CHANGES>\n.*?</CHANGES>',
    '''<CHANGES>
### &version;
* Local development build from the j-curatec GitLab-provider working tree.
* Adds CI_PROVIDER=github|gitlab while retaining the GitHub provider.
* Uses an offline, content-addressed flash artifact and has no automatic update URL.
</CHANGES>''',
    "development changes block",
    re.DOTALL,
)
sub_once(
    r'<!-- plugin package:.*?</FILE>',
    f'''<!-- local development package: copied from its offline flash artifact -->
<FILE Name="/tmp/&packageName;">
<LOCAL>{source_path}</LOCAL>
<MD5>&packageMD5;</MD5>
<SHA256>&packageSHA256;</SHA256>
</FILE>''',
    "package FILE block",
    re.DOTALL,
)

sub_once(
    r'# Sweep any older package versions off flash, keeping this build\'s package\.\n'
    r'find "\$CFGDIR" -maxdepth 1 -name \'ci-runner-farm-\*\.tgz\' ! -name \'[^\']+\' -delete 2>/dev/null \|\| true',
    '# Local dev artifacts and rollback packages are installer-owned; retain them.',
    "cached package sweep",
)

replace_once(
    'mkdir -p "$CFGDIR" "$PLGDIR"',
    f'''mkdir -p "$CFGDIR" "$PLGDIR"
PKG="/tmp/{package}"
EXPECTED_PACKAGE_SHA256="{sha256}"
command -v sha256sum >/dev/null 2>&1 || {{
  echo "ci-runner-farm dev install failed: sha256sum is unavailable." >&2
  rm -f -- "$PKG"
  exit 1
}}
actual_package_sha256="$(sha256sum "$PKG" | cut -d' ' -f1)" || {{
  rm -f -- "$PKG"
  exit 1
}}
if [ "$actual_package_sha256" != "$EXPECTED_PACKAGE_SHA256" ]; then
  echo "ci-runner-farm dev install failed: package SHA256 mismatch." >&2
  rm -f -- "$PKG"
  exit 1
fi
trap 'rm -f -- "$PKG"' EXIT HUP INT TERM''',
    "install directory setup",
)
sub_once(
    r'tar -xzf "\$CFGDIR/[^"]+" --no-same-owner --no-overwrite-dir -C "\$PLGDIR"',
    '''tar -xzf "$PKG" --no-same-owner --no-overwrite-dir -C "$PLGDIR"
rm -f -- "$PKG"
trap - EXIT HUP INT TERM''',
    "package extraction",
)
replace_once(
    '# The .tgz is kept on flash so the on-boot reinstall works without a download.',
    '# The verified temporary copy is removed after extraction; the external dev artifact is retained.',
    "package retention comment",
)
sub_once(
    r'# The downloaded package is just a cache; drop it\. Config \+ credentials stay\.\n'
    r'if ! rm -f -- "\$CFGDIR"/ci-runner-farm-\*\.tgz; then\n'
    r'.*?\nfi',
    f'''# External dev artifacts and rollback packages are installer-owned and retained.
# Do not delete upstream cached packages or /boot/config/ci-runner-farm-dev here.
rm -f -- "/tmp/{package}" 2>/dev/null || true''',
    "remove-time package cleanup",
    re.DOTALL,
)

if "pluginURL" in text or "<URL>" in text or "packageURL" in text:
    raise SystemExit("cannot render dev PLG: remote update metadata remains")
if "<LOCAL>" + source_path + "</LOCAL>" not in text:
    raise SystemExit("cannot render dev PLG: local artifact source is missing")
if f'<!ENTITY packageSHA256 "{sha256}">' not in text:
    raise SystemExit("cannot render dev PLG: package SHA256 entity is missing")
if '<SHA256>&packageSHA256;</SHA256>' not in text:
    raise SystemExit("cannot render dev PLG: package SHA256 reference is missing")

with open(destination, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(text)
PY

  DEV_VERSION="$dev_version" \
    DEV_PACKAGE_NAME="$package_name" \
    DEV_PACKAGE_MD5="$package_md5" \
    DEV_PACKAGE_SHA256="$package_sha" \
    DEV_SOURCE_PATH="$source_path" \
    python3 - "$stage_dir/manifest.json" <<'PY'
import json
import os
import sys

manifest = {
    "schema": 1,
    "name": "ci-runner-farm",
    "mode": "dev",
    "version": os.environ["DEV_VERSION"],
    "plugin_file": "ci-runner-farm.plg",
    "package_file": os.environ["DEV_PACKAGE_NAME"],
    "package_md5": os.environ["DEV_PACKAGE_MD5"],
    "package_sha256": os.environ["DEV_PACKAGE_SHA256"],
    "source_path": os.environ["DEV_SOURCE_PATH"],
    "runtime_root": "src/usr/local/emhttp/plugins/ci-runner-farm",
}
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as handle:
    json.dump(manifest, handle, separators=(",", ":"))
    handle.write("\n")
PY

  output_dir="tmp/dev-package"
  rm -rf -- "$output_dir"
  mv "$stage_dir" "$output_dir"
  rm -rf -- "$dev_workdir"
  trap - EXIT HUP INT TERM
  echo "built $output_dir/${NAME}.plg + $output_dir/$package_name (version $dev_version, sha256 $package_sha)"
}

if [ "${1:-}" = "--dev" ]; then build_dev_package; exit $?; fi

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

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g'
}

# Changelog body for the <CHANGES> block: pull the newest CHANGELOG.md section
# if present, else a generic line. Kept plain so the plugin manager renders it.
changes="- Containerized GitHub Actions runner farm for Unraid."
if [ -f CHANGELOG.md ]; then
  section="$(awk '/^## /{n++; if(n==2) exit} n==1 && !/^## /' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
  [ -n "$section" ] && changes="$section"
fi
changes="$(xml_escape "$changes")"

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
[ -d "\$PLGDIR/nchan" ] && find "\$PLGDIR/nchan" -type f -exec chmod 0755 {} +
# Unraid's emhttp_event executes these on Docker service start/stop — must be +x
[ -d "\$PLGDIR/event" ] && find "\$PLGDIR/event" -type f -exec chmod 0755 {} +
# Config defaults are NOT seeded to flash — the settings page and runner-farm.sh
# both fall back to built-in defaults, so flash only ever holds what the user set.
# Provider-specific editable Dockerfiles keep a GitLab job-image build from
# replacing a customized GitHub runner image (and vice versa). Existing installs
# used the unsuffixed Dockerfile; copy it forward once as the GitHub source while
# retaining the old file as a compatibility/downgrade fallback.
if [ ! -f "\$CFGDIR/Dockerfile.github" ]; then
  if [ -f "\$CFGDIR/Dockerfile" ]; then
    cp "\$CFGDIR/Dockerfile" "\$CFGDIR/Dockerfile.github"
  else
    cp "\$PLGDIR/default.github.Dockerfile" "\$CFGDIR/Dockerfile.github"
  fi
fi
[ -f "\$CFGDIR/Dockerfile.gitlab" ] || cp "\$PLGDIR/default.gitlab.Dockerfile" "\$CFGDIR/Dockerfile.gitlab"
# Migrate GitHub Dockerfiles seeded before the cache-ownership fix: without
# runner-owned CACHE_MOUNTS destinations baked into the image, Docker's
# bind-mount auto-creation leaves root-owned parents and a non-root runner
# fails writing beside them (rustup: "could not create bin directory
# '/home/runner/.cargo/bin'"). Patch only files that still carry the stock
# packages marker and lack the fix; customized files without the marker get a
# notice instead.
DF="\$CFGDIR/Dockerfile.github"
if [ -f "\$DF" ] && ! grep -q 'mkdir -p /home/runner/.cargo/registry' "\$DF"; then
  if grep -q '^#  && rm -rf /var/lib/apt/lists/\\*' "\$DF"; then
    BLK=\$(mktemp)
    cat > "\$BLK" <<'EOF_CACHEDIRS'

# Pre-create the default CACHE_MOUNTS destinations as runner-owned. When these
# paths are absent from the image, Docker's bind-mount auto-creation makes the
# missing parent directories root-owned, and a non-root runner (RUN_AS_ROOT=false)
# can then no longer write beside them — e.g. rustup fails with "could not
# create bin directory '/home/runner/.cargo/bin': Permission denied".
RUN mkdir -p /home/runner/.cargo/registry /home/runner/.cargo/git \\
      /home/runner/.cache/sccache /home/runner/.cache/yarn /home/runner/.cache/ms-playwright \\
      /home/runner/.npm /home/runner/.local/share/pnpm/store \\
 && chown -R runner:runner /home/runner/.cargo /home/runner/.cache /home/runner/.npm /home/runner/.local
EOF_CACHEDIRS
    sed -i "\\@^#  && rm -rf /var/lib/apt/lists/\\*@r \$BLK" "\$DF"
    rm -f "\$BLK"
    echo "ci-runner-farm: patched saved Dockerfile to pre-create runner-owned cache dirs (press Build to rebuild the runner image)."
  else
    echo "ci-runner-farm: NOTE - saved \$DF lacks the runner-owned cache-dir block from default.github.Dockerfile; merge it manually so non-root runners can write beside the cache mounts."
  fi
fi
( docker pull myoung34/github-runner:latest >/dev/null 2>&1 & ) || true
( docker pull gitlab/gitlab-runner:alpine >/dev/null 2>&1 & ) || true
# Bring the fleet + autoscaler up. Runs on manual install AND on every boot
# (rc.local reinstalls plugins), detached so it waits for dockerd+array without
# blocking. No-op until the selected provider's runner token is configured.
( nohup "\$PLGDIR/include/runner-farm.sh" boot-autostart >>"\$CFGDIR/boot.log" 2>&1 & ) || true
echo ""
echo "+=============================================================+"
echo "| ci-runner-farm ${VERSION} installed.                         "
echo "| Settings > Utilities > CI Runner Farm                        "
echo "| Select GitHub or GitLab, save its token, then Start.         "
echo "+=============================================================+"
]]></INLINE>
</FILE>

<!-- remove -->
<FILE Run="/bin/bash" Method="remove">
<INLINE><![CDATA[
set -euo pipefail
PLGDIR="/usr/local/emhttp/plugins/${NAME}"
CFGDIR="/boot/config/plugins/${NAME}"
ENGINE="\$PLGDIR/include/runner-farm.sh"
if [ -x "\$ENGINE" ]; then
  if ! "\$PLGDIR/include/runner-farm.sh" stop >>"\$CFGDIR/boot.log" 2>&1; then
    echo "ci-runner-farm NOT removed: one or more runners, jobs, or privileged sidecars could not be stopped safely." >&2
    echo "Review \$CFGDIR/boot.log, retry Stop, or use the separately confirmed local-forget recovery action if GitLab is permanently unreachable." >&2
    exit 1
  fi
else
  # A partially deleted runtime cannot perform the normal ownership-verified
  # teardown. Never interpret that as an empty farm: prove through Docker that
  # no plugin-labelled manager, validation container, privileged DinD sidecar,
  # host-socket executor workload, or registry mirror survives before allowing
  # the remaining package files to be removed.
  command -v docker >/dev/null 2>&1 || {
    echo "ci-runner-farm NOT removed: cleanup engine is missing and Docker is unavailable, so owned runtime resources cannot be enumerated." >&2
    echo "Start Docker or restore the plugin runtime, then retry removal." >&2
    exit 1
  }
  owned_runtime=""
  for filter in \
    'label=net.unraid.ci-runner-farm.managed=true' \
    'label=net.unraid.ci-runner-farm.sidecar=true' \
    'label=net.unraid.ci-runner-farm.role=mirror'
  do
    if ! ids=\$(docker ps -aq --filter "\$filter" 2>/dev/null); then
      echo "ci-runner-farm NOT removed: cleanup engine is missing and Docker ownership enumeration failed." >&2
      exit 1
    fi
    [ -z "\$ids" ] || owned_runtime="\${owned_runtime}\${ids} "
  done
  if ! ids=\$(docker ps -aq \
      --filter 'label=com.gitlab.gitlab-runner.managed=true' \
      --filter 'label=net.unraid.ci-runner-farm.provider=gitlab' 2>/dev/null); then
    echo "ci-runner-farm NOT removed: cleanup engine is missing and GitLab executor ownership enumeration failed." >&2
    exit 1
  fi
  [ -z "\$ids" ] || owned_runtime="\${owned_runtime}\${ids} "
  if [ -n "\$owned_runtime" ]; then
    echo "ci-runner-farm NOT removed: the cleanup engine is missing while plugin-owned Docker resources still exist." >&2
    echo "Restore the plugin runtime, then retry removal so those resources can be stopped safely." >&2
    exit 1
  fi
fi
if ! rm -rf -- "\$PLGDIR" || [ -e "\$PLGDIR" ]; then
  echo "ci-runner-farm NOT fully removed: failed to delete the installed runtime at \$PLGDIR." >&2
  exit 1
fi
# The downloaded package is just a cache; drop it. Config + credentials stay.
if ! rm -f -- "\$CFGDIR"/${NAME}-*.tgz; then
  echo "ci-runner-farm NOT fully removed: runtime cleanup succeeded, but a cached package could not be deleted from \$CFGDIR." >&2
  exit 1
fi
echo "ci-runner-farm removed. Config + credentials left in /boot/config/plugins/${NAME} (delete manually to purge)."
]]></INLINE>
</FILE>

</PLUGIN>
PLG

echo "built $OUT + $TGZ (version $VERSION, tag $RELEASE_TAG, package $(wc -c < "$TGZ" | tr -d ' ') bytes, md5 $PACKAGE_MD5)"
