#!/usr/bin/env bash
# Layer-integrity self-heal: the read-only checker must flag exactly the cached
# layers whose memory-mapped database files no longer match their recorded
# tar-split checksums, never follow links out of the store, stay incremental
# and bounded, and the healer must evict only in an idle, running slot, at most
# once per bound interval, failing open everywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
realpath -m -- / >/dev/null 2>&1 || { echo 'SKIP: GNU realpath required'; exit 0; }
command -v perl >/dev/null 2>&1 || { echo 'SKIP: perl required'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: python3 required'; exit 0; }

tmp="$(realpath -m -- "$(mktemp -d)")"
trap 'rm -rf "$tmp"' EXIT
CHECKER=src/usr/local/emhttp/plugins/ci-runner-farm/include/layer-integrity.pl
fail() { printf 'LAYER INTEGRITY FAIL: %s\n' "$*" >&2; exit 1; }

# ── Fixture builder ──────────────────────────────────────────────────────────
# build-store <store> <spec.json>: writes an overlay2 store in Docker's on-disk
# layout. Each layer lists files with the bytes recorded at registration
# ("recorded") and, optionally, different bytes now on disk ("disk"), so a
# seeded fault is a recorded/disk mismatch exactly like the real failure.
cat > "$tmp/build-store.py" <<'PY'
import base64, gzip, hashlib, json, os, sys, time

POLY = 0xD800000000000000
TABLE = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ POLY if c & 1 else c >> 1
    TABLE.append(c)

def crc64(data):
    crc = 0xFFFFFFFFFFFFFFFF
    for b in data:
        crc = TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFFFFFFFFFF

# CRC-64/GO-ISO standard check value: the fixtures themselves are trustworthy.
assert crc64(b"123456789") == 0xB90956C775A41001

store, spec_path = sys.argv[1], sys.argv[2]
spec = json.load(open(spec_path))
layerdb = os.path.join(store, "image/overlay2/layerdb/sha256")
imagedb = os.path.join(store, "image/overlay2/imagedb/content/sha256")
os.makedirs(layerdb, exist_ok=True)
os.makedirs(imagedb, exist_ok=True)
diff_ids, layer_chain = {}, {}
for layer in spec["layers"]:
    lines, pos = [], 0
    for f in layer["files"]:
        recorded = f["recorded"].encode()
        lines.append(json.dumps({"type": 2, "payload": base64.b64encode(b"hdr").decode(), "position": pos}, separators=(",", ":"))); pos += 1
        entry = {"type": 1, "name": f["name"], "size": len(recorded),
                 "payload": base64.b64encode(crc64(recorded).to_bytes(8, "big")).decode() if recorded else None,
                 "position": pos}
        lines.append(json.dumps(entry, separators=(",", ":"))); pos += 1
    diff_id = "sha256:" + hashlib.sha256(layer["id"].encode()).hexdigest()
    diff_ids[layer["id"]] = diff_id
    parent = layer.get("parent")
    chain = diff_id if not parent else "sha256:" + hashlib.sha256(
        (layer_chain[parent] + " " + diff_id).encode()).hexdigest()
    layer_chain[layer["id"]] = chain
    d = os.path.join(layerdb, chain[7:])
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "cache-id"), "w").write(layer["cache"])
    open(os.path.join(d, "diff"), "w").write(diff_id)
    with gzip.open(os.path.join(d, "tar-split.json.gz"), "wt") as g:
        g.write("\n".join(lines) + "\n")
    age = layer.get("age", 3600)
    t = time.time() - age
    os.utime(os.path.join(d, "tar-split.json.gz"), (t, t))
    diff = os.path.join(store, "overlay2", layer["cache"], "diff")
    os.makedirs(diff, exist_ok=True)
    for f in layer["files"]:
        if f.get("absent"):
            continue
        p = os.path.join(diff, f["name"])
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(f.get("disk", f["recorded"]).encode())
    print(layer["id"], chain[7:])
for image in spec.get("images", []):
    ids = [diff_ids[l] for l in image["layers"]]
    body = json.dumps({"architecture": "amd64", "rootfs": {"type": "layers", "diff_ids": ids}}, separators=(",", ":"))
    image_id = hashlib.sha256(body.encode()).hexdigest()
    open(os.path.join(imagedb, image_id), "w").write(body)
    print("image", image["name"], image_id)
PY

build() { mkdir -p "$1"; python3 "$tmp/build-store.py" "$1" "$2" > "$1.ids"; }
chain_of() { awk -v l="$2" '$1 == l { print $2 }' "$1.ids"; }
image_of() { awk -v n="$2" '$1 == "image" && $2 == n { print $3 }' "$1.ids"; }
check() { perl "$CHECKER" "$1" "$1.verified" "${2:-30}" "${3:-0}" "${4:-67108864}"; }

# ── Checker: seeded faults ───────────────────────────────────────────────────
S="$tmp/a/docker/ci-runner-build-2"
cat > "$tmp/a.json" <<'JSON'
{"layers": [
  {"id": "base", "cache": "aaa1", "files": [
    {"name": "usr/lib/sysimage/rpm/rpmdb.sqlite-shm", "recorded": "header-v1"},
    {"name": "usr/bin/tool", "recorded": "binary", "disk": "BINARY CHANGED"}]},
  {"id": "dnf", "cache": "bbb2", "parent": "base", "files": [
    {"name": "usr/lib/sysimage/rpm/rpmdb.sqlite-shm", "recorded": "live wal-index", "disk": "closed wal-idx"},
    {"name": "usr/lib/sysimage/libdnf5/transaction_history.sqlite-wal", "recorded": "wal frames"},
    {"name": "var/lib/rpm/__db.001", "recorded": "region"}]},
  {"id": "sized", "cache": "ccc3", "parent": "dnf", "files": [
    {"name": "var/lib/app/state.db-wal", "recorded": "twelve bytes", "disk": "short"}]},
  {"id": "gone", "cache": "ddd4", "parent": "sized", "files": [
    {"name": "var/lib/rpm/__db.002", "recorded": "region", "absent": true}]},
  {"id": "vector", "cache": "eee5", "parent": "gone", "files": [
    {"name": "srv/check-shm", "recorded": "123456789"}]}
 ],
 "images": [
  {"name": "clean", "layers": ["base"]},
  {"name": "uses-dnf", "layers": ["base", "dnf"]},
  {"name": "uses-all", "layers": ["base", "dnf", "sized", "gone", "vector"]}
 ]}
JSON
build "$S" "$tmp/a.json"
out="$(check "$S")"
bad_chains="$(printf '%s\n' "$out" | awk '$1 == "BAD" { print $2 }' | sort -u)"
expected="$(printf '%s\n' "$(chain_of "$S" dnf)" "$(chain_of "$S" sized)" "$(chain_of "$S" gone)" | sort -u)"
[ "$bad_chains" = "$expected" ] || fail "wrong bad layers: $out"
grep -qx "BAD $(chain_of "$S" dnf) checksum usr/lib/sysimage/rpm/rpmdb.sqlite-shm" <<< "$out" \
  || fail "checksum fault not reported: $out"
grep -qx "BAD $(chain_of "$S" sized) size var/lib/app/state.db-wal" <<< "$out" || fail "size fault not reported"
grep -qx "BAD $(chain_of "$S" gone) missing var/lib/rpm/__db.002" <<< "$out" || fail "missing file not reported"
# Only memory-mapped database files are read: a changed binary is out of scope.
grep -q 'usr/bin/tool' <<< "$out" && fail "checker read a file outside its scope"
grep -q "$(chain_of "$S" vector)" <<< "$out" && fail "standard CRC64 vector rejected"
grep -qx 'SUMMARY checked=5 cached=0 young=0 skipped=0 bytes=[0-9]*' <<< "$out" || fail "bad summary: $out"

# Incremental: consistent layers are cached; bad layers are rechecked every pass.
grep -q "^$(chain_of "$S" base) aaa1$" "$S.verified" || fail "consistent layer not cached"
grep -q "^$(chain_of "$S" dnf) " "$S.verified" && fail "bad layer cached as verified"
out="$(check "$S")"
grep -qx 'SUMMARY checked=3 cached=2 young=0 skipped=0 bytes=[0-9]*' <<< "$out" || fail "cache not used: $out"
# The cache forgets layers that no longer exist.
echo "$(printf 'f%.0s' $(seq 64)) zzz9" >> "$S.verified"
check "$S" >/dev/null
grep -q zzz9 "$S.verified" && fail "cache kept a deleted layer"

# Bounds: young layers wait, oversized entries are skipped, zero budget is partial.
S2="$tmp/b/docker/ci-runner-build-3"
cat > "$tmp/b.json" <<'JSON'
{"layers": [{"id": "fresh", "cache": "fff6", "age": 5, "files": [
  {"name": "a/x.sqlite-shm", "recorded": "one", "disk": "two"}]},
 {"id": "big", "cache": "ggg7", "files": [
  {"name": "a/y.sqlite-wal", "recorded": "0123456789abcdef", "disk": "fedcba9876543210"}]}]}
JSON
build "$S2" "$tmp/b.json"
out="$(check "$S2" 30 120 8)"
grep -q '^BAD' <<< "$out" && fail "young or oversized entry reported: $out"
grep -qx 'SUMMARY checked=1 cached=0 young=1 skipped=1 bytes=0' <<< "$out" || fail "bounds summary: $out"
grep -q "$(chain_of "$S2" fresh)" "$S2.verified" && fail "young layer cached before it was checked"
rm -f "$S2.verified"
out="$(check "$S2" 0 0)"
grep -qx 'SUMMARY checked=0 cached=0 young=0 skipped=0 bytes=0 partial' <<< "$out" || fail "zero budget not partial: $out"

# Links: a symlinked directory inside the diff, or a symlinked diff, is never followed.
S3="$tmp/c/docker/ci-runner-build-4"
cat > "$tmp/c.json" <<'JSON'
{"layers": [{"id": "link", "cache": "hhh8", "files": [
  {"name": "var/lib/rpm/rpmdb.sqlite-shm", "recorded": "outside", "absent": true}]},
 {"id": "linkdiff", "cache": "iii9", "files": [
  {"name": "x/y-shm", "recorded": "outside", "absent": true}]}]}
JSON
build "$S3" "$tmp/c.json"
mkdir -p "$tmp/outside/rpm"; printf 'outside' > "$tmp/outside/rpm/rpmdb.sqlite-shm"
mkdir -p "$S3/overlay2/hhh8/diff/var/lib"; ln -s "$tmp/outside/rpm" "$S3/overlay2/hhh8/diff/var/lib/rpm"
rm -rf "$S3/overlay2/iii9/diff"; mkdir -p "$tmp/outside/x"; printf 'outside' > "$tmp/outside/x/y-shm"
ln -s "$tmp/outside" "$S3/overlay2/iii9/diff"
out="$(check "$S3")"
grep -qx "BAD $(chain_of "$S3" link) missing var/lib/rpm/rpmdb.sqlite-shm" <<< "$out" \
  || fail "followed a symlinked directory: $out"
grep -q "$(chain_of "$S3" linkdiff)" <<< "$out" && fail "read through a symlinked diff directory"
# Unsafe member names are rejected rather than resolved.
for name in '../escape-shm' '/abs-shm' 'a/../../b-shm'; do
  S4="$tmp/d$RANDOM/docker/ci-runner-build-5"
  printf '{"layers":[{"id":"n","cache":"jjj1","files":[{"name":"%s","recorded":"x","absent":true}]}]}' "$name" > "$tmp/d.json"
  build "$S4" "$tmp/d.json"
  # Matching bytes exist where the unsafe name would resolve outside the diff.
  mkdir -p "$S4/overlay2/jjj1/diff/a"
  printf 'x' > "$S4/overlay2/jjj1/escape-shm"; printf 'x' > "$S4/overlay2/jjj1/b-shm"
  check "$S4" | grep -q '^BAD .* missing ' || fail "unsafe member name $name was resolved"
done
# "./"-prefixed member names (written by some image builders) resolve normally.
S5="$tmp/e/docker/ci-runner-build-6"
cat > "$tmp/e.json" <<'JSON'
{"layers": [{"id": "dot", "cache": "lll1", "files": [
  {"name": "./var/lib/rpm/rpmdb.sqlite-shm", "recorded": "same bytes"},
  {"name": "./var/lib/rpm/./other.sqlite-wal", "recorded": "recorded", "disk": "changed!"}]}]}
JSON
build "$S5" "$tmp/e.json"
out="$(check "$S5")"
grep -q 'rpmdb.sqlite-shm' <<< "$out" && fail "./-prefixed consistent member reported: $out"
grep -qx "BAD $(chain_of "$S5" dot) checksum ./var/lib/rpm/./other.sqlite-wal" <<< "$out" \
  || fail "./-prefixed corrupt member not checked: $out"
# No store yet: nothing to do, and success.
check "$tmp/none" | grep -q . && fail "missing store produced output"
perl "$CHECKER" >/dev/null 2>&1 && fail "usage error accepted"

# ── Shell integration ────────────────────────────────────────────────────────
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
export CRF_LAYER_SCAN_MIN_AGE=0 CRF_LAYER_SCAN_INTERVAL=600 CRF_LAYER_HEAL_MIN_INTERVAL=3600
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
CI_PROVIDER=github DIND=true SHARE_DOCKER_SOCK=false
crf_safe_cache_root() { printf '%s' "$tmp/a"; }
slot=ci-runner-build-2
slot_id="$(printf '2%.0s' $(seq 64))"
managed_names() { printf '%s\n' "$slot"; }
managed_runner_snapshot() { printf '%s|github|runner|2|gen\n' "$slot_id"; }
state=idle running=true exists=false exec_rc=0
DOCKER_LOG="$tmp/docker.log"; : > "$DOCKER_LOG"
docker() {
  case "$1" in
    inspect)
      case "$2" in
        -f) printf '%s\n' "$running" ;;
        *) [ "$exists" = true ] ;;
      esac ;;
    exec) shift; printf 'exec %s\n' "$*" | tr '\n' ' ' >> "$DOCKER_LOG"; echo >> "$DOCKER_LOG"; return "$exec_rc" ;;
    *) printf 'docker %s\n' "$*" >> "$DOCKER_LOG" ;;
  esac
}
runner_state() { printf '%s\n' "$state"; }
# timeout(1) cannot run shell functions; run the wrapped command in-process.
timeout() {
  while [ "$#" -gt 0 ]; do case "$1" in -k) shift 2 ;; -*) shift ;; *) break ;; esac; done
  shift; "$@"
}
flag="$CRF_RUNDIR/layer-corrupt.$slot"
reset() { rm -f "$CRF_RUNDIR"/layer-* ; : > "$DOCKER_LOG"; state=idle running=true exists=false exec_rc=0; }

# A scan records the bad chains and the images that reference them.
reset
log_out="$(layer_integrity_scan "$slot" 2>&1)"
[ -f "$flag" ] || fail "scan did not flag corrupt layers"
for l in dnf sized gone; do grep -qx "chain $(chain_of "$S" "$l")" "$flag" || fail "flag misses chain $l"; done
grep -qx "image sha256:$(image_of "$S" uses-dnf)" "$flag" || fail "flag misses image using the bad layer"
grep -qx "image sha256:$(image_of "$S" uses-all)" "$flag" || fail "flag misses image with a deep bad layer"
grep -q "$(image_of "$S" clean)" "$flag" && fail "flag lists an image without bad layers"
grep -q 'layer-integrity: ci-runner-build-2 holds 3 cached layer(s) that cannot be exported, used by 2 image(s)' <<< "$log_out" \
  || fail "scan finding not logged: $log_out"
# A store whose container still exists is left to the idle-slot pass.
reset; exists=true
layer_integrity_precreate "$slot" 2>/dev/null
[ ! -f "$flag" ] && [ -d "$S/image" ] || fail "precreate touched a store that is still in use"

# Slot creation with a flagged store: the store is moved aside before start,
# recreated empty, and deleted in the background without holding the fleet lock.
EV="$tmp/ev"; EVS="$EV/docker/$slot"
fixture_refs='mount|/'; fixture_refs_rc=0
crf_docker_storage_references() { printf '%s\n' "$fixture_refs"; return "$fixture_refs_rc"; }
fresh_store() { rm -rf "$EV"; build "$EVS" "$tmp/a.json"; touch "$EVS/volumes-marker"; }
wait_reaped() {
  local i
  for i in $(seq 1 50); do [ -z "$(ls -A "$EV/docker-evicted" 2>/dev/null)" ] && return 0; sleep 0.1; done
  return 1
}
crf_safe_cache_root() { printf '%s' "$EV"; }
reset; fresh_store
exec 8>"$tmp/fleet.lock"; flock 8
# Hold the reaper alive until released so lock inheritance would show. The stub
# runs after the reaper has set up its descriptors, so its signal means "ready".
reaper_up="$tmp/reaper.up"; reaper_go="$tmp/reaper.go"; rm -f "$reaper_up" "$reaper_go"
ionice() {
  local i
  : > "$reaper_up"
  for i in $(seq 1 100); do [ -e "$reaper_go" ] && break; sleep 0.1; done
  shift 2; "$@"
}
log_out="$(layer_integrity_precreate "$slot" 2>&1)"
# Close (not unlock) our descriptor: an inherited copy would keep the lock held.
exec 8>&-
for i in $(seq 1 50); do [ -e "$reaper_up" ] && break; sleep 0.1; done
[ -e "$reaper_up" ] || fail "store reaper did not start"
flock -n "$tmp/fleet.lock" true || fail "background store deletion holds the fleet lock"
: > "$reaper_go"
unset -f ionice
[ -d "$EVS" ] && [ -z "$(ls -A "$EVS")" ] || fail "flagged store not replaced by an empty one"
[ ! -e "$flag" ] && [ ! -e "$CRF_RUNDIR/layer-verified.$slot" ] && [ ! -e "$CRF_RUNDIR/layer-scan.$slot" ] \
  || fail "eviction left stale per-slot state"
grep -q "evicted $slot's Docker store before start" <<< "$log_out" || fail "store eviction not logged: $log_out"
wait_reaped || fail "moved-aside store was not deleted"
# Anything uncertain keeps the store and its pending eviction.
for case in consumer parent mount refs-failure trash-link; do
  reset; fresh_store; fixture_refs='mount|/'; fixture_refs_rc=0
  case "$case" in
    consumer) fixture_refs="consumer|$EVS" ;;
    parent) fixture_refs="consumer|$EV" ;;
    mount) fixture_refs="mount|$EVS/overlay2/merged" ;;
    refs-failure) fixture_refs_rc=1 ;;
    trash-link) mkdir -p "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$EV/docker-evicted" ;;
  esac
  layer_integrity_precreate "$slot" 2>/dev/null || fail "$case: precreate failed"
  [ -f "$EVS/volumes-marker" ] && [ -f "$flag" ] || fail "$case: store evicted despite doubt"
done
[ -z "$(ls -A "$tmp/elsewhere")" ] || fail "store moved through a symlinked trash directory"
# A clean store is never evicted.
printf '{"layers":[{"id":"ok","cache":"kkk1","files":[{"name":"a/z.sqlite-shm","recorded":"same"}]}]}' > "$tmp/clean.json"
build "$tmp/clean/docker/$slot" "$tmp/clean.json"
reset
crf_safe_cache_root() { printf '%s' "$tmp/clean"; }
layer_integrity_precreate "$slot" 2>/dev/null
[ -d "$tmp/clean/docker/$slot/image" ] || fail "clean store evicted"
# The lifecycle pass finishes deleting leftovers from an interrupted reaper.
crf_safe_cache_root() { printf '%s' "$EV"; }
reset; rm -rf "$EV"; mkdir -p "$EV/docker-evicted/leftover/sub"; date +%s > "$CRF_RUNDIR/layer-scan.$slot"
heal_corrupt_layers 2>/dev/null
wait_reaped || fail "leftover moved-aside store not deleted by the lifecycle pass"
crf_safe_cache_root() { printf '%s' "$tmp/a"; }

# Idle, running slot: one eviction with the referenced image IDs, then bounded.
reset
heal_corrupt_layers 2>/dev/null || fail "heal pass failed"
grep -q "^exec $slot sh -c " "$DOCKER_LOG" || fail "eviction did not run in the slot: $(cat "$DOCKER_LOG")"
grep -q "sha256:$(image_of "$S" uses-dnf)" "$DOCKER_LOG" && grep -q "sha256:$(image_of "$S" uses-all)" "$DOCKER_LOG" \
  || fail "eviction did not receive the referencing images"
grep -q "$(image_of "$S" clean)" "$DOCKER_LOG" && fail "eviction targeted an unrelated image"
grep -q 'builder prune --all --force' "$DOCKER_LOG" || fail "eviction does not prune the build cache"
[ ! -f "$flag" ] && [ -f "$CRF_RUNDIR/layer-healed.$slot" ] || fail "eviction state not recorded"
# The store is unchanged (the mock did not evict), so the forced rescan re-flags,
# and the per-slot bound stops a second eviction inside the interval.
: > "$DOCKER_LOG"
heal_corrupt_layers 2>/dev/null
[ -f "$flag" ] || fail "rescan after eviction did not confirm"
grep -q '^exec' "$DOCKER_LOG" && fail "second eviction inside the bound interval"

# Busy, starting, or stopped slots are never touched; the flag waits.
for case in busy starting stopped; do
  reset; layer_integrity_scan "$slot" 2>/dev/null
  case "$case" in stopped) running=false ;; *) state="$case" ;; esac
  heal_corrupt_layers 2>/dev/null
  grep -q '^exec' "$DOCKER_LOG" && fail "$case slot was touched"
  [ -f "$flag" ] || fail "$case slot lost its pending eviction"
done

# A job arriving mid-eviction stops it and keeps the slot eligible.
reset; layer_integrity_scan "$slot" 2>/dev/null; exec_rc=20
heal_corrupt_layers 2>/dev/null || fail "job arrival treated as failure"
[ -f "$flag" ] && [ ! -f "$CRF_RUNDIR/layer-healed.$slot" ] || fail "interrupted eviction not retried"
# A failed eviction is reported, keeps the flag, and consumes the bound.
reset; layer_integrity_scan "$slot" 2>/dev/null; exec_rc=21
if heal_corrupt_layers 2>/dev/null; then fail "failed eviction reported success"; fi
[ -f "$flag" ] && [ -f "$CRF_RUNDIR/layer-healed.$slot" ] || fail "failed eviction state wrong"

# Idle-slot scans respect their interval and clear a flag once the store is clean.
reset
date +%s > "$CRF_RUNDIR/layer-scan.$slot"
heal_corrupt_layers 2>/dev/null
[ ! -f "$flag" ] && [ ! -s "$DOCKER_LOG" ] && [ ! -f "$CRF_RUNDIR/layer-verified.$slot" ] \
  || fail "idle scan ran inside its interval"
printf 'chain %s\n' "$(printf 'e%.0s' $(seq 64))" > "$flag"
crf_safe_cache_root() { printf '%s' "$tmp/clean"; }   # same slot, no corrupt layers
rm -f "$CRF_RUNDIR/layer-scan.$slot"
log_out="$(heal_corrupt_layers 2>&1)"
[ ! -f "$flag" ] && [ ! -s "$DOCKER_LOG" ] || fail "flag not cleared by the clean full scan itself"
grep -q 'no longer holds corrupt layers' <<< "$log_out" || fail "flag clearing not logged"
crf_safe_cache_root() { printf '%s' "$tmp/a"; }

# Fail open: a checker crash, an unsafe store, or a non-DinD farm never blocks.
reset
SCRIPT_DIR="$tmp/missing" layer_integrity_scan "$slot" 2>/dev/null || fail "checker failure blocked the caller"
[ ! -f "$flag" ] || fail "checker failure invented a flag"
reset; mv "$tmp/a/docker" "$tmp/a/real-docker"; ln -s "$tmp/a/real-docker" "$tmp/a/docker"
log_out="$(layer_integrity_precreate "$slot" 2>&1)"
[ ! -f "$flag" ] && [ -d "$tmp/a/real-docker/$slot/image" ] && [ ! -e "$tmp/a/docker-evicted" ] \
  && ! grep -q layer-integrity <<< "$log_out" || fail "scanned or evicted through a symlinked store"
rm "$tmp/a/docker"; mv "$tmp/a/real-docker" "$tmp/a/docker"
reset; DIND=false
layer_integrity_precreate "$slot" 2>/dev/null; heal_corrupt_layers 2>/dev/null
[ ! -f "$flag" ] && [ ! -s "$DOCKER_LOG" ] || fail "ran without a per-slot Docker store"
DIND=true

# The lifecycle tick runs the pass and survives its failure.
grep -q 'heal_corrupt_layers' <(declare -f lifecycle_tick) || fail "lifecycle tick does not run the heal pass"
grep -q 'docker-evicted' <<< "$(declare -f cmd_prune_cache)" || fail "prune-cache leaves moved-aside stores behind"
grep -q 'layer_integrity_precreate "\$name"' <(declare -f github_start_one) || fail "slot creation does not scan"
grep -q 'layer_integrity_precreate "\$name"' <(declare -f cmd_recycle) || fail "recycle does not scan"

echo "layer-integrity: ok"
