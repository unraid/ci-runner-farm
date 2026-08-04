#!/usr/bin/env bash
# Run the same checks as CI in a small Linux image. This is the recommended
# local entry point on macOS, where Bash 3, BSD tar, and BSD realpath differ from
# the Unraid/GitHub Actions environment.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required for the Linux check environment." >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "The Docker daemon is not reachable. Start Docker, then retry." >&2
  exit 1
}

if docker buildx version >/dev/null 2>&1; then
  docker build --progress=plain -f tests/linux-checks.Dockerfile .
else
  # Docker Engine's legacy builder has no --progress flag. It is still enough
  # for this disposable syntax/package check image (and is common on Unraid or
  # when a developer uses an isolated DOCKER_CONFIG without Desktop plugins).
  docker build -f tests/linux-checks.Dockerfile .
fi

# The repository checks run inside the Linux build above.  Config validation
# needs a real Docker daemon to launch the pinned official Runner image, so run
# that gate on the host after the portable suite succeeds.
bash tests/gitlab-runner-lint.sh
