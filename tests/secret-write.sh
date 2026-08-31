#!/usr/bin/env bash
# Atomic credential writes must report rename success even if final chmod is
# rejected, while still rejecting setup and temporary-file failures.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'secret-write: FAIL: %s\n' "$*" >&2; exit 1; }
command -v php >/dev/null 2>&1 || fail "php is required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

CRF_SECRET_TEST_DIR="$tmp/secrets" php -d display_errors=0 <<'PHP' || fail "write_secret did not preserve atomic-write semantics"
<?php
$dir = getenv('CRF_SECRET_TEST_DIR');
$_SERVER['REQUEST_METHOD'] = 'POST';
$var = ['csrf_token'=>'known-test-token'];
$_POST = ['csrf_token'=>'known-test-token', 'action'=>'secret-write-test'];
ob_start();
include 'src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php';
ob_end_clean();

$path = "$dir/token";
if (!write_secret($path, 'first-secret')) exit(1);
if (file_get_contents($path) !== 'first-secret') exit(1);
if ((fileperms($path) & 0777) !== 0600) exit(1);
if (glob("$dir/.crf-secret-*") !== []) exit(1);

if (!write_secret($path, 'replacement-secret')) exit(1);
if (file_get_contents($path) !== 'replacement-secret') exit(1);
if ((fileperms($path) & 0777) !== 0600) exit(1);

file_put_contents("$dir/not-a-directory", 'occupied');
if (write_secret("$dir/not-a-directory/token", 'should-fail')) exit(1);
if (glob("$dir/.crf-secret-*") !== []) exit(1);
PHP

if rg -n '\&\&[[:space:]]*@chmod\(\$path, 0600\)' \
    src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php >/dev/null; then
  fail "write_secret still reports final chmod as part of save success"
fi
grep -qF 'if (!@rename($tmp, $path))' src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php \
  || fail "write_secret does not use an explicit atomic rename gate"

echo "secret-write: PASS"
