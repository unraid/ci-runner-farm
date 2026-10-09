#!/usr/bin/env bash
# Exercise the installed PHP guard with real protected metadata, not a stub.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" -eq 0 ] || { echo 'shared-host-budget: root replay runs in Linux package checks'; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$tmp/provider"
# shellcheck source=/dev/null
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { echo "SHARED HOST BUDGET FAIL: $*" >&2; exit 1; }
php() {
  local code="${2//\/boot\/config\/plugins\/qa-vm-service\//$tmp/provider/}"
  command php -r "$code"
}
fixture() {
  command php -r '
    $root="/mnt/boot/appdata/build-admission";
    $policy=["budget"=>["memoryMiB"=>48000,"vcpus"=>24],"pools"=>["build"=>["minimum"=>1,"maximum"=>3,"cost"=>["memoryMiB"=>12288,"vcpus"=>4]]],"agingSeconds"=>600];
    $shared=["buildOnly"=>true,"policy"=>$policy,"guestOverheadMiB"=>0];
    $config=["stateRoot"=>$root,"sharedCapacity"=>$shared];
    $docs=["host-policy.json"=>["providerConfig"=>$config],"host-plan.json"=>["manifest"=>["providerConfig"=>$config]],"runner-integration.json"=>["buildOnly"=>true,"sharedAdmission"=>["elastic"=>true,"ledgerPath"=>$root."/state/shared-capacity.bolt","policy"=>$policy]]];
    foreach ($docs as $name=>$data) { file_put_contents($argv[1]."/".$name,json_encode($data)); chmod($argv[1]."/".$name,0600); }
  ' "$tmp/provider"
}
fixture
for maximum in 24 64 65; do
  fixture
  command php -r '
    foreach (["host-policy.json","host-plan.json","runner-integration.json"] as $name) {
      $p=$argv[1]."/".$name;$d=json_decode(file_get_contents($p),true);
      if ($name==="host-policy.json") $d["providerConfig"]["sharedCapacity"]["policy"]["pools"]["build"]["maximum"]=(int)$argv[2];
      elseif ($name==="host-plan.json") $d["manifest"]["providerConfig"]["sharedCapacity"]["policy"]["pools"]["build"]["maximum"]=(int)$argv[2];
      else $d["sharedAdmission"]["policy"]["pools"]["build"]["maximum"]=(int)$argv[2];
      file_put_contents($p,json_encode($d));
    }
  ' "$tmp/provider" "$maximum"
  if [ "$maximum" -le 64 ]; then
    [ "$(shared_capacity_build_limits)" = "1|$maximum|12288|4" ] || fail 'supported aggregate expansion rejected'
  elif shared_capacity_build_limits; then fail 'maximum beyond provider cap accepted'; fi
done
fixture
[ "$(shared_capacity_build_limits)" = '1|3|12288|4' ] || fail 'protected build-only floor not read'
# Replay differently serialized Go plan and policy documents. Object order is
# not policy identity; strict scalar types and actual values remain mandatory.
command php -r '
  $p=$argv[1];$d=json_decode(file_get_contents($p),true);
  unset($d["providerConfig"]["sharedCapacity"]["guestOverheadMiB"]);
  $d["providerConfig"]["sharedCapacity"]["policy"]=array_reverse($d["providerConfig"]["sharedCapacity"]["policy"],true);
  file_put_contents($p,json_encode($d));
' "$tmp/provider/host-policy.json"
[ "$(shared_capacity_build_limits)" = '1|3|12288|4' ] || fail 'Go serialized matching policy rejected'
fixture
command php -r '$p=$argv[1];$d=json_decode(file_get_contents($p),true);$d["sharedAdmission"]["policy"]["pools"]["build"]["maximum"]="3";file_put_contents($p,json_encode($d));' "$tmp/provider/runner-integration.json"
if shared_capacity_build_limits; then fail 'scalar type drift accepted'; fi
fixture
RUNNER_MODE=pools GH_SCOPE=org CI_PROVIDER=github AUTOSCALE=true
touch "$CFGDIR/shared-capacity.enabled"
RUNNER_POOLS='v3|build|general-build|unraid,build|1|1|2|0|4|12g|builtin;v3|build-large|build-large||1|0|1|0|4|16g|builtin'
validate_runner_mode || fail 'actual policy guard rejected matching classes'
for doc in host-policy.json host-plan.json runner-integration.json; do
  fixture
  chmod 666 "$tmp/provider/$doc"
  if shared_capacity_build_limits; then fail 'writable document accepted'; fi
  fixture
  mv "$tmp/provider/$doc" "$tmp/provider/saved"
  ln -s "$tmp/provider/saved" "$tmp/provider/$doc"
  if shared_capacity_build_limits; then fail 'symlink document accepted'; fi
  rm "$tmp/provider/$doc"
  fixture
  printf '{broken' > "$tmp/provider/$doc"
  if shared_capacity_build_limits; then fail 'malformed document accepted'; fi
  fixture
  rm "$tmp/provider/$doc"
  if shared_capacity_build_limits; then fail 'missing document accepted'; fi
done
fixture
command php -r '$p=$argv[1];$d=json_decode(file_get_contents($p),true);$d["sharedAdmission"]["policy"]["pools"]["build"]["maximum"]=4;file_put_contents($p,json_encode($d));' "$tmp/provider/runner-integration.json"
if shared_capacity_build_limits; then fail 'integration policy drift accepted'; fi
fixture
command php -r '$p=$argv[1];$d=json_decode(file_get_contents($p),true);$d["manifest"]["providerConfig"]["stateRoot"]="/mnt/other";file_put_contents($p,json_encode($d));' "$tmp/provider/host-plan.json"
if shared_capacity_build_limits; then fail 'signed root drift accepted'; fi
fixture
command php -r '$p=$argv[1];$d=json_decode(file_get_contents($p),true);$d["buildOnly"]=false;file_put_contents($p,json_encode($d));' "$tmp/provider/runner-integration.json"
if shared_capacity_build_limits; then fail 'hosting mode drift accepted'; fi
fixture
chown 65534 "$tmp/provider/host-plan.json"
if shared_capacity_build_limits; then fail 'foreign-owned plan accepted'; fi
echo 'shared-host-budget: protected floor/max, root, policy and hosting identity passed'
