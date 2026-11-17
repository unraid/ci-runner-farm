#!/usr/bin/env bash
# Opt-in removal of superseded runner images from the host Docker store: the
# configured image of every pool and the newest previous image always stay.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'RUNNER IMAGE PRUNE FAIL: %s\n' "$*" >&2; exit 1; }
repo=ghcr.io/unraid/ci-runner-image
d() { printf 'sha256:%064d' "$1"; }
cur="$repo@$(d 1)"; evid="$repo@$(d 2)"
export IMAGES="$tmp/images"; mkdir -p "$IMAGES"
# id|created|refs (space separated)
img() { printf '%s|%s|%s\n' "$2" "$3" "$4" > "$IMAGES/$1"; }
reset() {
  rm -f "$IMAGES"/*
  img cur  "$(d 11)" 2026-11-17T00:00:00Z "$cur"
  img evid "$(d 12)" 2026-11-16T00:00:00Z "$evid"
  img prev "$(d 13)" 2026-11-15T00:00:00Z "$repo@$(d 3)"
  img old1 "$(d 14)" 2026-11-10T00:00:00Z "$repo@$(d 4) $repo:sha-old1"
  img old2 "$(d 15)" 2026-11-01T00:00:00Z "$repo@$(d 5)"
  img used "$(d 16)" 2026-10-01T00:00:00Z "$repo@$(d 6)"
  img shared "$(d 18)" 2026-09-01T00:00:00Z "$repo@$(d 8) localhost:5000/mine:keep"
  img other "$(d 17)" 2025-01-01T00:00:00Z "registry:2"
  : > "$tmp/calls"
}
docker() {
  local f id
  case "$1 $2" in
    'image inspect')
      shift 2; [ "$1" = --format ] && shift 2
      for ref in "$@"; do
        for f in "$IMAGES"/*; do
          IFS='|' read -r id created refs < "$f"
          if [ "$ref" = "$id" ] || grep -qw -- "$ref" <<< "$refs"; then
            printf '%s|%s|%s\n' "$id" "$created" "$refs"; continue 2
          fi
        done
        return 1
      done ;;
    'image ls') for f in "$IMAGES"/*; do cut -d'|' -f1 "$f"; done ;;
    'ps -aq') echo container-1 ;;
    'inspect --format') printf '%s\n' "$(d 16)" "$(d 12)" ;;
    'image rm')
      echo "rm $3" >> "$tmp/calls"
      for f in "$IMAGES"/*; do
        IFS='|' read -r id created refs < "$f"
        case " $refs " in *" $3 "*) refs=" $refs "; refs="${refs/ $3 / }"; refs="$(xargs <<< "$refs")"
          [ -n "$refs" ] && printf '%s|%s|%s\n' "$id" "$created" "$refs" > "$f" || rm -f "$f"; return 0 ;; esac
        [ "$3" = "$id" ] && { rm -f "$f"; return 0; }
      done
      return 1 ;;
    *) fail "unexpected docker $*" ;;
  esac
}
CI_PROVIDER=github; GH_SCOPE=org; RUNNER_MODE=pools; IMAGE_SOURCE=remote
RUNNER_POOLS="v3|build|general-build|linux,x64|9|9|18|1|4|16g|$cur;v3|build-evidence|evidence-wait|evidence-only|3|3|10|1|1|2g|$evid"
pool_records_prime

reset; crf_runner_image_prune
[ ! -s "$tmp/calls" ] || fail 'pruned without the opt-in'

RUNNER_IMAGE_PRUNE=true
reset; crf_runner_image_prune > "$tmp/log" 2>&1 || fail "prune failed: $(cat "$tmp/log")"
for gone in old1 old2; do [ ! -e "$IMAGES/$gone" ] || fail "superseded image $gone kept"; done
grep -q "removed 2 superseded runner image" "$tmp/log" || fail "removal not logged: $(cat "$tmp/log") calls: $(tr "\n" " " < "$tmp/calls")"
for kept in cur evid prev used other shared; do [ -e "$IMAGES/$kept" ] || fail "image $kept removed"; done
# A reference outside the runner repositories keeps its image and its tag.
grep -q 'localhost:5000/mine:keep' "$IMAGES/shared" || fail 'a foreign tag was removed'
# GitLab job images are not fleet-owned.
touch -d '2 hours ago' "$CRF_RUNDIR/runner-image-prune.last"
reset; CI_PROVIDER=gitlab crf_runner_image_prune > "$tmp/log" 2>&1
[ ! -s "$tmp/calls" ] || fail 'pruned GitLab images'
# At most three removals per pass.
touch -d '2 hours ago' "$CRF_RUNDIR/runner-image-prune.last"
reset; for n in 1 2 3 4 5; do img "extra$n" "$(d $((20 + n)))" "2026-08-0${n}T00:00:00Z" "$repo@$(d $((30 + n)))"; done
crf_runner_image_prune > "$tmp/log" 2>&1
[ "$(grep -c '^rm ' "$tmp/calls")" -le 6 ] && grep -q 'removed 3 superseded' "$tmp/log" || fail "pass not bounded: $(cat "$tmp/calls")"
! grep -q -- '--force\|-f ' "$tmp/calls" || fail 'forced removal'
# Hourly at most.
reset; crf_runner_image_prune > "$tmp/log" 2>&1
[ -e "$IMAGES/old1" ] || fail 'ran again inside the hour'
# A configured image that is not local yet (still pulling) stops the pass.
touch -d '2 hours ago' "$CRF_RUNDIR/runner-image-prune.last"
reset; rm -f "$IMAGES/evid"; crf_runner_image_prune > "$tmp/log" 2>&1 || true
[ -e "$IMAGES/old1" ] && [ -e "$IMAGES/old2" ] || fail 'pruned while a configured image was missing'
printf 'runner image prune: opt-in, configured, previous and in-use images kept PASS\n'
