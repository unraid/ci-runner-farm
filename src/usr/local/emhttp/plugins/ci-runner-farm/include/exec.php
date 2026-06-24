<?php
/* CI Runner Farm - backend endpoint for the web UI.
   Guards every action with the Unraid CSRF token, then shells out to
   runner-farm.sh. Token writes go to a chmod-600 file, never config.cfg. */
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

  default:
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'unknown action']);
}
