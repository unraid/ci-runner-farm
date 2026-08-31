<?php
/* Shared output encoders. WebGUI data can contain bytes from Docker, APIs, or
   pasted form values, so every JSON and HTML boundary must handle invalid UTF-8
   explicitly instead of relying on PHP's default failure behavior. */
function crf_json($value, $flags = 0) {
  $json = json_encode($value, $flags | JSON_INVALID_UTF8_SUBSTITUTE);
  return is_string($json) ? $json : '{"ok":false,"error":"response encoding failed"}';
}

function crf_html($value) {
  $html = htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
  return is_string($html) ? $html : '';
}
