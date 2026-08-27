#!/usr/bin/env bash
# The engine and the UI endpoint must scrub diagnostics identically: the shell
# filters the log verbs, the endpoint filters every response body (including the
# stderr run() merges in). One shared fixture — the loaded credential snapshot
# plus every recognized provider token shape — goes through both implementations
# and the two outputs must be byte-for-byte identical.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'log-redaction: FAIL: %s\n' "$*" >&2; exit 1; }
command -v php >/dev/null 2>&1 || fail "php is required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The token shapes provider-mocks.sh pins for redact_log_stream, plus a registry
# password of shell/sed punctuation that both sides must treat literally.
redact_access='loaded-access-secret-1234'
redact_runner='loaded-glrt-runner-secret-1234'
redact_api='loaded-api-secret-5678'
redact_registry='reg[]/.*&\punct$token-9012'
routable='glrt-AAECAwQFBgcICQoLDA0OD286MQpwOjIKdTozCnQ6Mw8.01.170z6aiyq'
payload="${routable#glrt-}"

fixture="$tmp/fixture.log"
printf '%s\n' \
  "loaded $redact_access $redact_runner $redact_api $redact_registry" \
  'shape glrt-abcdefghijklmnop glrtr-abcdefghijklmnop acme-glrt-abcdefghijklmnop' \
  "shape $routable glrtr-$payload acme-glrt-$payload" \
  'shape glpat-abcdefghijklmnop github_pat_abcdefghijklmnop ghp_abcdefghijklmnop' \
  'shape gho_abcdefghijklmnop ghs_abcdefghijklmnop ghu_abcdefghijklmnop ghr_abcdefghijklmnop' \
  'plain time="2026-01-01T00:00:00Z" level=warning msg="docker: no such image"' \
  > "$fixture"

(
  export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
  ACCESS_TOKEN="$redact_access"
  GITLAB_RUNNER_TOKEN="$redact_runner"
  GITLAB_API_TOKEN="$redact_api"
  REGISTRY_TOKEN="$redact_registry"
  redact_log_stream < "$fixture"
) > "$tmp/shell.out" || fail "engine redaction failed"

# Same standalone-CSRF harness the endpoint's other tests use. The action is
# unknown, so dispatch falls to default and no credential path is touched.
marker='CRF_REDACTED_FIXTURE'
CRF_FIXTURE="$fixture" CRF_MARKER="$marker" \
CRF_ACCESS="$redact_access" CRF_RUNNER="$redact_runner" \
CRF_API="$redact_api" CRF_REGISTRY="$redact_registry" \
  php -d auto_prepend_file= > "$tmp/php.raw" <<'PHP' || fail "endpoint redaction failed"
<?php
$_SERVER['REQUEST_METHOD'] = 'POST';
$var = ['csrf_token'=>'known-test-token'];
$_POST = ['csrf_token'=>'known-test-token', 'action'=>'crf-redaction-parity'];
include 'src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php';
$secrets = [getenv('CRF_ACCESS'), getenv('CRF_RUNNER'), getenv('CRF_API'), getenv('CRF_REGISTRY')];
echo "\n" . getenv('CRF_MARKER') . "\n";
echo crf_redact(file_get_contents(getenv('CRF_FIXTURE')), $secrets);
PHP
sed "1,/^$marker\$/d" "$tmp/php.raw" > "$tmp/php.out"

if ! cmp -s "$tmp/shell.out" "$tmp/php.out"; then
  diff -u "$tmp/shell.out" "$tmp/php.out" >&2 || true
  fail "endpoint redaction diverged from the engine"
fi

# Parity alone would also accept two identically broken filters, so assert the
# shared output on its merits: nothing recognizable survives, and each marker
# the UI/CLI shows an operator is actually produced.
for leaked in "$redact_access" "$redact_runner" "$redact_api" "$redact_registry" \
  glrt-abcdefghijklmnop glrtr-abcdefghijklmnop acme-glrt-abcdefghijklmnop \
  "$routable" "glrtr-$payload" "acme-glrt-$payload" \
  glpat-abcdefghijklmnop github_pat_abcdefghijklmnop \
  ghp_abcdefghijklmnop gho_abcdefghijklmnop ghs_abcdefghijklmnop \
  ghu_abcdefghijklmnop ghr_abcdefghijklmnop
do
  if grep -Fq -- "$leaked" "$tmp/php.out"; then fail "shared redaction leaked $leaked"; fi
done
for marker_text in '[REDACTED]' '[REDACTED_GITLAB_TOKEN]' '[REDACTED_GITHUB_TOKEN]'; do
  grep -Fq -- "$marker_text" "$tmp/php.out" || fail "shared redaction never emits $marker_text"
done
grep -Fq 'no such image' "$tmp/php.out" || fail "shared redaction discards ordinary log text"

# status-json/image-info/farm-log/build-log echo an engine JSON body verbatim
# through run_json(), so redaction must leave that body parseable.
CRF_TOKEN="$routable" php -d auto_prepend_file= -r '
  $_SERVER["REQUEST_METHOD"] = "POST";
  $var = ["csrf_token"=>"known-test-token"];
  $_POST = ["csrf_token"=>"known-test-token", "action"=>"crf-redaction-parity"];
  ob_start(); include "src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php"; ob_end_clean();
  $body = json_encode(["ok"=>true,"log"=>"registering with ".getenv("CRF_TOKEN")." and ghp_abcdefghijklmnop"]);
  $decoded = json_decode(crf_redact($body, []), true);
  exit(is_array($decoded) && strpos($decoded["log"], "[REDACTED_GITLAB_TOKEN]") !== false ? 0 : 1);
' || fail "redacting a passthrough JSON body left it unparseable"

# Without an explicit set, the literal pass uses the stored credentials: the same
# four filenames and 4-byte floor the engine loads, read like the engine's
# command substitution (trailing newline dropped, edge spaces preserved).
mkdir -p "$tmp/secrets"
printf '%s\n' 'aaaa-github-token' > "$tmp/secrets/token"
printf '%s' 'bbbb-runner-token' > "$tmp/secrets/gitlab-runner-token"
printf '%s' 'cc' > "$tmp/secrets/gitlab-api-token"
printf '%s' ' dd-registry-token ' > "$tmp/secrets/registry-token"
CRF_SECRET_DIR="$tmp/secrets" php -d auto_prepend_file= -r '
  $_SERVER["REQUEST_METHOD"] = "POST";
  $var = ["csrf_token"=>"known-test-token"];
  $_POST = ["csrf_token"=>"known-test-token", "action"=>"crf-redaction-parity"];
  ob_start(); include "src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php"; ob_end_clean();
  $expected = ["aaaa-github-token", "bbbb-runner-token", " dd-registry-token "];
  exit(crf_secret_values(getenv("CRF_SECRET_DIR")) === $expected ? 0 : 1);
' || fail "endpoint does not load the stored credential set the engine redacts"

echo "log-redaction: PASS"
