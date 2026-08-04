#!/usr/bin/env bash
# Publishing belongs exclusively to the canonical upstream repository. Forks
# retain these workflows for easy rebasing but a main push/tag must be a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."

RP=".github/workflows/release-please.yml"
REL=".github/workflows/release.yml"

assert_all_jobs_guarded() {
  local file="$1" jobs job block found=0
  jobs="$(awk '
    /^jobs:[[:space:]]*$/ { in_jobs=1; next }
    in_jobs && /^[^[:space:]#]/ { in_jobs=0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      line=$0; sub(/^  /,"",line); sub(/:.*/,"",line); print line
    }
  ' "$file")"
  [ -n "$jobs" ] || { echo "release-guard: no jobs found in $file" >&2; return 1; }
  while IFS= read -r job; do
    [ -n "$job" ] || continue; found=$((found+1))
    block="$(awk -v want="$job" '
      $0 == "  " want ":" { emit=1; next }
      emit && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
      emit { print }
    ' "$file")"
    printf '%s\n' "$block" \
      | grep -Eq "^    if:.*github\.repository == 'unraid/ci-runner-farm'" || {
        echo "release-guard: unguarded job '$job' in $file" >&2
        return 1
      }
  done <<< "$jobs"
  [ "$found" -gt 0 ]
}

assert_all_jobs_guarded "$RP"
assert_all_jobs_guarded "$REL"

if [ -e .gitlab-ci.yml ]; then
  echo "release-guard: this fork keeps its own CI on GitHub; .gitlab-ci.yml is out of scope" >&2
  exit 1
fi

echo "release-guard: OK — fork branches/tags cannot run upstream release jobs"
