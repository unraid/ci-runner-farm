#!/usr/bin/env bash
# Invalid UTF-8 from APIs or form fields must be substituted at output boundaries.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'utf8-safety: FAIL: %s\n' "$*" >&2; exit 1; }
command -v php >/dev/null 2>&1 || fail "php is required"

php -d display_errors=0 <<'PHP' || fail "encoding helpers did not handle invalid UTF-8 safely"
<?php
require 'src/usr/local/emhttp/plugins/ci-runner-farm/include/encoding.php';

$invalid = "prefix \xC3 suffix";
$decoded = json_decode(crf_json(['message' => $invalid]), true);
if (!is_array($decoded) || strpos($decoded['message'] ?? '', "\xEF\xBF\xBD") === false) {
  exit(1);
}

$html = crf_html("prefix \xC3 & < > \" ' suffix");
foreach (["\xEF\xBF\xBD", '&amp;', '&lt;', '&gt;', '&quot;', '&#039;'] as $needle) {
  if (strpos($html, $needle) === false) exit(1);
}

$recursive = [];
$recursive['self'] = &$recursive;
if (crf_json($recursive) !== '{"ok":false,"error":"response encoding failed"}') exit(1);
PHP

if rg -n '\bjson_encode\(' src/usr/local/emhttp/plugins/ci-runner-farm --glob '*.php' --glob '*.page' \
    | grep -v '/include/encoding.php:' >/dev/null; then
  fail "application code still calls json_encode directly"
fi
if rg -n 'htmlspecialchars\(' src/usr/local/emhttp/plugins/ci-runner-farm --glob '*.php' --glob '*.page' \
    | grep -v '/include/encoding.php:' >/dev/null; then
  fail "application code still calls htmlspecialchars directly"
fi

echo "utf8-safety: PASS"
