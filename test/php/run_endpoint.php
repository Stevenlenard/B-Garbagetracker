<?php
/**
 * Runs ONE backend endpoint with a fake database and a fake request.
 *   php run_endpoint.php <script.php> <state-file> <request-json-file> [post-json-file]
 * The endpoint's output is printed; the fake database state is saved on shutdown.
 */
$script = $argv[1];
$state = $argv[2];
$bodyFile = $argv[3] ?? '';
$postFile = $argv[4] ?? '';

$GLOBALS['FAKE_MISSING_COLUMNS'] = array_filter(explode(',', getenv('GT_FAKE_MISSING_COLUMNS') ?: ''));

// Stub files resolve before the real backend files of the same name.
set_include_path(__DIR__ . '/stubs' . PATH_SEPARATOR . get_include_path());
putenv('GT_PHP_STATE=' . $state);
define('GT_TEST_HARNESS', true); // lets assignment_lib.php read GT_ASSIGNMENT_TEST_NOW

require_once __DIR__ . '/fake_pdo.php';

// Pretend the HTTP layer exists.
$_SERVER['REQUEST_METHOD'] = 'POST';
$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
if (getenv('GT_TEST_TOKEN')) { $_SERVER['HTTP_X_GT_TOKEN'] = getenv('GT_TEST_TOKEN'); }
// Saved sign-in tests: request cookies, CSRF header, Origin/Host and the script URL.
$_COOKIE = getenv('GT_TEST_COOKIES') ? (json_decode(getenv('GT_TEST_COOKIES'), true) ?: []) : [];
if (getenv('GT_TEST_CSRF')) { $_SERVER['HTTP_X_GT_CSRF'] = getenv('GT_TEST_CSRF'); }
if (getenv('GT_TEST_ORIGIN')) { $_SERVER['HTTP_ORIGIN'] = getenv('GT_TEST_ORIGIN'); }
$_SERVER['HTTP_HOST'] = 'app.example.test';
$_SERVER['SCRIPT_NAME'] = '/backend/' . basename($script);
$_POST = $postFile && is_file($postFile) ? json_decode(file_get_contents($postFile), true) : [];
$_REQUEST = $_POST;

// php://input override (CLI has no request body).
$GLOBALS['__GT_BODY'] = $bodyFile && is_file($bodyFile) ? file_get_contents($bodyFile) : '';
class GtInputWrapper
{
    private $pos = 0;
    public $context;
    public function stream_open($path, $mode, $options, &$opened) { $this->pos = 0; return true; }
    public function stream_read($count)
    {
        $chunk = substr($GLOBALS['__GT_BODY'], $this->pos, $count);
        $this->pos += strlen($chunk);
        return $chunk;
    }
    public function stream_eof() { return $this->pos >= strlen($GLOBALS['__GT_BODY']); }
    public function stream_stat() { return []; }
}
stream_wrapper_unregister('php');
stream_wrapper_register('php', 'GtInputWrapper');

// curl is not installed in this PHP build; the endpoints only use it to post a
// Firebase notification. Record instead of sending.
// Writes (POST/PUT/PATCH) are listed in <state>.curl as before; every request is logged with
// method and body in <state>.curl_log; PUTs are kept in a tiny fake Firebase store
// (<state>.firebase) so a later GET of the same path sees them. GT_FAKE_FIREBASE_FAIL=1
// makes every request fail (no response).
foreach (['CURLOPT_RETURNTRANSFER'=>19913,'CURLOPT_POST'=>47,'CURLOPT_POSTFIELDS'=>10015,'CURLOPT_HTTPHEADER'=>10023,'CURLOPT_TIMEOUT'=>13,'CURLOPT_CUSTOMREQUEST'=>10036,'CURLOPT_SSL_VERIFYPEER'=>64,'CURLINFO_HTTP_CODE'=>2097154] as $__k=>$__v) { if (!defined($__k)) define($__k,$__v); }
$GLOBALS['__GT_FB_FILE'] = $state . '.firebase';
$GLOBALS['__GT_FB'] = is_file($GLOBALS['__GT_FB_FILE']) ? (json_decode(file_get_contents($GLOBALS['__GT_FB_FILE']), true) ?: []) : [];
$GLOBALS['__GT_CURL_LOG'] = is_file($state . '.curl_log') ? (json_decode(file_get_contents($state . '.curl_log'), true) ?: []) : [];
function curl_init($url = null) { $GLOBALS['__GT_CURLH'][] = ['url' => $url, 'method' => 'GET', 'body' => null, 'code' => 0]; return count($GLOBALS['__GT_CURLH']); }
function curl_setopt($h, $o, $v)
{
    if ($o === CURLOPT_POST && $v) $GLOBALS['__GT_CURLH'][$h - 1]['method'] = 'POST';
    if ($o === CURLOPT_CUSTOMREQUEST) $GLOBALS['__GT_CURLH'][$h - 1]['method'] = strtoupper($v);
    if ($o === CURLOPT_POSTFIELDS) $GLOBALS['__GT_CURLH'][$h - 1]['body'] = $v;
    return true;
}
function curl_exec($h)
{
    $req = &$GLOBALS['__GT_CURLH'][$h - 1];
    $GLOBALS['__GT_CURL_LOG'][] = ['method' => $req['method'], 'url' => $req['url'], 'body' => $req['body']];
    if ($req['method'] !== 'GET') $GLOBALS['__GT_CURL'][] = $req['url'];
    if (getenv('GT_FAKE_FIREBASE_FAIL') === '1') return false;
    $req['code'] = 200;
    $path = (string)parse_url((string)$req['url'], PHP_URL_PATH);
    if ($req['method'] === 'GET') return array_key_exists($path, $GLOBALS['__GT_FB']) ? json_encode($GLOBALS['__GT_FB'][$path]) : 'null';
    if ($req['method'] === 'PUT') { $GLOBALS['__GT_FB'][$path] = json_decode((string)$req['body'], true); return (string)$req['body']; }
    return '{}';
}
function curl_getinfo($h, $opt = 0) { return $GLOBALS['__GT_CURLH'][$h - 1]['code'] ?? 0; }
function curl_close($h) {}

register_shutdown_function(function () {
    file_put_contents(getenv('GT_PHP_STATE') . '.cookies', json_encode($GLOBALS['__GT_COOKIES'] ?? new stdClass()));
    if (!empty($GLOBALS['__GT_CURL'])) {
        file_put_contents(getenv('GT_PHP_STATE') . '.curl', json_encode($GLOBALS['__GT_CURL']));
    }
    if (!empty($GLOBALS['__GT_CURL_LOG'])) {
        file_put_contents(getenv('GT_PHP_STATE') . '.curl_log', json_encode($GLOBALS['__GT_CURL_LOG']));
    }
    file_put_contents($GLOBALS['__GT_FB_FILE'], json_encode($GLOBALS['__GT_FB']));
});

ini_set('log_errors', '1');
ini_set('error_log', $state . '.errlog');
chdir(dirname($script));
require $script;
