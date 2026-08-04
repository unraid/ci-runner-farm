#!/usr/bin/env bash
# Static safety contracts for the development deploy transaction and generated
# Unraid uninstall action. Package-output assertions live in package-contents.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

DEPLOY="deploy.sh"
BUILD="build-plg.sh"

fail() { printf 'DEPLOY/UNINSTALL SAFETY FAIL: %s\n' "$*" >&2; exit 1; }
first_line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

lock_line="$(first_line "$DEPLOY" 'flock -w 20 8')"
manager_check_line="$(first_line "$DEPLOY" 'owned_managers="$(docker ps -a')"
swap_line="$(first_line "$DEPLOY" 'mv "$stage" "$dest"')"
[ -n "$lock_line" ] && [ -n "$manager_check_line" ] && [ -n "$swap_line" ] \
  || fail "could not locate deploy lock, inactive-state check, and tree swap"
[ "$lock_line" -lt "$manager_check_line" ] && [ "$manager_check_line" -lt "$swap_line" ] \
  || fail "deploy does not hold fleet.lock across inactive-state verification and tree swap"

grep -qF 'exec 8>"$rundir/fleet.lock"' "$DEPLOY" \
  || fail "deploy does not open the engine-compatible fleet lock"
grep -qF 'COPYFILE_DISABLE=1 tar --no-xattrs -C "$SRC" -cf - .' "$DEPLOY" \
  || fail "deploy does not suppress macOS AppleDouble metadata at the source"
grep -qF "find \"\$stage\" -name '._*' -print" "$DEPLOY" \
  || fail "deploy does not reject AppleDouble metadata in the staged runtime"
if sed -n "${lock_line},${swap_line}p" "$DEPLOY" | grep -F 'flock -u 8' >/dev/null; then
  fail "deploy releases fleet.lock before the staged tree swap"
fi
grep -qF "docker ps -a" "$DEPLOY" || fail "deploy does not inspect stopped Docker objects"
if grep -qF "docker ps -q --filter 'label=net.unraid.ci-runner-farm.managed=true'" "$DEPLOY"; then
  fail "deploy still checks only running managers"
fi
for label in \
  'label=net.unraid.ci-runner-farm.managed=true' \
  'label=net.unraid.ci-runner-farm.sidecar=true' \
  'label=net.unraid.ci-runner-farm.role=dind' \
  'label=com.gitlab.gitlab-runner.managed=true' \
  'label=net.unraid.ci-runner-farm.provider=gitlab' \
  'label=net.unraid.ci-runner-farm.slot' \
  'label=net.unraid.ci-runner-farm.resource=true' \
  'label=net.unraid.ci-runner-farm.role=mirror' \
  'label=net.unraid.ci-runner-farm.provider=github' \
  'label=net.unraid.ci-runner-farm.role=validate' \
  'label=net.unraid.ci-runner-farm.role=validate-job'
do
  grep -qF "$label" "$DEPLOY" || fail "deploy ownership scan is missing $label"
done
mirror_block="$(sed -n '/^owned_mirrors="$(docker ps -a/,/^}/p' "$DEPLOY")"
printf '%s\n' "$mirror_block" | grep -qF "'label=net.unraid.ci-runner-farm.resource=true'" \
  && printf '%s\n' "$mirror_block" | grep -qF "'label=net.unraid.ci-runner-farm.role=mirror'" \
  || fail "deploy mirror scan does not require the complete owned resource/role contract"
github_validation_block="$(sed -n '/^owned_github_validations="$(docker ps -a/,/^}/p' "$DEPLOY")"
for label in \
  "'label=net.unraid.ci-runner-farm.managed=true'" \
  "'label=net.unraid.ci-runner-farm.provider=github'" \
  "'label=net.unraid.ci-runner-farm.role=validate'"
do
  printf '%s\n' "$github_validation_block" | grep -qF "$label" \
    || fail "deploy GitHub validation scan is missing exact contract label $label"
done
gitlab_validation_block="$(sed -n '/^owned_gitlab_validations="$(docker ps -a/,/^}/p' "$DEPLOY")"
for label in \
  "'label=net.unraid.ci-runner-farm.provider=gitlab'" \
  "'label=net.unraid.ci-runner-farm.role=validate-job'" \
  "'label=net.unraid.ci-runner-farm.slot'"
do
  printf '%s\n' "$gitlab_validation_block" | grep -qF "$label" \
    || fail "deploy GitLab validation scan is missing exact contract label $label"
done
for owned in owned_mirrors owned_legacy_mirrors owned_github_validations owned_gitlab_validations; do
  sed -n "${manager_check_line},${swap_line}p" "$DEPLOY" | grep -F '[ -n "$'"$owned"'" ]' >/dev/null \
    || fail "deploy inactive decision ignores $owned"
done
for provenance in \
  "legacy_name\" = /ci-runner-mirror" \
  "legacy_image\" = registry:2" \
  'legacy_source" = "$legacy_cache_root/registry-mirror"' \
  'REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io'
do
  grep -qF "$provenance" "$DEPLOY" \
    || fail "deploy legacy mirror recognition is missing provenance check: $provenance"
done
grep -qF "printf '%s\\n' \"\$all_container_names\" | grep -qxF 'ci-runner-mirror'" "$DEPLOY" \
  || fail "deploy does not distinguish an absent mirror from an inspect failure"
for failure in \
  'Docker CLI is unavailable; cannot prove the fleet is inactive' \
  'cannot enumerate CI Runner Farm managers; refusing deployment' \
  'cannot enumerate GitLab DinD sidecars; refusing deployment' \
  'cannot enumerate GitLab host-socket jobs/helpers/services; refusing deployment' \
  'cannot enumerate shared registry mirrors; refusing deployment' \
  'cannot enumerate Docker names for legacy mirror verification; refusing deployment' \
  'cannot verify fixed-name registry mirror provenance; refusing deployment' \
  'cannot enumerate GitHub validation containers; refusing deployment' \
  'cannot enumerate GitLab validation jobs; refusing deployment' \
  'cannot verify CI Runner Farm background-daemon state; refusing deployment'
do
  grep -qF "$failure" "$DEPLOY" || fail "deploy lacks fail-closed diagnostic: $failure"
done

remove_block="$(awk '
  /<FILE Run="\/bin\/bash" Method="remove">/ { emit=1 }
  emit { print }
  emit && /<\/FILE>/ { exit }
' "$BUILD")"
[ -n "$remove_block" ] || fail "could not locate generated plugin remove action"
printf '%s\n' "$remove_block" | grep -qF 'set -euo pipefail' \
  || fail "plugin remove action lacks strict shell error handling"
printf '%s\n' "$remove_block" | grep -qF 'if ! "\$PLGDIR/include/runner-farm.sh" stop' \
  || fail "plugin remove action does not surface fleet stop failures"
for fallback_contract in \
  'cleanup engine is missing and Docker is unavailable' \
  'label=net.unraid.ci-runner-farm.managed=true' \
  'label=net.unraid.ci-runner-farm.sidecar=true' \
  'label=net.unraid.ci-runner-farm.role=mirror' \
  'label=com.gitlab.gitlab-runner.managed=true' \
  'label=net.unraid.ci-runner-farm.provider=gitlab' \
  'cleanup engine is missing while plugin-owned Docker resources still exist'
do
  printf '%s\n' "$remove_block" | grep -qF "$fallback_contract" \
    || fail "plugin remove action lacks missing-engine safety contract: $fallback_contract"
done
printf '%s\n' "$remove_block" | grep -qF 'if ! rm -rf -- "\$PLGDIR" || [ -e "\$PLGDIR" ]; then' \
  || fail "plugin remove action does not fail on incomplete runtime deletion"
printf '%s\n' "$remove_block" | grep -qF 'if ! rm -f -- "\$CFGDIR"/${NAME}-*.tgz; then' \
  || fail "plugin remove action does not fail on cached-package deletion"

runtime_delete_line="$(printf '%s\n' "$remove_block" | grep -nF 'if ! rm -rf -- "\$PLGDIR"' | head -1 | cut -d: -f1)"
package_delete_line="$(printf '%s\n' "$remove_block" | grep -nF 'if ! rm -f -- "\$CFGDIR"/${NAME}-*.tgz' | head -1 | cut -d: -f1)"
success_line="$(printf '%s\n' "$remove_block" | grep -nF 'ci-runner-farm removed. Config + credentials left' | head -1 | cut -d: -f1)"
[ "$runtime_delete_line" -lt "$success_line" ] && [ "$package_delete_line" -lt "$success_line" ] \
  || fail "plugin remove action can announce success before cleanup completes"

echo "deploy-uninstall-safety: OK — deploy is fleet-locked/fail-closed and uninstall propagates cleanup failures"
