#!/usr/bin/env bash
# Real disk cache + RAM workspace, fresh runners, and concurrent offline reuse.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"; tmp="$(mktemp -d)"; suffix="$(date +%s)-$$"
image="ci-runner-farm-pnpm-test:$suffix"; containers=(); children=()
cleanup() {
  local original_status=$? name child cleanup_status=0
  for name in "${containers[@]}"; do docker rm -f "$name" >/dev/null 2>&1 || true; done
  for child in "${children[@]}"; do wait "$child" 2>/dev/null || true; done
  # Real Linux bind mounts retain each test UID. Delete only this disposable
  # fixture's contents as root; the unprivileged CI host owns the outer temp dir.
  docker run --rm --name "crf-pnpm-$suffix-cleanup" -v "$tmp:/cleanup" "$image" \
    bash -c 'find /cleanup -mindepth 1 -delete' || cleanup_status=$?
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf "$tmp" || cleanup_status=$?
  [ "$original_status" = 0 ] || exit "$original_status"
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker build -t "$image" -f tests/pnpm-store.Dockerfile .
for uid in 0 65534; do
  for dest in /home/runner/.local/share/pnpm/store /opt/custom-store; do
    cache="$tmp/cache-$uid-${dest##*/}"
    mkdir -p "$cache/pnpm-store" "$cache/metadata"
    chmod 777 "$tmp" "$cache" "$cache/pnpm-store" "$cache/metadata"
    for version in 10 11; do
      run_case() {
        local mode="$1" instance="$2" name="crf-pnpm-$suffix-$uid-$version-${dest##*/}-$2"
        containers+=("$name")
        docker run --rm --name "$name" --user "$uid:$uid" \
          --tmpfs /_work:rw,exec,size=64m,mode=1777 \
          -v "$repo:/workspace:ro" -v "$cache:/mounted-cache" \
          -e HOME=/tmp/runner-home -e XDG_CACHE_HOME=/fixture-metadata \
          -v "$cache/metadata:/fixture-metadata" \
          -v "$cache/pnpm-store:$dest" "$image" \
          bash /workspace/tests/pnpm-store-guest.sh "$dest" "$version" "$mode"
      }
      run_case seed initial
      run_case offline replacement
      # Names are registered in the parent so the EXIT trap owns both children.
      for instance in concurrent-a concurrent-b; do
        containers+=("crf-pnpm-$suffix-$uid-$version-${dest##*/}-$instance")
        run_case offline "$instance" >"$tmp/$uid-$version-${dest##*/}-$instance.log" 2>&1 &
        children+=("$!")
      done
      failed=0
      for child in "${children[@]}"; do wait "$child" || failed=1; done
      children=()
      cat "$tmp/$uid-$version-${dest##*/}-concurrent-a.log" "$tmp/$uid-$version-${dest##*/}-concurrent-b.log"
      [ "$failed" = 0 ]
    done
  done
done
printf 'Real pnpm store persistence and concurrency checks passed.\n'
