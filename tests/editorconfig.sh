#!/usr/bin/env bash
# Verify that the verbatim LICENSE file is excluded from editor formatting.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import configparser
import json

editorconfig = configparser.ConfigParser(interpolation=None)
editorconfig.optionxform = str
with open('.editorconfig', encoding='utf-8') as handle:
    editorconfig.read_string('[__root__]\n' + handle.read())

license_rules = editorconfig['LICENSE']
assert license_rules['indent_style'] == 'unset'
assert license_rules['indent_size'] == 'unset'
assert license_rules['end_of_line'] == 'unset'
assert license_rules['charset'] == 'unset'
assert license_rules['trim_trailing_whitespace'] == 'false'
assert license_rules['insert_final_newline'] == 'false'

with open('.vscode/settings.json', encoding='utf-8') as handle:
    settings = json.load(handle)
assert settings['files.associations']['LICENSE'] == 'plaintext'
plaintext_rules = settings['[plaintext]']
assert plaintext_rules['files.insertFinalNewline'] is False
assert plaintext_rules['files.trimTrailingWhitespace'] is False
assert plaintext_rules['files.trimFinalNewlines'] is False

print('editorconfig: PASS')
PY
