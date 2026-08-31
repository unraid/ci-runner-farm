#!/usr/bin/env bash
# Full repository check used by GitHub Actions and the containerized local runner.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="src/usr/local/emhttp/plugins/ci-runner-farm"

echo "== Shell syntax =="
while IFS= read -r file; do
  echo "bash -n $file"
  bash -n "$file"
done < <(find . -path './.git' -prune -o -type f -name '*.sh' -print | sort)
while IFS= read -r file; do
  case "$(head -1 "$file" 2>/dev/null)" in
    '#!'*sh*) echo "bash -n $file"; bash -n "$file" ;;
  esac
done < <(find "$RUNTIME/event" "$RUNTIME/nchan" -type f -print | sort)

echo "== PHP syntax =="
command -v php >/dev/null 2>&1 || {
  echo "php is required; run ./tests/run-linux-checks.sh for the bundled Linux environment" >&2
  exit 1
}
while IFS= read -r file; do
  grep -q '<?php' "$file" || continue
  echo "php -l $file"
  php -l "$file" >/dev/null
done < <(find "$RUNTIME" -type f \( -name '*.php' -o -name '*.page' \) -print | sort)

echo "== Contracts and package =="
bash tests/config-parity.sh
bash tests/runner-pools.sh
bash tests/autoscale-queue.sh
bash tests/pool-runtime.sh
bash tests/numeric-config.sh
bash tests/safe-paths.sh
bash tests/provider-contract.sh
bash tests/exec-csrf.sh
bash tests/log-redaction.sh
bash tests/provider-mocks.sh
bash tests/lease-selfheal.sh
bash tests/ownership-safety.sh
bash tests/resource-ownership.sh
bash tests/gitlab-policy.sh
bash tests/firewall-transition.sh
bash tests/deploy-uninstall-safety.sh
bash tests/install-dev-safety.sh
bash tests/release-guard.sh
bash tests/package-contents.sh
bash tests/dev-package.sh

echo "All repository checks passed."
