#!/usr/bin/env bash
# Safety and failure-order contracts for install-dev.sh.  All host interaction
# is mocked; this test never reads or writes an Unraid /boot tree.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALLER=install-dev.sh
fail() { printf 'INSTALL-DEV SAFETY FAIL: %s\n' "$*" >&2; exit 1; }
line_of() {
  local value
  value="$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1 || true)"
  [ -n "$value" ] || fail "missing contract: $2"
  printf '%s\n' "$value"
}

bash -n "$INSTALLER" || fail "installer has invalid shell syntax"
missing_line_output="$( (line_of "$INSTALLER" '__install_dev_missing_contract_probe__') 2>&1 || true)"
case "$missing_line_output" in
  *'missing contract: __install_dev_missing_contract_probe__'*) ;;
  *) fail "line_of suppresses its focused missing-contract diagnostic" ;;
esac

# The local bundle is authenticated before the first remote mutation, and the
# lock-protected live deployment completes before flash state is created.
validate_line="$(line_of "$INSTALLER" '  validate_bundle')"
deploy_line="$(line_of "$INSTALLER" '  bash "$SCRIPT_DIR/deploy.sh" "$HOST"')"
stage_line="$(line_of "$INSTALLER" '  REMOTE_STAGE="$(ssh -- "$HOST"')"
[ "$validate_line" -lt "$deploy_line" ] && [ "$deploy_line" -lt "$stage_line" ] \
  || fail "bundle validation/deploy/upload ordering is unsafe"

for contract in \
  'set -euo pipefail' \
  'manifest fields do not exactly match schema 1' \
  'package MD5 does not match the manifest' \
  'package SHA-256 does not match the manifest' \
  'invalid plugin XML' \
  'plugin package LOCAL source does not match manifest source_path' \
  'plugin package SHA-256 does not match the manifest' \
  'host must be root@ followed by a simple SSH hostname or IPv4 address'
do
  grep -qF -- "$contract" "$INSTALLER" || fail "missing local validation: $contract"
done
grep -qF 'case "${HOST#root@}"' "$INSTALLER" || fail "host shell syntax is not rejected"
if grep -qF 'set -x' "$INSTALLER"; then fail "installer enables shell tracing"; fi
if grep -qF 'PACKAGE="$BUNDLE_DIR/$PACKAGE_FILE"' "$INSTALLER"; then
  fail "installer retains the unused PACKAGE assignment"
fi

# Baseline creation is one-time and copies exactly the public canonical
# descriptor plus the one package it references.  It must not sweep or copy the
# config directory that contains tokens, certificates, TOMLs, and Docker auth.
for contract in \
  'rollback="$dev_root/rollback"' \
  'chmod 0700 "$rollback_tmp"' \
  'if [ -e "$rollback" ] || [ -L "$rollback" ]; then' \
  'cp -- "$canonical_plg" "$rollback_tmp/ci-runner-farm.plg"' \
  'baseline_package="$canonical_cfg/$baseline_name"' \
  'cp -- "$baseline_package" "$rollback_tmp/packages/$baseline_name"' \
  'printf '\''%s\n'\'' absent >"$rollback_tmp/state"' \
  'canonical descriptor'\''s exact cached package is unavailable; refusing an incomplete baseline'
do
  grep -qF -- "$contract" "$INSTALLER" || fail "missing rollback-baseline contract: $contract"
done
cleanup_function_line="$(line_of "$INSTALLER" 'cleanup_install_temps() {')"
cleanup_trap_line="$(line_of "$INSTALLER" 'trap cleanup_install_temps EXIT')"
rollback_tmp_line="$(line_of "$INSTALLER" '  rollback_tmp="$(mktemp -d "$dev_root/.rollback.XXXXXX")"')"
commit_tmp_line="$(line_of "$INSTALLER" '  commit_tmp="$(mktemp "$artifacts/.commit.XXXXXX")"')"
[ "$cleanup_function_line" -lt "$cleanup_trap_line" ] \
  && [ "$cleanup_trap_line" -lt "$rollback_tmp_line" ] \
  && [ "$cleanup_trap_line" -lt "$commit_tmp_line" ] \
  || fail "temporary-path cleanup is not armed before temporary paths are created"
for contract in \
  '"$dev_root"/.rollback.*) rm -rf -- "$rollback_tmp" || status=1' \
  '"$artifacts"/.commit.*) rm -f -- "$commit_tmp" || status=1' \
  '  rollback_tmp=' \
  '  commit_tmp='
do
  grep -qF -- "$contract" "$INSTALLER" || fail "missing temporary cleanup contract: $contract"
done
if grep -Eq 'cp[[:space:]]+-R.*(canonical_cfg|/boot/config/plugins/ci-runner-farm)' "$INSTALLER"; then
  fail "installer recursively copies the persistent config/credential directory"
fi
if grep -Eq 'find[[:space:]]+"?\$canonical_cfg|rm[[:space:]].*\$canonical_cfg/.*\*' "$INSTALLER"; then
  fail "installer sweeps canonical cached packages"
fi

# Uploaded bytes are verified, then the external package commits before Unraid
# registers the canonical descriptor.  A retained descriptor is only a hash
# provenance record and never replaces the canonical file itself.
upload_verify_line="$(line_of "$INSTALLER" '[ "$(sha256_of "$uploaded_package")" = "$package_sha256" ]')"
baseline_commit_line="$(line_of "$INSTALLER" '  mv -- "$rollback_tmp" "$rollback"')"
package_commit_line="$(line_of "$INSTALLER" 'commit_artifact "$uploaded_package" "$artifacts/$package_name"')"
plugin_install_line="$(line_of "$INSTALLER" 'plugin install "$uploaded_plugin"')"
canonical_verify_line="$(line_of "$INSTALLER" 'canonical descriptor verification failed after plugin install')"
[ "$upload_verify_line" -lt "$baseline_commit_line" ] \
  && [ "$baseline_commit_line" -lt "$package_commit_line" ] \
  && [ "$package_commit_line" -lt "$plugin_install_line" ] \
  && [ "$plugin_install_line" -lt "$canonical_verify_line" ] \
  || fail "upload/baseline/artifact/plugin commit ordering is unsafe"

# Rollback uses the current engine, then holds the same fleet lock while proving
# every owned class and daemon empty.  It restores package first and descriptor
# last, without invoking plugin install or extracting an old runtime.
stop_line="$(line_of "$INSTALLER" 'if ! "$engine" stop >/dev/null 2>&1; then')"
lock_line="$(line_of "$INSTALLER" 'exec 8>"$rundir/fleet.lock"')"
manager_line="$(line_of "$INSTALLER" 'docker_names "runner managers"')"
restore_package_line="$(line_of "$INSTALLER" '      mv -- "$package_tmp" "$destination"')"
restore_descriptor_line="$(line_of "$INSTALLER" '    mv -- "$descriptor_tmp" "$canonical_plg"')"
[ "$stop_line" -lt "$lock_line" ] && [ "$lock_line" -lt "$manager_line" ] \
  && [ "$manager_line" -lt "$restore_package_line" ] \
  && [ "$restore_package_line" -lt "$restore_descriptor_line" ] \
  || fail "Stop/lock/empty-check/restore ordering is unsafe"
for resource in \
  'runner managers' \
  'GitLab DinD sidecars' \
  'GitLab host-socket jobs/helpers/services' \
  'registry mirrors' \
  'GitHub validation containers' \
  'GitLab validation jobs' \
  'fixed-name registry mirror remains after Stop' \
  'CI Runner Farm background daemon remains after Stop'
do
  grep -qF -- "$resource" "$INSTALLER" || fail "rollback omits empty check: $resource"
done
for contract in \
  'legacy_name="$(docker inspect -f '\''{{.Name}}'\'' ci-runner-mirror 2>/dev/null)"' \
  'legacy_image="$(docker inspect -f '\''{{.Config.Image}}'\'' ci-runner-mirror 2>/dev/null)"' \
  'legacy_source="$(docker inspect -f '\''{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Source}}{{end}}{{end}}'\'' ci-runner-mirror 2>/dev/null)"' \
  'REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io' \
  '[ "$legacy_name" = /ci-runner-mirror ]' \
  '[ "$legacy_image" = registry:2 ]' \
  '[ "$legacy_source" = "$legacy_cache_root/registry-mirror" ]'
do
  grep -qF -- "$contract" "$INSTALLER" || fail "rollback omits legacy mirror provenance: $contract"
done
legacy_name_line="$(line_of "$INSTALLER" 'legacy_name="$(docker inspect')"
legacy_tuple_line="$(line_of "$INSTALLER" '  if [ "$legacy_name" = /ci-runner-mirror ]')"
legacy_fail_line="$(line_of "$INSTALLER" '    fail "fixed-name registry mirror remains after Stop"')"
[ "$legacy_name_line" -lt "$legacy_tuple_line" ] && [ "$legacy_tuple_line" -lt "$legacy_fail_line" ] \
  || fail "an unrelated fixed-name mirror can still trigger rollback failure before provenance matches"
rollback_block="$(awk '
  /^ssh -- "\$HOST" \/bin\/bash -s <<'"'"'REMOTE_ROLLBACK'"'"'$/ { emit=1 }
  emit { print }
  emit && /^REMOTE_ROLLBACK$/ { exit }
' "$INSTALLER")"
[ -n "$rollback_block" ] || fail "could not locate rollback transaction"
if printf '%s\n' "$rollback_block" | grep -qF 'plugin install'; then
  fail "rollback overlays the baseline runtime through plugin install"
fi
if printf '%s\n' "$rollback_block" | grep -Eq 'tar[[:space:]]+-x|/usr/local/emhttp/plugins.*(cp|mv)'; then
  fail "rollback overlays files into the live runtime"
fi
grep -qF 'Reboot is required; this script did not reboot.' "$INSTALLER" \
  || fail "rollback does not state the reboot boundary"
if printf '%s\n' "$rollback_block" | grep -Eq '(^|[[:space:]])(reboot|shutdown)([[:space:]]|$)'; then
  fail "rollback reboots the host"
fi

# Exercise local validation and the observable failure order with mocked
# deploy/SSH commands.  The remote heredocs are deliberately not executed.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Execute the install transaction's actual EXIT-trap function against both
# temporary path classes. An implicit set -e failure must retain its non-zero
# status while removing the baseline directory and the artifact staging file.
cleanup_function="$(awk '
  /^cleanup_install_temps\(\) \{$/ { emit=1 }
  emit { print }
  emit && /^}$/ { exit }
' "$INSTALLER")"
[ -n "$cleanup_function" ] || fail "could not extract temporary cleanup function"
cleanup_root="$tmp/cleanup-probe"
cleanup_artifacts="$cleanup_root/artifacts"
cleanup_rollback="$cleanup_root/.rollback.ABC123"
cleanup_commit="$cleanup_artifacts/.commit.ABC123"
mkdir -p "$cleanup_rollback" "$cleanup_artifacts"
printf 'partial artifact\n' >"$cleanup_commit"
cleanup_probe="$tmp/cleanup-probe.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  printf '%s\n' 'dev_root="$1"' 'artifacts="$2"' 'rollback_tmp="$3"' 'commit_tmp="$4"'
  printf '%s\n' "$cleanup_function"
  printf '%s\n' 'trap cleanup_install_temps EXIT' 'false'
} >"$cleanup_probe"
if bash "$cleanup_probe" "$cleanup_root" "$cleanup_artifacts" "$cleanup_rollback" "$cleanup_commit"; then
  fail "temporary cleanup probe lost the triggering failure status"
fi
[ ! -e "$cleanup_rollback" ] || fail "rollback temporary directory survived a transaction failure"
[ ! -e "$cleanup_commit" ] || fail "artifact temporary file survived a transaction failure"

repo="$tmp/repo"
mkdir -p "$repo/tmp/dev-package" "$tmp/bin"
cp "$INSTALLER" "$repo/install-dev.sh"
chmod 0755 "$repo/install-dev.sh"

cat >"$repo/deploy.sh" <<'MOCK_DEPLOY'
#!/usr/bin/env bash
printf 'deploy\n' >>"$TEST_LOG"
[ "${MOCK_DEPLOY_FAIL:-0}" = 0 ] || exit 42
MOCK_DEPLOY
chmod 0755 "$repo/deploy.sh"

cat >"$tmp/bin/ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *' mktemp -d /tmp/ci-runner-farm-dev.XXXXXX '*)
    printf 'ssh-stage\n' >>"$TEST_LOG"
    printf '/tmp/ci-runner-farm-dev.ABC123\n'
    ;;
  *' tar -xf - -C '*)
    printf 'ssh-upload\n' >>"$TEST_LOG"
    while IFS= read -r -n 8192 chunk; do :; done || true
    ;;
  *' /bin/bash -s -- '*)
    printf 'ssh-install\n' >>"$TEST_LOG"
    while IFS= read -r line; do :; done
    ;;
  *' /bin/bash -s '*)
    printf 'ssh-rollback\n' >>"$TEST_LOG"
    while IFS= read -r line; do :; done
    ;;
  *' rm -rf -- '*) printf 'ssh-cleanup\n' >>"$TEST_LOG" ;;
  *) printf 'unexpected ssh call: %s\n' "$*" >&2; exit 91 ;;
esac
MOCK_SSH
chmod 0755 "$tmp/bin/ssh"

version=2026.08.04.1615.1-1.8.0-jcuratec.gitlab.dev.0123456789ab
package="ci-runner-farm-jcuratec-dev-$version.tgz"
printf 'mock development package bytes\n' >"$repo/tmp/dev-package/$package"
read -r package_md5 package_sha <<EOF
$(python3 - "$repo/tmp/dev-package/$package" <<'PY'
import hashlib, sys
data = open(sys.argv[1], "rb").read()
print(hashlib.md5(data).hexdigest(), hashlib.sha256(data).hexdigest())
PY
)
EOF
cat >"$repo/tmp/dev-package/ci-runner-farm.plg" <<EOF
<?xml version='1.0' standalone='yes'?>
<!DOCTYPE PLUGIN [
<!ENTITY name "ci-runner-farm">
<!ENTITY version "$version">
<!ENTITY packageName "$package">
<!ENTITY packageMD5 "$package_md5">
<!ENTITY packageSHA256 "$package_sha">
]>
<PLUGIN name="&name;" version="&version;">
<FILE Name="/tmp/&packageName;"><LOCAL>/boot/config/ci-runner-farm-dev/artifacts/&packageName;</LOCAL><MD5>&packageMD5;</MD5><SHA256>&packageSHA256;</SHA256></FILE>
</PLUGIN>
EOF
python3 - "$repo/tmp/dev-package/manifest.json" "$version" "$package" "$package_md5" "$package_sha" <<'PY'
import json, sys
path, version, package, md5, sha = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({
        "schema": 1,
        "name": "ci-runner-farm",
        "mode": "dev",
        "version": version,
        "plugin_file": "ci-runner-farm.plg",
        "package_file": package,
        "package_md5": md5,
        "package_sha256": sha,
        "source_path": "/boot/config/ci-runner-farm-dev/artifacts/" + package,
        "runtime_root": "src/usr/local/emhttp/plugins/ci-runner-farm",
    }, stream, separators=(",", ":"))
    stream.write("\n")
PY

log="$tmp/actions.log"
: >"$log"
TEST_LOG="$log" PATH="$tmp/bin:$PATH" "$repo/install-dev.sh" root@mock-unraid >/dev/null
expected="$(printf 'deploy\nssh-stage\nssh-upload\nssh-install\nssh-cleanup\n')"
[ "$(cat "$log")" = "$expected" ] || fail "mocked successful install order was: $(tr '\n' ' ' <"$log")"

: >"$log"
if TEST_LOG="$log" MOCK_DEPLOY_FAIL=1 PATH="$tmp/bin:$PATH" \
    "$repo/install-dev.sh" root@mock-unraid >/dev/null 2>&1; then
  fail "installer ignored deploy failure"
fi
[ "$(cat "$log")" = deploy ] || fail "flash/upload mutation occurred after deploy failure"

: >"$log"
printf 'tamper\n' >>"$repo/tmp/dev-package/$package"
if TEST_LOG="$log" PATH="$tmp/bin:$PATH" "$repo/install-dev.sh" root@mock-unraid >/dev/null 2>&1; then
  fail "installer accepted a package hash mismatch"
fi
[ ! -s "$log" ] || fail "installer mutated the host before rejecting a package hash mismatch"

: >"$log"
if TEST_LOG="$log" PATH="$tmp/bin:$PATH" "$repo/install-dev.sh" 'root@host;touch_bad' >/dev/null 2>&1; then
  fail "installer accepted an unsafe host"
fi
[ ! -s "$log" ] || fail "unsafe host reached deploy/SSH"

: >"$log"
TEST_LOG="$log" PATH="$tmp/bin:$PATH" "$repo/install-dev.sh" --rollback root@mock-unraid >/dev/null
[ "$(cat "$log")" = ssh-rollback ] || fail "rollback invoked deploy or an unexpected SSH sequence"

echo "install-dev-safety: OK — local validation and failure/commit/rollback ordering are fail-closed"
