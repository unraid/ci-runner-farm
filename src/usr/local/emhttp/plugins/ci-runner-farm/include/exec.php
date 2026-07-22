<?php
/* CI Runner Farm - backend endpoint for the web UI.
   Guards every action with the Unraid CSRF token, then shells out to
   runner-farm.sh. Token writes go to a chmod-600 file, never ci-runner-farm.cfg. */
header('Content-Type: application/json');

$var = @parse_ini_file('/var/local/emhttp/var.ini');
$csrf = $var['csrf_token'] ?? '';
$given = $_REQUEST['csrf_token'] ?? '';
if (!$csrf || !hash_equals($csrf, $given)) {
  http_response_code(403);
  echo json_encode(['ok' => false, 'error' => 'csrf']);
  exit;
}

$PLUGIN  = 'ci-runner-farm';
$CFGDIR  = "/boot/config/plugins/$PLUGIN";
$SCRIPT  = "/usr/local/emhttp/plugins/$PLUGIN/include/runner-farm.sh";
$action  = $_REQUEST['action'] ?? 'status-json';

function run($cmd) { exec($cmd . ' 2>&1', $out, $rc); return [implode("\n", $out), $rc]; }

switch ($action) {
  case 'status-json':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' status-json');
    // runner-farm.sh already emits JSON; pass it through verbatim
    echo $out !== '' ? $out : json_encode(['count'=>0,'runners'=>[]]);
    break;

  case 'start': case 'stop': case 'restart': case 'validate':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' ' . escapeshellarg($action));
    echo json_encode(['ok' => $rc === 0, 'action' => $action, 'log' => $out]);
    break;

  case 'scale':
    $n = (int)($_REQUEST['n'] ?? 0);
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' scale ' . escapeshellarg((string)$n));
    echo json_encode(['ok' => $rc === 0, 'action' => "scale $n", 'log' => $out]);
    break;

  case 'set-token':
    $tok = trim($_REQUEST['token'] ?? '');
    if ($tok === '') { echo json_encode(['ok'=>false,'error'=>'empty']); break; }
    @mkdir($CFGDIR, 0755, true);
    file_put_contents("$CFGDIR/token", $tok);
    chmod("$CFGDIR/token", 0600);
    echo json_encode(['ok' => true, 'action' => 'set-token']);
    break;

  case 'clear-token':
    @unlink("$CFGDIR/token");
    echo json_encode(['ok' => true, 'action' => 'clear-token']);
    break;

  case 'set-registry-token':
    $tok = trim($_REQUEST['token'] ?? '');
    if ($tok === '') { echo json_encode(['ok'=>false,'error'=>'empty']); break; }
    @mkdir($CFGDIR, 0755, true);
    file_put_contents("$CFGDIR/registry-token", $tok);
    chmod("$CFGDIR/registry-token", 0600);
    echo json_encode(['ok' => true, 'action' => 'set-registry-token']);
    break;

  case 'clear-registry-token':
    @unlink("$CFGDIR/registry-token");
    echo json_encode(['ok' => true, 'action' => 'clear-registry-token']);
    break;

  case 'get-dockerfile':
    $df = "$CFGDIR/Dockerfile";
    if (!is_file($df)) $df = "/usr/local/emhttp/plugins/$PLUGIN/default.Dockerfile";
    echo json_encode(['ok' => true, 'dockerfile' => is_file($df) ? file_get_contents($df) : '']);
    break;

  case 'save-dockerfile':
    $content = $_REQUEST['dockerfile'] ?? '';
    if (trim($content) === '') { echo json_encode(['ok'=>false,'error'=>'empty']); break; }
    @mkdir($CFGDIR, 0755, true);
    file_put_contents("$CFGDIR/Dockerfile", $content);
    echo json_encode(['ok' => true, 'action' => 'save-dockerfile']);
    break;

  case 'build-image':
    // launch the build in the background; UI polls 'build-log'
    $log  = "$CFGDIR/build.log";
    $lock = "$CFGDIR/build.lock";
    @mkdir($CFGDIR, 0755, true);
    // Serialize builds ATOMICALLY. The detached wrapper takes a non-blocking
    // flock on fd 9 and only truncates the log + builds if it wins; a second
    // request whose wrapper loses the race exits at `|| exit 9` before touching
    // the running build's log. flock releases on process exit (even SIGKILL), so
    // there is no stale-lock leak. The synchronous probe below is best-effort UX
    // only — it lets us return a clean "already running" now instead of relying
    // on the detached wrapper's exit code; the wrapper's flock is the real guard.
    $probe = 'flock -n ' . escapeshellarg($lock) . ' -c true >/dev/null 2>&1 && echo free || echo busy';
    if (trim((string)shell_exec($probe)) === 'busy') { echo json_encode(['ok' => false, 'error' => 'a build is already running']); break; }
    // Truncate happens INSIDE the lock (`: > log`) so it can never clobber a build
    // that won the race between the probe above and this wrapper acquiring fd 9.
    $wrapper = 'flock -n 9 || exit 9; : > ' . escapeshellarg($log) . '; '
             . escapeshellarg($SCRIPT) . ' build-image >> ' . escapeshellarg($log) . ' 2>&1; '
             . 'echo "__BUILD_RC__=$?" >> ' . escapeshellarg($log);
    exec('nohup sh -c ' . escapeshellarg($wrapper) . ' 9> ' . escapeshellarg($lock) . ' >/dev/null 2>&1 &');
    echo json_encode(['ok' => true, 'action' => 'build-image']);
    break;

  case 'queued-json':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' queued-json');
    echo $out !== '' ? $out : json_encode(['queued' => -1]);
    break;

  case 'stats-json':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' stats-json');
    echo $out !== '' ? $out : json_encode(['total' => -1]);
    break;

  case 'cache-usage':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' cache-usage-json');
    echo $out !== '' ? $out : json_encode(['total' => -1]);
    break;

  case 'cache-clear':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' cache-clear-pkg');
    // cmd_cache_clear_pkg logs before its JSON; trust the exit code, not stdout.
    echo json_encode(['ok' => $rc === 0, 'action' => 'cache-clear']);
    break;

  case 'recycle':
    $n = $_REQUEST['name'] ?? '';
    if (!preg_match('/^ci-runner-[0-9]+$/', $n)) { echo json_encode(['ok'=>false,'error'=>'bad name']); break; }
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' recycle ' . escapeshellarg($n));
    // cmd_recycle emits log lines before its JSON; trust the exit code, not stdout.
    echo json_encode(['ok' => $rc === 0, 'action' => 'recycle']);
    break;

  case 'runner-log':
    $n = $_REQUEST['name'] ?? '';
    if (!preg_match('/^ci-runner-[0-9]+$/', $n)) { echo json_encode(['ok'=>false,'error'=>'bad name']); break; }
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' logs-tail ' . escapeshellarg($n) . ' 150');
    echo json_encode(['ok' => true, 'log' => $out]);
    break;

  case 'image-info':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' image-info-json');
    echo $out !== '' ? $out : json_encode(['exists' => false]);
    break;

  case 'get-default-dockerfile':
    $df = "/usr/local/emhttp/plugins/$PLUGIN/default.Dockerfile";
    echo json_encode(['ok' => true, 'dockerfile' => is_file($df) ? file_get_contents($df) : '']);
    break;

  case 'farm-log':
    // Live farm activity for the Fleet log's idle state: the autoscale daemon
    // log (or boot.log before the daemon ever ran), minus docker's noisy
    // per-invocation swap-limit warning.
    $as = "$CFGDIR/autoscale.log"; $bt = "$CFGDIR/boot.log";
    $src = is_file($as) ? $as : $bt;
    $txt = is_file($src) ? shell_exec('tail -n 150 ' . escapeshellarg($src) . " | grep -v 'swap limit capabilities' | tail -n 60") : '';
    echo json_encode(['ok' => true, 'log' => $txt ?: '']);
    break;

  case 'build-log':
    $log = "$CFGDIR/build.log";
    $txt = is_file($log) ? (string)shell_exec('tail -n 120 ' . escapeshellarg($log)) : '';
    $running = trim(shell_exec("pgrep -f '[r]unner-farm.sh build-image' >/dev/null 2>&1 && echo 1 || echo 0")) === '1';
    $rc = (!$running && preg_match('/__BUILD_RC__=(\d+)/', $txt, $m)) ? (int)$m[1] : null;
    $disp = preg_replace('/\n?__BUILD_RC__=\d+\n?/', "\n", $txt);
    echo json_encode(['ok' => true, 'running' => $running, 'rc' => $rc, 'log' => $disp]);
    break;

  default:
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'unknown action']);
}
