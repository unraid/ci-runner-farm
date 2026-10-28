<?php
// Dynamix compiles inline help directives before evaluating a .page file.
// Match Unraid 7.2.3's parse_text contract; source-only PHP lint misses these tags.
// https://github.com/unraid/webgui/blob/7.2.3/emhttp/plugins/dynamix/include/Translations.php
$pages = glob($argv[1] . '/*.page');
if (!$pages) throw new RuntimeException('No page templates found');
$temporary = tempnam(sys_get_temp_dir(), 'crf-page-');
if ($temporary === false) throw new RuntimeException('Cannot stage compiled page');
try {
    foreach ($pages as $page) {
        $compiled = preg_replace(
            ["/^:(.+_help):$/m", "/^:(.+_plug):$/m", "/^:end$/m"],
            ['<?translate("_$1");?>', '<?if (translate("_$1")):?>', '<?endif;?>'],
            file_get_contents($page)
        );
        if (!is_string($compiled) || file_put_contents($temporary, $compiled) !== strlen($compiled)) {
            throw new RuntimeException('Cannot compile page help directives');
        }
        $output = [];
        exec(escapeshellarg(PHP_BINARY) . ' -d short_open_tag=1 -l ' . escapeshellarg($temporary) . ' 2>&1', $output, $status);
        if ($status !== 0) throw new RuntimeException(basename($page) . ': generated PHP is invalid: ' . implode("\n", $output));
    }
    echo "page-template-syntax: Dynamix-compiled page PHP is valid\n";
} finally {
    unlink($temporary);
}
