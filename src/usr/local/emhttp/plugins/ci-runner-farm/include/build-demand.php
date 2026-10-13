<?php
// Farm owns general GitHub queue evidence and desired sizing. Native admission
// remains in the existing shared broker; this file never edits owner state.
declare(strict_types=1);
require_once __DIR__ . "/encoding.php";

class BuildDemand
{
    private const CACHE_LIMIT = 16777216;
    private array $cache = ['items' => [], 'cooldown' => 0];
    private string $scope;
    private float $started;

    public function __construct(private string $cachePath, string $groupToken, string $queueToken)
    {
        $this->started = microtime(true);
        $this->scope = hash('sha256', $groupToken . "\0" . $queueToken);
        if (file_exists($cachePath) || is_link($cachePath)) {
            $this->cache = self::decode(self::protectedRead($cachePath, self::CACHE_LIMIT, true));
            self::check(isset($this->cache['items'], $this->cache['cooldown']) && is_array($this->cache['items']) && count($this->cache['items']) <= 512 && is_int($this->cache['cooldown']), 'invalid HTTP cache');
        }
    }

    public static function check(bool $condition, string $message): void
    {
        if (!$condition) throw new RuntimeException($message);
    }

    public static function decode(string $text): array
    {
        $value = json_decode($text, true, 64, JSON_THROW_ON_ERROR);
        self::check(is_array($value), 'incomplete JSON response');
        return $value;
    }

    public static function protectedRead(string $path, int $limit, bool $private): string
    {
        $before = lstat($path);
        self::check($before !== false && ($before['mode'] & 0170000) === 0100000 && $before['uid'] === 0 &&
            ($private ? ($before['mode'] & 0777) === 0600 : ($before['mode'] & 0022) === 0) && $before['size'] <= $limit, 'unprotected Farm input');
        $file = fopen($path, 'rb');
        self::check($file !== false, 'unreadable Farm input');
        try {
            $actual = fstat($file);
            self::check($actual !== false && $actual['dev'] === $before['dev'] && $actual['ino'] === $before['ino'], 'Farm input identity changed');
            $data = stream_get_contents($file, $limit + 1);
            self::check(is_string($data) && strlen($data) <= $limit, 'Farm input exceeds bound');
            return $data;
        } finally { fclose($file); }
    }

    public static function credentials(string $directory): array
    {
        $values = [];
        foreach (explode("\n", self::protectedRead($directory . '/ci-runner-farm.cfg', 262144, false)) as $line) {
            if (!preg_match('/^\s*(CI_PROVIDER|GH_SCOPE|GH_OWNER|RUNNER_GROUP)\s*=(.*)$/', $line, $match)) continue;
            self::check(!isset($values[$match[1]]), 'duplicate Farm scope');
            $value = trim($match[2]);
            if (strlen($value) >= 2 && (($value[0] === '"' && substr($value, -1) === '"') || ($value[0] === "'" && substr($value, -1) === "'"))) $value = substr($value, 1, -1);
            self::check(!preg_match('/["\']/', $value), 'ambiguous Farm scope quoting');
            $values[$match[1]] = $value;
        }
        self::check(($values['CI_PROVIDER'] ?? '') === 'github' && ($values['GH_SCOPE'] ?? '') === 'org' &&
            preg_match('/\A[A-Za-z0-9][A-Za-z0-9-]*\z/', $values['GH_OWNER'] ?? '') === 1 &&
            ($values['RUNNER_GROUP'] ?? '') !== '' && !preg_match('/[\x00-\x1f$`\\\\]/', implode('', $values)), 'invalid native Farm scope');
        foreach (['token', 'queue-token'] as $name) {
            $value = trim(self::protectedRead($directory . '/' . $name, 65536, true));
            self::check($value !== '' && !preg_match('/\s/', $value), 'invalid native Farm credential');
            $values[$name] = $value;
        }
        return $values;
    }

    public static function pools(string $records): array
    {
        $pools = [];
        foreach (explode(';', $records) as $record) {
            $f = explode('|', $record);
            self::check(count($f) === 11 && $f[0] === 'v3' && in_array($f[1], ['build', 'build-small', 'build-large'], true) && !isset($pools[$f[1]]), 'invalid demand class');
            foreach ([5, 6, 7, 8] as $i) self::check(ctype_digit($f[$i]), 'invalid demand limits');
            self::check(preg_match('/\A([0-9]+)([mg])\z/i', $f[9], $memory) === 1, 'invalid demand memory');
            $min = (int)$f[5]; $max = (int)$f[6]; $idle = (int)$f[7];
            self::check($max > 0 && $max <= 64 && $min <= $max && $idle <= $max && (int)$f[8] > 0 && ($f[1] === 'build' || $min === 0), 'invalid class bounds');
            $labels = array_unique(array_map('strtolower', array_merge([$f[2], 'self-hosted', 'linux', 'x64'], explode(',', $f[3]))));
            self::check(!in_array('', $labels, true), 'empty demand label');
            $pools[$f[1]] = ['id' => $f[1], 'minimum' => $min, 'maximum' => $max, 'idle' => $idle, 'cpus' => (int)$f[8],
                'memory' => (int)$memory[1] * (strtolower($memory[2]) === 'g' ? 1024 : 1), 'labels' => array_values($labels)];
        }
        self::check(isset($pools['build']), 'standard demand class missing');
        uasort($pools, fn($a, $b) => [$a['memory'], $a['cpus'], $a['id']] <=> [$b['memory'], $b['cpus'], $b['id']]);
        return $pools;
    }

    private function fresh(): void
    {
        self::check(microtime(true) >= $this->started && microtime(true) - $this->started <= 60, 'stale general queue snapshot');
        self::check(time() >= $this->cache['cooldown'], 'GitHub queue reader cooldown');
    }

    // At most eight independent requests run concurrently. Every cache reuse
    // requires a fresh authenticated 304; redirects and partial bodies fail.
    public function requests(array $requests): array
    {
        $this->fresh();
        $multi = curl_multi_init(); $active = []; $result = []; $pending = array_keys($requests);
        try {
            do {
                while (count($active) < 8 && $pending) {
                    $path = array_shift($pending); $token = $requests[$path];
                    self::check(str_starts_with($path, '/') && !str_starts_with($path, '//'), 'invalid GitHub path');
                    $key = $this->scope . ':' . $path;
                    $previous = $this->cache['items'][$key] ?? null;
                    if (!is_array($previous) || !isset($previous['seen'], $previous['etag'], $previous['body']) ||
                        !is_int($previous['seen']) || $previous['seen'] > time() || time() - $previous['seen'] > 86400 ||
                        !is_string($previous['etag']) || $previous['etag'] === '' || strlen($previous['etag']) > 256 || preg_match('/[\r\n]/', $previous['etag']) ||
                        !is_string($previous['body']) || strlen($previous['body']) > 1048576) $previous = null;
                    $headers = ['Accept: application/vnd.github+json', 'Authorization: Bearer ' . $token, 'X-GitHub-Api-Version: 2022-11-28'];
                    if ($previous !== null) $headers[] = 'If-None-Match: ' . $previous['etag'];
                    $state = (object)['body' => '', 'headers' => [], 'headerBytes' => 0];
                    $handle = curl_init('https://api.github.com' . $path);
                    curl_setopt_array($handle, [CURLOPT_HTTPHEADER => $headers, CURLOPT_USERAGENT => 'ci-runner-farm', CURLOPT_FOLLOWLOCATION => false,
                        CURLOPT_CONNECTTIMEOUT => 8, CURLOPT_TIMEOUT => max(1, min(20, (int)(60 - (microtime(true) - $this->started)))),
                        CURLOPT_PROTOCOLS_STR => 'https', CURLOPT_WRITEFUNCTION => static function ($h, $data) use ($state) {
                            if (strlen($state->body) + strlen($data) > 1048576) return 0;
                            $state->body .= $data; return strlen($data);
                        }, CURLOPT_HEADERFUNCTION => static function ($h, $data) use ($state) {
                            $state->headerBytes += strlen($data); if ($state->headerBytes > 8192) return 0;
                            if (str_contains($data, ':')) { [$k, $v] = explode(':', $data, 2); $state->headers[strtolower(trim($k))] = trim($v); }
                            return strlen($data);
                        }]);
                    $active[spl_object_id($handle)] = [$handle, $path, $key, $previous, $state];
                    curl_multi_add_handle($multi, $handle);
                }
                self::check(curl_multi_exec($multi, $running) === CURLM_OK, 'GitHub request scheduler failed');
                while ($info = curl_multi_info_read($multi)) {
                    $handle = $info['handle']; [$handle, $path, $key, $previous, $state] = $active[spl_object_id($handle)];
                    self::check($info['result'] === CURLE_OK, 'GitHub queue request failed');
                    $status = curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
                    $result[$path] = $this->response($key, $status, $state->headers, $state->body, $previous);
                    curl_multi_remove_handle($multi, $handle); unset($active[spl_object_id($handle)]);
                }
                $this->fresh();
                if ($active) { if (curl_multi_select($multi, 0.2) === -1) usleep(10000); }
            } while ($active || $pending);
            return $result;
        } finally {
            foreach ($active as [$handle]) curl_multi_remove_handle($multi, $handle);
            curl_multi_close($multi);
        }
    }

    public function response(string $key, int $status, array $headers, string $body, ?array $previous): array
    {
        if ($status === 403 || $status === 429) {
            $until = time() + 60;
            if (ctype_digit($headers['retry-after'] ?? '')) $until = max($until, time() + min(86400, (int)$headers['retry-after']));
            if (($headers['x-ratelimit-remaining'] ?? '') === '0' && ctype_digit($headers['x-ratelimit-reset'] ?? '')) $until = max($until, min(time() + 86400, (int)$headers['x-ratelimit-reset']));
            $this->cache['cooldown'] = max($this->cache['cooldown'], $until);
        }
        if ($status === 304) {
            self::check($previous !== null, 'unattested GitHub 304');
            return self::decode($previous['body']);
        }
        self::check($status === 200 && strlen($body) <= 1048576, 'GitHub queue response denied or incomplete');
        $decoded = self::decode($body);
        unset($this->cache['items'][$key]);
        $etag = $headers['etag'] ?? '';
        if (is_string($etag) && $etag !== '' && strlen($etag) <= 256 && !preg_match('/[\r\n]/', $etag)) {
            $this->cache['items'][$key] = ['seen' => time(), 'etag' => $etag, 'body' => $body];
            $this->trim();
        }
        return $decoded;
    }

    private function trim(): string
    {
        uasort($this->cache['items'], fn($a, $b) => ($a['seen'] ?? 0) <=> ($b['seen'] ?? 0));
        do {
            $data = crf_json($this->cache, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
            if (count($this->cache['items']) <= 512 && strlen($data) <= self::CACHE_LIMIT) return $data;
            array_shift($this->cache['items']);
        } while ($this->cache['items']);
        throw new RuntimeException('HTTP cache exceeds bound');
    }

    public function save(): void
    {
        $data = $this->trim();
        $temporary = tempnam(dirname($this->cachePath), '.build-http-');
        self::check(is_string($temporary), 'HTTP cache staging failed');
        try {
            self::check(chmod($temporary, 0600), 'HTTP cache permissions failed');
            $file = fopen($temporary, 'wb');
            self::check($file !== false, 'HTTP cache write failed');
            try { self::check(fwrite($file, $data) === strlen($data) && fflush($file) && fsync($file), 'HTTP cache write incomplete'); }
            finally { fclose($file); }
            self::check(rename($temporary, $this->cachePath), 'HTTP cache promotion failed');
        } finally { if (file_exists($temporary)) unlink($temporary); }
    }

    // Pagination is checked against exact totals where GitHub supplies them.
    // Requests for distinct repositories/runs share the same bounded snapshot.
    public function pages(array $queries, ?string $field, callable $visit, int $bound): void
    {
        $seen = []; $page = 1;
        while ($queries) {
            self::check($page <= $bound, 'queue pagination exceeds bound');
            $requests = [];
            foreach ($queries as $path => $token) $requests[$path . (str_contains($path, '?') ? '&' : '?') . 'per_page=100&page=' . $page] = $token;
            $responses = $this->requests($requests); $next = [];
            foreach ($queries as $path => $token) {
                $value = $responses[$path . (str_contains($path, '?') ? '&' : '?') . 'per_page=100&page=' . $page];
                $items = $field === null ? $value : ($value[$field] ?? null);
                self::check(is_array($items) && array_is_list($items) && count($items) <= 100, 'incomplete queue page');
                if ($field !== null) {
                    $total = $value['total_count'] ?? null;
                    self::check(is_int($total) && $total >= 0 && count($items) === min(100, max(0, $total - ($page - 1) * 100)), 'incomplete queue total');
                    if (isset($seen[$path])) self::check($seen[$path] === $total, 'queue total changed during pagination');
                    $seen[$path] = $total;
                }
                foreach ($items as $item) { self::check(is_array($item), 'invalid queue item'); $visit($path, $item); }
                if ($field === null ? count($items) === 100 : $page * 100 < $value['total_count']) $next[$path] = $token;
            }
            $queries = $next; $page++;
        }
    }

    public function queue(array $scope, array $pools): array
    {
        $org = $scope['GH_OWNER']; $groupToken = $scope['token']; $token = $scope['queue-token'];
        $groups = []; $groupIDs = [];
        $this->pages(["/orgs/$org/actions/runner-groups" => $groupToken], 'runner_groups', function ($path, $g) use (&$groups, &$groupIDs, $scope) {
            self::check(is_int($g['id'] ?? null) && $g['id'] > 0 && !isset($groupIDs[$g['id']]) && is_string($g['name'] ?? null) && is_bool($g['inherited'] ?? null), 'invalid group identity');
            $groupIDs[$g['id']] = true;
            if ($g['name'] === $scope['RUNNER_GROUP'] && !$g['inherited']) $groups[] = $g;
        }, 100);
        self::check(count($groups) === 1, 'native runner group ambiguous');
        $g = $groups[0];
        self::check(($g['allows_public_repositories'] ?? null) === false && ($g['restricted_to_workflows'] ?? null) === false &&
            ($g['selected_workflows'] ?? null) === [] && in_array($g['visibility'] ?? '', ['all', 'private', 'selected'], true), 'native runner group policy differs');
        $selected = null;
        if ($g['visibility'] === 'selected') {
            $selected = [];
            $this->pages(["/orgs/$org/actions/runner-groups/{$g['id']}/repositories" => $groupToken], 'repositories', function ($path, $r) use (&$selected, $org) {
                $name = strtolower($r['full_name'] ?? '');
                self::check(str_starts_with($name, strtolower($org) . '/') && !isset($selected[$name]), 'invalid selected repository'); $selected[$name] = true;
            }, 100);
        }
        $repos = []; $ids = [];
        $this->pages(["/orgs/$org/repos?type=private" => $token], null, function ($path, $r) use (&$repos, &$ids, $org) {
            $name = $r['name'] ?? ''; $full = strtolower($r['full_name'] ?? '');
            self::check(is_int($r['id'] ?? null) && $r['id'] > 0 && !isset($ids[$r['id']]) && ($r['private'] ?? null) === true &&
                is_string($name) && preg_match('/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\z/', $name) === 1 && $full === strtolower($org . '/' . $name) && !isset($repos[$full]), 'invalid private repository identity');
            $ids[$r['id']] = true; $repos[$full] = $name;
        }, 100);
        if ($selected !== null) { self::check(!array_diff_key($selected, $repos), 'selected repository inaccessible'); $repos = array_intersect_key($repos, $selected); }
        self::check(count($repos) > 0, 'queue credential cannot observe eligible repositories');
        $queries = []; $runs = []; $runIDs = [];
        foreach ($repos as $name) foreach (['queued', 'in_progress'] as $status) $queries["/repos/$org/$name/actions/runs?status=$status"] = $token;
        $this->pages($queries, 'workflow_runs', function ($path, $run) use (&$runs, &$runIDs, $token) {
            preg_match('~/repos/([^/]+/[^/]+)/actions/runs\?status=(queued|in_progress)~', $path, $m);
            $id = $run['id'] ?? null; $attempt = $run['run_attempt'] ?? null; $key = $m[1] . '/' . $id;
            self::check(is_int($id) && $id > 0 && is_int($attempt) && $attempt > 0 && ($run['status'] ?? '') === $m[2] &&
                strtolower($run['repository']['full_name'] ?? '') === strtolower($m[1]) && !isset($runIDs[$key]), 'workflow attempt identity changed');
            $runIDs[$key] = true; $runs["/repos/{$m[1]}/actions/runs/$id/attempts/$attempt/jobs"] = $token;
        }, 10);
        $counts = array_fill_keys(array_keys($pools), 0); $jobIDs = [];
        $this->pages($runs, 'jobs', function ($path, $job) use (&$counts, &$jobIDs, $pools) {
            preg_match('~/repos/([^/]+/[^/]+)/actions/runs/([0-9]+)/attempts/([0-9]+)/jobs~', $path, $m);
            $id = $job['id'] ?? null; $key = $m[1] . '/' . $id;
            self::check(is_int($id) && $id > 0 && ($job['run_id'] ?? null) === (int)$m[2] && !isset($jobIDs[$key]) &&
                in_array($job['status'] ?? null, ['queued', 'in_progress', 'completed', 'waiting', 'pending', 'requested'], true) && is_array($job['labels'] ?? null) && array_is_list($job['labels']) &&
                array_key_exists('runner_id', $job) && ($job['runner_id'] === null || (is_int($job['runner_id']) && $job['runner_id'] >= 0)), 'incomplete job identity');
            $jobIDs[$key] = true;
            foreach ($job['labels'] as $label) self::check(is_string($label) && $label !== '', 'invalid job label');
            if ($job['status'] !== 'queued' || !$job['labels']) return;
            foreach ($pools as $pool) if (!array_diff(array_map('strtolower', $job['labels']), $pool['labels'])) {
                // GitHub documents null as not yet assigned; zero is also observed.
                if ($job['runner_id'] === null || $job['runner_id'] === 0) $counts[$pool['id']]++;
                break;
            }
        }, 10);
        $this->fresh();
        return ['queueStartedAt' => (int)$this->started, 'counts' => $counts, 'organization' => $org];
    }

    public static function targets(string $records, array $scan, array $observation): array
    {
        $pools = self::pools($records); $now = time(); $start = $scan['queueStartedAt'] ?? null; $observed = $observation['observedAt'] ?? null;
        self::check(($observation['schema'] ?? 0) === 1 && is_int($start) && $start > 0 && $start <= $now && $now - $start <= 60 &&
            is_int($observed) && $observed >= $start && $observed <= $now && $now - $observed <= 15 &&
            preg_match('/\A[a-f0-9]{64}\z/', $observation['policyDigest'] ?? '') === 1 &&
            ($observation['poolsDigest'] ?? '') === hash('sha256', ($scan['organization'] ?? '') . "\0" . $records) &&
            is_array($scan['counts'] ?? null) && is_array($observation['retained'] ?? null) &&
            count($scan['counts']) === count($pools) && count($observation['retained']) === count($pools), 'demand observation identity differs');
        $targets = [];
        foreach ($pools as $pool) {
            $q = $scan['counts'][$pool['id']] ?? null; $retained = $observation['retained'][$pool['id']] ?? null;
            self::check(is_int($q) && $q >= 0 && is_int($retained) && $retained >= 0 && $retained <= $pool['maximum'], 'incomplete demand evidence');
            // GitHub jobs omit requested groups: one advisory spare per class.
            $targets[$pool['id']] = min($pool['maximum'], max($pool['minimum'], $retained + min($q, 1) + $pool['idle']));
        }
        return ['schema' => 1, 'policyDigest' => $observation['policyDigest'], 'poolsDigest' => $observation['poolsDigest'],
            'observedAt' => $observed, 'queueStartedAt' => $start, 'targets' => $targets];
    }
}

if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
    try {
        umask(0077);
        ini_set("memory_limit", "128M");
        if (($argv[1] ?? '') === 'scan' && count($argv) === 5) {
            BuildDemand::check(posix_geteuid() === 0 && function_exists('curl_multi_init'), 'general demand requires native root PHP curl runtime');
            $scope = BuildDemand::credentials($argv[2]);
            $reader = new BuildDemand($argv[3] . '/build-demand-http.json', $scope['token'], $scope['queue-token']);
            try { $result = $reader->queue($scope, BuildDemand::pools($argv[4])); }
            finally { $reader->save(); }
        } elseif (($argv[1] ?? '') === 'targets' && count($argv) === 5) {
            $result = BuildDemand::targets($argv[2], BuildDemand::decode($argv[3]), BuildDemand::decode($argv[4]));
        } else throw new RuntimeException('invalid Farm demand command');
        echo crf_json($result, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES) . "\n";
    } catch (Throwable $error) {
        // Do not print request URLs, response bodies, or credential-bearing input.
        fwrite(STDERR, "[ci-runner-farm] general queue evidence unavailable; preserving owners\n"); exit(1);
    }
}
