#!/usr/bin/env bash
# Exercise both CSRF paths in exec.php. Unraid 7.3 validates and consumes the
# request token in auto_prepend_file before the endpoint runs; CLI/tests need the
# endpoint's standalone fallback instead. Every action input below is invalid so
# this test can never write the real /boot credential path.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'exec-csrf: FAIL: %s\n' "$*" >&2; exit 1; }
command -v php >/dev/null 2>&1 || fail "php is required"

# Short enough to fit the deliberately undersized token case, but distinctive
# enough to prove that no rejected input is reflected in a JSON response.
sentinel='Z9Q7X5'

run_case() {
  CRF_CSRF_CASE="$1" CRF_TOKEN_CASE="${2:-prefix}" CRF_TOKEN_SENTINEL="$sentinel" \
    php -d auto_prepend_file= <<'PHP'
<?php
$_SERVER['REQUEST_METHOD'] = 'POST';
$var = ['csrf_token'=>'known-test-token'];
$csrfCase = getenv('CRF_CSRF_CASE');
$tokenCase = getenv('CRF_TOKEN_CASE');
$sentinel = getenv('CRF_TOKEN_SENTINEL');

switch ($tokenCase) {
  case 'empty':
    $token = '';
    break;
  case 'wrapped-command':
    $token = 'gitlab-runner register --url https://gitlab.example.test --token glrt-' . $sentinel . 'abcdef';
    break;
  case 'wrapped-quotes':
    $token = '"glrt-' . $sentinel . 'abcdef"';
    break;
  case 'wrapped-assignment':
    $token = 'RUNNER_AUTH_TOKEN=glrt-' . $sentinel . 'abcdef';
    break;
  case 'legacy':
    $token = 'glrtr-' . $sentinel . 'abcdef';
    break;
  case 'api':
    $token = 'glpat-' . $sentinel . 'abcdef';
    break;
  case 'custom-prefix':
    $token = 'acme-glrt-' . $sentinel . 'abcdef';
    break;
  case 'prefix':
    $token = 'runner-' . $sentinel . '-abcdef';
    break;
  case 'too-short':
    // 6 sentinel bytes + 3 ASCII bytes = a 9-byte suffix (<10).
    $token = 'glrt-' . $sentinel . 'abc';
    break;
  case 'too-long':
    // 6 sentinel bytes + 502 ASCII bytes = a 508-byte suffix (>507).
    $token = 'glrt-' . $sentinel . str_repeat('A', 502);
    break;
  case 'punctuation':
    $token = 'glrt-' . $sentinel . 'abc!def';
    break;
  case 'control':
    $token = 'glrt-' . $sentinel . "abc\x01def";
    break;
  case 'non-ascii':
    $token = 'glrt-' . $sentinel . "abc\xC3\xA9def";
    break;
  case 'non-scalar':
    $token = [$sentinel];
    break;
  default:
    fwrite(STDERR, "unknown token test case\n");
    exit(2);
}

if ($csrfCase === 'platform') {
  function csrf_terminate($reason) {}
  $csrf_token = 'known-test-token';
  // This is the state Unraid 7.3 leaves after successful prevalidation.
  $_POST = ['action'=>'set-gitlab-runner-token', 'token'=>$token];
} elseif ($csrfCase === 'platform-spoof') {
  function csrf_terminate($reason) {}
  $csrf_token = 'wrong-test-token';
  $_POST = ['action'=>'set-gitlab-runner-token', 'token'=>$token];
} elseif ($csrfCase === 'standalone') {
  $_POST = [
    'csrf_token'=>'known-test-token',
    'action'=>'set-gitlab-runner-token',
    'token'=>$token,
  ];
} elseif ($csrfCase === 'standalone-bad') {
  $_POST = [
    'csrf_token'=>'wrong-test-token',
    'action'=>'set-gitlab-runner-token',
    'token'=>$token,
  ];
} else {
  fwrite(STDERR, "unknown CSRF test case\n");
  exit(2);
}
include 'src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php';
PHP
}

assert_action_error() {
  local label="$1" actual="$2" expected_code="$3" expected_message="$4"
  case "$actual" in
    *"$sentinel"*) fail "$label reflected rejected token material" ;;
  esac
  if ! CRF_ACTUAL_JSON="$actual" CRF_EXPECTED_CODE="$expected_code" \
      CRF_EXPECTED_MESSAGE="$expected_message" php -r '
        $body = json_decode(getenv("CRF_ACTUAL_JSON"), true);
        $ok = is_array($body)
          && array_key_exists("ok", $body) && $body["ok"] === false
          && ($body["error_code"] ?? null) === getenv("CRF_EXPECTED_CODE")
          && ($body["error"] ?? null) === getenv("CRF_EXPECTED_MESSAGE");
        exit($ok ? 0 : 1);
      '
  then
    fail "$label returned the wrong static error contract"
  fi
}

check_token_case() {
  local token_case="$1" expected_code="$2" expected_message="$3" csrf_case actual
  for csrf_case in platform standalone; do
    actual="$(run_case "$csrf_case" "$token_case")" \
      || fail "$csrf_case/$token_case endpoint invocation failed"
    assert_action_error "$csrf_case/$token_case" "$actual" "$expected_code" "$expected_message"
  done
}

empty_message='No runner authentication token was provided.'
wrapped_message='Paste only the raw glrt- runner authentication token, without a command, flag, variable assignment, or quotes.'
legacy_message='Tokens beginning glrtr- come from GitLab’s legacy registration-token flow and are not supported; create a runner with GitLab’s modern workflow and use its glrt- token.'
api_message='That looks like a GitLab API token. Paste the runner authentication token beginning glrt-.'
custom_message='This token has a custom instance prefix. This build requires glrt- at the start for safe manager-only removal.'
prefix_message='The runner authentication token must begin exactly glrt-.'
length_message='The runner authentication token must contain 10–507 characters after glrt-.'
characters_message='After glrt-, use only ASCII letters, digits, dots, hyphens, and underscores.'

check_token_case empty runner_token_empty "$empty_message"
check_token_case wrapped-command runner_token_wrapped "$wrapped_message"
check_token_case wrapped-quotes runner_token_wrapped "$wrapped_message"
check_token_case wrapped-assignment runner_token_wrapped "$wrapped_message"
check_token_case legacy runner_token_legacy "$legacy_message"
check_token_case api runner_token_api "$api_message"
check_token_case custom-prefix runner_token_custom_prefix "$custom_message"
check_token_case prefix runner_token_prefix "$prefix_message"
check_token_case too-short runner_token_length "$length_message"
check_token_case too-long runner_token_length "$length_message"
check_token_case punctuation runner_token_characters "$characters_message"
check_token_case control runner_token_characters "$characters_message"
check_token_case non-ascii runner_token_characters "$characters_message"
check_token_case non-scalar runner_token_prefix "$prefix_message"

csrf_error='{"ok":false,"error":"csrf"}'
[ "$(run_case platform-spoof prefix)" = "$csrf_error" ] \
  || fail "spoofed platform CSRF variable bypassed validation"
[ "$(run_case standalone-bad prefix)" = "$csrf_error" ] \
  || fail "standalone invalid CSRF token bypassed validation"

echo "exec-csrf: PASS"
