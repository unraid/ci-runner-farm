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

# Exercise the real release validation/build step with the incident's stale
# VERSION/.plg state. No GitHub calls or plugin installation run in this test.
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
workflow = (root / ".github/workflows/release.yml").read_text()
step = workflow.split("      - name: Validate plugin metadata\n", 1)[1]
run = step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
script = "\n".join(line[10:] if line.startswith("          ") else line
                   for line in run.splitlines())

with tempfile.TemporaryDirectory() as temporary:
    build = Path(temporary)
    for name in ("build-plg.sh", "VERSION", "ci-runner-farm.plg", "CHANGELOG.md"):
        shutil.copy2(root / name, build / name)
    shutil.copytree(root / "src", build / "src")
    (build / "VERSION").write_text("1.9.1\n")
    (build / ".release-please-manifest.json").write_text(json.dumps({".": "1.10.0"}))
    # The workflow obtains its reproducible build date from the checked-out
    # commit. Use a real repository, not a mocked git response.
    for args in (["git", "init", "-q"], ["git", "add", "."],
                 ["git", "-c", "user.name=Release Test", "-c",
                  "user.email=release-test@example.invalid", "commit", "-qm", "fixture"]):
        subprocess.run(args, cwd=build, check=True, stdout=subprocess.DEVNULL)
    env = dict(os.environ, RELEASE_TAG="v1.10.0", GITHUB_REPOSITORY="unraid/ci-runner-farm")

    def validate(tag="v1.10.0", success=True):
        result = subprocess.run(["bash", "-c", script], cwd=build,
                                env=dict(env, RELEASE_TAG=tag), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if (result.returncode == 0) != success:
            raise SystemExit(result.stdout)
        return result.stdout

    validate()
    artifacts = build / "release-artifacts"
    files = sorted(artifacts.iterdir())
    assert len(files) == 2, files
    assert (build / "VERSION").read_text().strip() == "1.10.0"
    descriptor = (artifacts / "ci-runner-farm.plg").read_text()
    assert '<!ENTITY pluginVersion "1.10.0">' in descriptor
    assert '/releases/download/v1.10.0/' in descriptor
    before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
    # A retry must not change either artifact, even under a different run id.
    env["GITHUB_RUN_NUMBER"] = "999999"
    validate()
    after = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
             for path in artifacts.iterdir()}
    assert before == after, "release retry changed validated artifacts"
    assert "Manifest version 1.10.0 does not match tag v2.0.0" in validate("v2.0.0", False)
    assert "Release tags must use SemVer" in validate("not-a-release", False)

    # Run the actual publisher with only GitHub and HTTP replaced. The workflow
    # still owns upload order, failure handling, and downloaded-byte comparison.
    publication = (root / ".github/workflows/release-please.yml").read_text()
    publication = publication.split("      - name: Upload plugin release artifact\n", 1)[1]
    publication = publication.split("        run: |\n", 1)[1]
    publish_script = "\n".join(line[10:] if line.startswith("          ") else line
                               for line in publication.splitlines())
    binaries = build / "bin"
    binaries.mkdir()
    gh = binaries / "gh"
    gh.write_text('''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$CALLS"
if [[ "$*" == *"release upload"* && "$*" == *".tgz"* && "${FAIL_PACKAGE:-0}" == 1 ]]; then
  exit 1
fi
''')
    curl = binaries / "curl"
    curl.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
destination = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])
source = pathlib.Path("release-artifacts") / destination.name
shutil.copyfile(source, destination)
if os.environ.get("CORRUPT_DOWNLOAD") == "1":
    destination.write_bytes(b"wrong release bytes")
''')
    gh.chmod(0o755)
    curl.chmod(0o755)
    calls = build / "calls"
    publish_env = dict(env, PATH=f"{binaries}:{env['PATH']}", CALLS=str(calls),
                       GITHUB_RUN_ID="123", GITHUB_SERVER_URL="https://github.com")

    def publish(**overrides):
        calls.write_text("")
        return subprocess.run(["bash", "-c", publish_script], cwd=build,
                              env=dict(publish_env, **overrides),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    assert publish().returncode == 0
    uploads = [line for line in calls.read_text().splitlines() if line.startswith("release upload")]
    assert len(uploads) == 2 and ".tgz" in uploads[0] and ".plg" in uploads[1], uploads
    assert publish(FAIL_PACKAGE="1").returncode != 0
    assert ".plg" not in calls.read_text(), "descriptor uploaded despite package upload failure"
    assert publish(CORRUPT_DOWNLOAD="1").returncode != 0, "incorrect public download was accepted"

print("release-guard: OK — stale metadata rebuilt, artifacts validated, retries stable, invalid tags rejected")
print("release-guard: OK — package published first, failed uploads stop, public downloads compared")
PY
