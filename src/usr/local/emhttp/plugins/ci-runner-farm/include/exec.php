<?php
/* CI Runner Farm - backend endpoint for the web UI.
   Guards every action with the Unraid CSRF token, then shells out to
   runner-farm.sh. Token writes go to a chmod-600 file, never ci-runner-farm.cfg. */
header('Content-Type: application/json');
require_once __DIR__ . '/encoding.php';

// Every UI call already uses POST. Reject GET (and every other method) before
// reading a CSRF value so a token can never be placed in a URL, browser history,
// proxy log, or referrer by this endpoint's action contract.
$method = $_SERVER['REQUEST_METHOD'] ?? '';
if (!is_string($method) || $method !== 'POST') {
  http_response_code(405);
  header('Allow: POST');
  echo crf_json(['ok' => false, 'error' => 'method not allowed']);
  exit;
}

$csrfState = isset($var) && is_array($var)
  ? $var : @parse_ini_file('/var/local/emhttp/var.ini');
$csrf = is_array($csrfState) && is_string($csrfState['csrf_token'] ?? null)
  ? $csrfState['csrf_token'] : '';
$platformCsrfTokenPresent = array_key_exists('csrf_token', get_defined_vars());
$platformCsrfTokenMatches = !$platformCsrfTokenPresent
  || (is_string($csrf_token) && hash_equals($csrf, $csrf_token));
$platformCsrfValidated = function_exists('csrf_terminate')
  && $csrf !== ''
  // Unraid's auto_prepend_file validates either transport, then consumes both
  // keys before this endpoint runs. Releases through 7.2 do not retain a local
  // $csrf_token; 7.3 does. If the platform supplies one, it must still match.
  && !array_key_exists('csrf_token', $_POST)
  && !array_key_exists('HTTP_X_CSRF_TOKEN', $_SERVER)
  && $platformCsrfTokenMatches;
if (!$platformCsrfValidated) {
  // Standalone/CLI fallback for tests and any host that does not use Unraid's
  // local_prepend.php. On Unraid, a missing or incorrect token has already been
  // terminated before the plugin endpoint is evaluated.
  $given = $_POST['csrf_token'] ?? ($_SERVER['HTTP_X_CSRF_TOKEN'] ?? '');
  if ($csrf === '' || !is_string($given) || !hash_equals($csrf, $given)) {
    http_response_code(403);
    echo crf_json(['ok' => false, 'error' => 'csrf']);
    exit;
  }
  unset($_POST['csrf_token'], $_SERVER['HTTP_X_CSRF_TOKEN']);
}

$PLUGIN  = 'ci-runner-farm';
$CFGDIR  = "/boot/config/plugins/$PLUGIN";
$SCRIPT  = "/usr/local/emhttp/plugins/$PLUGIN/include/runner-farm.sh";
$rawAction = $_POST['action'] ?? 'status-json';
// A crafted action[]=... must reach the ordinary unknown-action response, not
// trigger PHP type juggling/warnings in switch. Bound the dispatch string too.
$action = is_string($rawAction) && strlen($rawAction) <= 64 ? $rawAction : '';

// The currently stored credential snapshot, for the literal pass of crf_redact.
// These are the same four files the engine loads into its redaction set; a value
// under 4 bytes is too short to substitute without mangling ordinary log text.
function crf_secret_values($cfgdir) {
  $secrets = [];
  $paths = array_map(fn($name) => "$cfgdir/$name", ['token', 'gitlab-runner-token', 'gitlab-api-token', 'registry-token']);
  $poolTokens = glob("$cfgdir/gitlab-runner-token.*", GLOB_NOSORT);
  if (is_array($poolTokens)) $paths = array_merge($paths, $poolTokens);
  foreach ($paths as $path) {
    $value = @file_get_contents($path);
    // The engine reads these through command substitution, which drops trailing
    // newlines; an opaque registry password's edge spaces are still significant.
    if (is_string($value)) $value = rtrim($value, "\n");
    if (is_string($value) && strlen($value) >= 4) $secrets[] = $value;
  }
  return $secrets;
}

// Command output is not a trusted redaction boundary: stderr in particular is
// unanticipated text from docker and the engine's dependencies. Every response
// body leaves through run()/run_json(), so filter here, with the same locked-
// credential-then-token-shape order and the same markers as redact_log_stream
// in runner-farm.sh. The $secrets injection point keeps this testable without
// giving a root endpoint an environment override for $CFGDIR.
function crf_redact($s, $secrets = null) {
  if (!is_string($s) || $s === '') return $s;
  if ($secrets === null) $secrets = crf_secret_values($GLOBALS['CFGDIR'] ?? '');
  foreach ($secrets as $secret) {
    if (is_string($secret) && strlen($secret) >= 4) $s = str_replace($secret, '[REDACTED]', $s);
  }
  $out = preg_replace([
    '/([A-Za-z0-9_.@-]{1,64}-)?glrt(r)?-[A-Za-z0-9_.-]{10,507}/',
    '/github_pat_[A-Za-z0-9_]{10,}/',
    '/gh[pousr]_[A-Za-z0-9_]{10,}/',
    '/glpat-[A-Za-z0-9_-]{8,}/',
  ], [
    '[REDACTED_GITLAB_TOKEN]',
    '[REDACTED_GITHUB_TOKEN]',
    '[REDACTED_GITHUB_TOKEN]',
    '[REDACTED_GITLAB_TOKEN]',
  ], $s);
  // preg_replace returns null only when PCRE itself fails. Fall back to the
  // empty body every caller already handles, never to the unfiltered input.
  return is_string($out) ? $out : '';
}

function run($cmd) { exec($cmd . ' 2>&1', $out, $rc); return [crf_redact(implode("\n", $out)), $rc]; }
// For actions whose stdout is a JSON body the frontend parses: keep stderr OUT of
// it, so a stray docker/system warning can't corrupt the JSON (JSON.parse would
// throw and the consumer's .catch would silently freeze the panel). run() keeps
// 2>&1 for the action responses where the merged log IS the payload.
function run_json($cmd) { exec($cmd . ' 2>/dev/null', $out, $rc); return [crf_redact(implode("\n", $out)), $rc]; }
// The last non-empty stdout line, if it is a JSON object — lets an emitter print
// progress logs then its {ok,error?} verdict as the final line and have us pass
// that verdict through with its specific reason intact.
function last_json($out) {
  $lines = array_values(array_filter(explode("\n", $out), fn($l) => trim($l) !== ''));
  $last = $lines ? trim(end($lines)) : '';
  return (strlen($last) && $last[0] === '{') ? $last : '';
}
// Credentials and trust material never belong in the shell-sourced cfg. Keep
// writes in one helper so every provider secret gets the same locked write and
// restrictive mode. Paths passed here are fixed plugin-owned filenames.
function write_secret($path, $value) {
  $dir = dirname($path);
  if (!is_dir($dir) && !@mkdir($dir, 0755, true)) return false;
  $tmp = @tempnam($dir, '.crf-secret-');
  if ($tmp === false) return false;
  $ok = @chmod($tmp, 0600)
    && file_put_contents($tmp, $value, LOCK_EX) !== false
    && @rename($tmp, $path)
    && @chmod($path, 0600);
  if (!$ok) @unlink($tmp);
  return $ok;
}

// Validate only the local, injection-safe shape of a GitLab runner
// authentication token. Current GitLab routable tokens contain two literal
// dots, so the payload alphabet is the URL-safe base64 alphabet plus '.'. Keep
// the total value bounded to 512 bytes, matching GitLab's token storage limit.
//
// The exact glrt- prefix is also a lifecycle safety boundary: official Runner
// uses it to select manager-only unregister. A glrtr- or custom-prefixed value
// can take the legacy runner-removal path and delete the shared runner entity.
// Every rejection is static and deliberately reveals neither the submitted
// value, its exact length, nor an offending character.
function gitlab_runner_token_validation($raw, &$normalized) {
  $normalized = '';
  if (!is_string($raw)) {
    return ['code'=>'runner_token_prefix', 'error'=>'The runner authentication token must begin exactly glrt-.'];
  }

  // A copied token may carry an outer newline. Strip only ordinary paste
  // whitespace; unlike trim(), this does not silently discard NUL bytes.
  $tok = trim($raw, " \t\r\n");
  if ($tok === '') {
    return ['code'=>'runner_token_empty', 'error'=>'No runner authentication token was provided.'];
  }

  if (strncmp($tok, 'glrt-', 5) === 0) {
    $payload = substr($tok, 5);
    $length = strlen($payload);
    if ($length < 10 || $length > 507) {
      return ['code'=>'runner_token_length', 'error'=>'The runner authentication token must contain 10–507 characters after glrt-.'];
    }
    if (!preg_match('/\A[A-Za-z0-9_.-]+\z/D', $payload)) {
      // An exact-prefix value followed by command text or a closing quote gets
      // the same actionable guidance as a full copied registration command.
      if (preg_match('/[ \t\r\n\'"`]/', $payload)) {
        return ['code'=>'runner_token_wrapped', 'error'=>'Paste only the raw glrt- runner authentication token, without a command, flag, variable assignment, or quotes.'];
      }
      return ['code'=>'runner_token_characters', 'error'=>'After glrt-, use only ASCII letters, digits, dots, hyphens, and underscores.'];
    }
    $normalized = $tok;
    return null;
  }

  if (strncmp($tok, 'glrtr-', 6) === 0) {
    return ['code'=>'runner_token_legacy', 'error'=>'Tokens beginning glrtr- come from GitLab’s legacy registration-token flow and are not supported; create a runner with GitLab’s modern workflow and use its glrt- token.'];
  }
  if (strncmp($tok, 'glpat-', 6) === 0) {
    return ['code'=>'runner_token_api', 'error'=>'That looks like a GitLab API token. Paste the runner authentication token beginning glrt-.'];
  }

  $embedded = strpos($tok, 'glrt-');
  if ($embedded !== false) {
    if (preg_match('/\A[A-Za-z0-9_.@-]{1,64}glrt-[A-Za-z0-9_.-]+\z/D', $tok)) {
      return ['code'=>'runner_token_custom_prefix', 'error'=>'This token has a custom instance prefix. This build requires glrt- at the start for safe manager-only removal.'];
    }
    return ['code'=>'runner_token_wrapped', 'error'=>'Paste only the raw glrt- runner authentication token, without a command, flag, variable assignment, or quotes.'];
  }

  return ['code'=>'runner_token_prefix', 'error'=>'The runner authentication token must begin exactly glrt-.'];
}

// Accept only a PEM certificate chain: no private-key blocks, comments, or
// arbitrary text. Validate the envelope/base64 shape first and, when PHP's
// OpenSSL extension is present, also require every certificate to parse.
function normalize_pem_ca($raw) {
  if (!is_string($raw) || $raw === '' || strlen($raw) > 1048576 || strpos($raw, "\0") !== false) return false;
  $pem = str_replace(["\r\n", "\r"], "\n", trim($raw)) . "\n";
  $pattern = '/-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+\/=\n]+-----END CERTIFICATE-----/';
  if (!preg_match_all($pattern, $pem, $certs) || trim(preg_replace($pattern, '', $pem)) !== '') return false;
  foreach ($certs[0] as $cert) {
    $body = str_replace(['-----BEGIN CERTIFICATE-----', '-----END CERTIFICATE-----', "\n"], '', $cert);
    if ($body === '' || base64_decode($body, true) === false) return false;
  }
  if (function_exists('openssl_x509_read')) {
    foreach ($certs[0] as $cert) {
      $x509 = @openssl_x509_read($cert);
      if ($x509 === false) return false;
      if (function_exists('openssl_x509_free')) @openssl_x509_free($x509);
    }
  }
  return $pem;
}

function active_provider($cfgdir) {
  $cfg = @parse_ini_file("$cfgdir/ci-runner-farm.cfg") ?: [];
  return (($cfg['CI_PROVIDER'] ?? 'github') === 'gitlab') ? 'gitlab' : 'github';
}

// Secret removal must not claim success when flash is read-only or an I/O
// error leaves the credential behind. A missing file is already the requested
// end state and remains a successful, idempotent clear.
function unlink_secret($path) {
  return !file_exists($path) || @unlink($path);
}

// GitLab managers bake their runner token and trust/auth mounts into each slot.
// Updating one of those inputs while GitLab is active therefore needs the same
// idle-draining reconcile used by Settings Apply. Pre-staging GitLab secrets
// while GitHub is active deliberately does not disturb the GitHub fleet.
function reconcile_active_gitlab($cfgdir, $script) {
  if (active_provider($cfgdir) !== 'gitlab') return ['requested' => false, 'ok' => true, 'log' => ''];
  [$out, $rc] = run(escapeshellarg($script) . ' reconcile-config');
  return ['requested' => true, 'ok' => $rc === 0, 'log' => $out];
}

function credential_response($action, $ok, $error = null, $reconcile = null, $extra = []) {
  $body = array_merge(['ok' => $ok, 'action' => $action, 'error' => $ok ? null : $error], $extra);
  if (is_array($reconcile)) {
    $body['reconcile_requested'] = $reconcile['requested'];
    $body['reconcile_started'] = $reconcile['requested'] && $reconcile['ok'];
    if ($reconcile['requested'] && !$reconcile['ok']) $body['reconcile_error'] = $reconcile['log'] ?: 'could not start reconcile';
  }
  echo crf_json($body);
}

function dockerfile_paths($cfgdir, $plugin, $provider) {
  $suffix = $provider === 'gitlab' ? 'gitlab' : 'github';
  return ["$cfgdir/Dockerfile.$suffix", "/usr/local/emhttp/plugins/$plugin/default.$suffix.Dockerfile"];
}

switch ($action) {
  case 'status-json':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' status-json');
    // runner-farm.sh already emits JSON; pass it through verbatim. Empty stdout means
    // the backend script itself failed (missing/non-executable/crash) — not a real
    // empty fleet — so on a non-zero exit surface an HTTP error, which makes crfPost
    // reject and the UI show "lost connection" instead of a misleading "No managed
    // runners" card.
    if      ($out !== '') { echo $out; }
    elseif  ($rc === 0)   { echo crf_json(['count'=>0,'runners'=>[]]); }
    else                  { http_response_code(500); echo crf_json(['ok'=>false,'error'=>'backend unavailable']); }
    break;

  case 'start': case 'stop': case 'restart': case 'validate':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' ' . escapeshellarg($action));
    echo crf_json(['ok' => $rc === 0, 'action' => $action, 'log' => $out]);
    break;

  case 'scale':
    // Clamp server-side too — the form max is presentation-only and the engine
    // hard-caps; this is defense-in-depth against a crafted POST (n=99999).
    $raw = $_POST['n'] ?? '';
    if (!is_string($raw) || !preg_match('/\A[0-9]{1,20}\z/D', $raw)) {
      echo crf_json(['ok'=>false,'error'=>'bad scale target']); break;
    }
    // Avoid integer-overflow behavior for a very large but syntactically valid
    // decimal: anything above two digits necessarily clamps to the hard limit.
    $digits = ltrim($raw, '0');
    $n = strlen($digits) > 2 ? 64 : min(64, (int)$raw);
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' scale ' . escapeshellarg((string)$n));
    echo crf_json(['ok' => $rc === 0, 'action' => "scale $n", 'log' => $out]);
    break;

  case 'set-token':
    $raw = $_POST['token'] ?? '';
    $tok = is_string($raw) ? trim($raw) : '';
    if ($tok === '') { echo crf_json(['ok'=>false,'error'=>'empty']); break; }
    // Shape-check the PAT: every GitHub token form (ghp_/gho_/ghs_/ghr_/github_pat_
    // + classic 40-char hex) is [A-Za-z0-9_] only. Rejecting anything else keeps a
    // stray quote/newline/backslash out of the curl `--config` header the engine
    // builds from this value (where it could break or inject curl directives).
    if (!preg_match('/^[A-Za-z0-9_]{20,255}$/', $tok)) {
      echo crf_json(['ok'=>false,'error'=>'that does not look like a GitHub token (expected letters, digits, and underscores only)']); break;
    }
    $ok = write_secret("$CFGDIR/token", $tok);
    echo crf_json(['ok' => $ok, 'action' => 'set-token', 'error' => $ok ? null : 'write failed']);
    break;

  case 'clear-token':
    // The GitHub PAT is also the optional GHCR fallback. Remove the source and
    // plugin-owned Docker auth under fleet.lock so a queued lifecycle action
    // cannot recreate config.json from a pre-lock ACCESS_TOKEN snapshot.
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' credential-clear-github-token');
    $j = last_json($out);
    if ($j !== '') echo $j;
    else credential_response('clear-token', false,
      $out !== '' ? $out : 'credential clear action failed', null,
      ['token_removed'=>false,'host_auth_removed'=>false]);
    break;

  case 'set-gitlab-runner-token':
    $raw = $_POST['token'] ?? '';
    $tok = '';
    // Require a runner created through GitLab's modern workflow. Registration-
    // created glrtr- tokens can make `unregister` delete the shared runner entity
    // instead of only this farm slot's manager, so they are intentionally refused.
    $validation = gitlab_runner_token_validation($raw, $tok);
    if (is_array($validation)) {
      echo crf_json(['ok'=>false, 'error_code'=>$validation['code'], 'error'=>$validation['error']]); break;
    }
    $ok = write_secret("$CFGDIR/gitlab-runner-token", $tok);
    $reconcile = $ok ? reconcile_active_gitlab($CFGDIR, $SCRIPT) : null;
    credential_response('set-gitlab-runner-token', $ok, 'write failed', $reconcile);
    break;

  case 'set-gitlab-pool-token':
    $pool = $_POST['pool'] ?? '';
    if (!is_string($pool) || !preg_match('/^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$/D', $pool)
        || in_array($pool, ['default', 'invalid'], true)) {
      echo crf_json(['ok'=>false,'error'=>'invalid pool id']); break;
    }
    $raw = $_POST['token'] ?? '';
    $tok = '';
    $validation = gitlab_runner_token_validation($raw, $tok);
    if (is_array($validation)) {
      echo crf_json(['ok'=>false, 'error_code'=>$validation['code'], 'error'=>$validation['error']]); break;
    }
    $ok = write_secret("$CFGDIR/gitlab-runner-token.$pool", $tok);
    echo crf_json(['ok'=>$ok,'action'=>'set-gitlab-pool-token','pool'=>$pool,'error'=>$ok ? null : 'write failed']);
    break;

  case 'clear-gitlab-pool-token':
    $pool = $_POST['pool'] ?? '';
    if (!is_string($pool) || !preg_match('/^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$/D', $pool)
        || in_array($pool, ['default', 'invalid'], true)) {
      echo crf_json(['ok'=>false,'error'=>'invalid pool id']); break;
    }
    [$active, $activeRc] = run_json('docker ps -a --filter ' . escapeshellarg('label=net.unraid.ci-runner-farm.pool=' . $pool) . " --format '{{.Names}}'");
    if ($activeRc !== 0) { echo crf_json(['ok'=>false,'error'=>'could not verify pool usage']); break; }
    if (trim($active) !== '') { echo crf_json(['ok'=>false,'error'=>'stop the fleet before clearing a pool token']); break; }
    $path = "$CFGDIR/gitlab-runner-token.$pool";
    $ok = !file_exists($path) || @unlink($path);
    echo crf_json(['ok'=>$ok,'action'=>'clear-gitlab-pool-token','pool'=>$pool,'error'=>$ok ? null : 'remove failed']);
    break;

  case 'clear-gitlab-runner-token':
    $active = active_provider($CFGDIR) === 'gitlab';
    $confirmStop = $_POST['confirm_stop'] ?? '';
    if ($active && (!is_string($confirmStop) || $confirmStop !== '1')) {
      echo crf_json([
        'ok'=>false,
        'action'=>'clear-gitlab-runner-token',
        'confirmation_required'=>true,
        'error'=>'Clearing the active GitLab runner token gracefully drains each manager before stopping and unregistering it; jobs still running after the configured timeout are forced to stop.'
      ]);
      break;
    }
    // The source token, mounted per-slot copies, manager unregister, and fleet
    // teardown must be one fleet-locked transaction. Doing `stop` here and then
    // unlinking from PHP leaves a gap in which an already-running reconciler can
    // recreate config.toml from the bootstrap token. The engine also re-checks
    // the active provider under the lock, so a concurrent Settings Apply cannot
    // turn an unconfirmed inactive-token clear into a destructive fleet stop.
    $confirmed = (is_string($confirmStop) && $confirmStop === '1') ? '1' : '0';
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' credential-clear-gitlab-runner ' . escapeshellarg($confirmed));
    $j = last_json($out);
    if ($j !== '') echo $j;
    else credential_response('clear-gitlab-runner-token', false,
      $out !== '' ? $out : 'credential clear action failed', null,
      ['token_removed'=>false,'fleet_stop_requested'=>$active,'fleet_stopped'=>false,'slot_configs_removed'=>false]);
    break;

  case 'set-gitlab-api-token':
    $raw = $_POST['token'] ?? '';
    $tok = is_string($raw) ? trim($raw) : '';
    // GitLab.com PATs normally use glpat-, but self-managed instances may
    // configure a different prefix. Accept the same narrow alphabet as the
    // engine's curl-config path while rejecting whitespace, controls, quotes,
    // backslashes, and newlines that could terminate or inject a directive.
    if (!preg_match('/^[A-Za-z0-9_.@:+\/=~-]{8,512}$/D', $tok)) {
      echo crf_json(['ok'=>false,'error'=>'expected an 8-512 character GitLab API token using only token-safe characters']); break;
    }
    $ok = write_secret("$CFGDIR/gitlab-api-token", $tok);
    echo crf_json(['ok'=>$ok,'action'=>'set-gitlab-api-token','error'=>$ok ? null : 'write failed']);
    break;

  case 'clear-gitlab-api-token':
    $ok = unlink_secret("$CFGDIR/gitlab-api-token");
    credential_response('clear-gitlab-api-token', $ok, 'could not remove gitlab-api-token');
    break;

  case 'set-gitlab-ca':
    $pem = normalize_pem_ca($_POST['ca'] ?? '');
    if ($pem === false) { echo crf_json(['ok'=>false,'error'=>'expected one or more PEM CERTIFICATE blocks (private keys are not accepted)']); break; }
    $ok = write_secret("$CFGDIR/gitlab-ca.crt", $pem);
    $reconcile = $ok ? reconcile_active_gitlab($CFGDIR, $SCRIPT) : null;
    credential_response('set-gitlab-ca', $ok, 'write failed', $reconcile);
    break;

  case 'clear-gitlab-ca':
    $ok = unlink_secret("$CFGDIR/gitlab-ca.crt");
    $reconcile = $ok ? reconcile_active_gitlab($CFGDIR, $SCRIPT) : null;
    credential_response('clear-gitlab-ca', $ok, 'could not remove gitlab-ca.crt', $reconcile);
    break;

  case 'set-registry-token':
    $raw = $_POST['token'] ?? '';
    if (!is_string($raw)) { echo crf_json(['ok'=>false,'error'=>'invalid registry token']); break; }
    // Registry passwords are opaque: leading/trailing spaces may be meaningful,
    // so never trim or normalize them. Keep flash writes bounded and reject ASCII
    // controls (including NUL, tabs, CR/LF, and DEL) that cannot safely be treated
    // as a single stored credential or redacted line-for-line in diagnostics.
    if (strlen($raw) > 8192 || preg_match('/[\x00-\x1F\x7F]/', $raw)) {
      echo crf_json(['ok'=>false,'error'=>'invalid or oversized registry token']); break;
    }
    $tok = $raw;
    if ($tok === '') { echo crf_json(['ok'=>false,'error'=>'empty']); break; }
    $ok = write_secret("$CFGDIR/registry-token", $tok);
    $reconcile = $ok ? reconcile_active_gitlab($CFGDIR, $SCRIPT) : null;
    credential_response('set-registry-token', $ok, 'write failed', $reconcile);
    break;

  case 'clear-registry-token':
    // Serialize source-token removal, every derived Docker auth copy, and the
    // active-GitLab reconcile decision with fleet mutations. Otherwise a drain
    // that was already waiting on fleet.lock can repopulate config.json between
    // PHP's independent unlink/scrub operations.
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' credential-clear-registry-token');
    $j = last_json($out);
    if ($j !== '') echo $j;
    else credential_response('clear-registry-token', false,
      $out !== '' ? $out : 'credential clear action failed', null,
      ['token_removed'=>false,'slot_auth_removed'=>false,'host_auth_removed'=>false]);
    break;

  case 'get-dockerfile':
    $provider = active_provider($CFGDIR);
    [$saved, $default] = dockerfile_paths($CFGDIR, $PLUGIN, $provider);
    // Existing GitHub installs used an unsuffixed custom Dockerfile. Read it as
    // a compatibility fallback, but all new saves go to Dockerfile.github.
    $df = $saved;
    if (!is_file($df) && $provider === 'github' && is_file("$CFGDIR/Dockerfile")) $df = "$CFGDIR/Dockerfile";
    if (!is_file($df)) $df = $default;
    echo crf_json(['ok'=>true,'provider'=>$provider,'path'=>$df,'saved'=>is_file($saved) || ($provider === 'github' && is_file("$CFGDIR/Dockerfile")),'dockerfile'=>is_file($df) ? file_get_contents($df) : '']);
    break;

  case 'save-dockerfile':
    $content = $_POST['dockerfile'] ?? '';
    if (!is_string($content) || trim($content) === '') { echo crf_json(['ok'=>false,'error'=>'empty']); break; }
    if (strlen($content) > 2097152 || strpos($content, "\0") !== false) { echo crf_json(['ok'=>false,'error'=>'invalid or oversized Dockerfile']); break; }
    $provider = active_provider($CFGDIR);
    $expected = $_POST['provider'] ?? $provider;
    if (!is_string($expected) || !in_array($expected, ['github','gitlab'], true) || $expected !== $provider) {
      echo crf_json(['ok'=>false,'error'=>'active provider changed; reload the provider Dockerfile before saving','provider'=>$provider]); break;
    }
    [$df, $default] = dockerfile_paths($CFGDIR, $PLUGIN, $provider);
    @mkdir($CFGDIR, 0755, true);
    $ok = file_put_contents($df, $content, LOCK_EX) !== false;
    echo crf_json(['ok'=>$ok,'action'=>'save-dockerfile','provider'=>$provider,'path'=>$df,'error'=>$ok ? null : 'write failed']);
    break;

  case 'build-image':
    // The engine owns the flock/launch state machine (build-async verb); thin shim.
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' build-async');
    echo $out !== '' ? $out : crf_json(['ok'=>false,'error'=>'build launch failed']);
    break;

  case 'queued-json':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' queued-json');
    echo $out !== '' ? $out : crf_json(['queued' => -1]);
    break;

  case 'stats-json':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' stats-json');
    echo $out !== '' ? $out : crf_json(['total' => -1]);
    break;

  case 'cache-usage':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' cache-usage-json');
    echo $out !== '' ? $out : crf_json(['total' => -1]);
    break;

  case 'cache-clear':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' cache-clear-pkg');
    // cmd_cache_clear_pkg emits its {ok,error?} verdict as the final stdout line;
    // pass it through so a specific reason (unsafe root / could not remove N dirs)
    // reaches the UI, else fall back to the exit-code envelope.
    $j = last_json($out);
    echo $j !== '' ? $j : crf_json(['ok' => $rc === 0, 'action' => 'cache-clear']);
    break;

  case 'recycle':
    $n = $_POST['name'] ?? '';
    if (!is_string($n) || !preg_match('/^ci-runner-(?:[0-9]+|[a-z][a-z0-9-]{0,23}-[0-9]+)$/', $n)) { echo crf_json(['ok'=>false,'error'=>'bad name']); break; }
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' recycle ' . escapeshellarg($n));
    // cmd_recycle emits progress logs then its {ok,error?} verdict as the final
    // stdout line; pass it through so the specific reason (removed-not-recreated,
    // preflight-aborted, no-token …) reaches the UI, else fall back to exit code.
    $j = last_json($out);
    echo $j !== '' ? $j : crf_json(['ok' => $rc === 0, 'action' => 'recycle']);
    break;

  case 'force-forget-gitlab':
    $n = $_POST['name'] ?? '';
    $confirm = $_POST['confirm'] ?? '';
    if (!is_string($n) || !preg_match('/^ci-runner-(?:[0-9]+|[a-z][a-z0-9-]{0,23}-[0-9]+)$/', $n)) {
      echo crf_json(['ok'=>false,'error'=>'bad name']); break;
    }
    // This is the escape hatch for a permanently unreachable GitLab instance
    // or revoked manager token. It interrupts the slot and deliberately leaves
    // any remote manager record behind, so require an explicit second request.
    if (!is_string($confirm) || !hash_equals('FORGET_LOCAL_GITLAB_MANAGER', $confirm)) {
      echo crf_json(['ok'=>false,'confirmation_required'=>true,'error'=>'explicit local-forget confirmation required']); break;
    }
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' force-forget-gitlab ' . escapeshellarg($n));
    echo crf_json([
      'ok'=>$rc === 0,
      'action'=>'force-forget-gitlab',
      'name'=>$n,
      'remote_manager_may_remain'=>true,
      'error'=>$rc === 0 ? null : 'local cleanup failed; review the log and retry',
      'log'=>$out,
    ]);
    break;

  case 'runner-log':
    $n = $_POST['name'] ?? '';
    if (!is_string($n) || !preg_match('/^ci-runner-(?:[0-9]+|[a-z][a-z0-9-]{0,23}-[0-9]+)$/', $n)) { echo crf_json(['ok'=>false,'error'=>'bad name']); break; }
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' logs-tail ' . escapeshellarg($n) . ' 150');
    echo crf_json(['ok' => $rc === 0, 'log' => $out, 'error' => $rc === 0 ? null : 'runner is not an owned managed slot']);
    break;

  case 'image-info':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' image-info-json');
    echo $out !== '' ? $out : crf_json(['exists' => false]);
    break;

  case 'get-default-dockerfile':
    $provider = active_provider($CFGDIR);
    [$saved, $df] = dockerfile_paths($CFGDIR, $PLUGIN, $provider);
    echo crf_json(['ok'=>true,'provider'=>$provider,'path'=>$df,'dockerfile'=>is_file($df) ? file_get_contents($df) : '']);
    break;

  case 'farm-log':
    // engine owns the source selection + filtering (farm-log verb); thin shim.
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' farm-log');
    echo $out !== '' ? $out : crf_json(['ok'=>true,'log'=>'']);
    break;

  case 'build-log':
    // engine owns the liveness/rc/log parsing (build-status verb); thin shim.
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' build-status');
    echo $out !== '' ? $out : crf_json(['ok'=>true,'running'=>false,'rc'=>null,'log'=>'']);
    break;

  default:
    http_response_code(400);
    echo crf_json(['ok' => false, 'error' => 'unknown action']);
}
