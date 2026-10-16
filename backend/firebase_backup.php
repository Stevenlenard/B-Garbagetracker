<?php
/**
 * Daily Firebase Realtime Database backup (run by a Hostinger cron job, never from the web).
 *
 *   php firebase_backup.php [--out=DIR] [--keep=14] [--no-db]
 *
 * Works with the locked-down database rules (firebase/database.rules.json) WITHOUT any
 * Firebase secret:
 *  - collections the app reads as a whole are downloaded whole;
 *  - per-account nodes (residents, driver settings/sessions, notification inboxes) cannot be
 *    listed, so they are read one account at a time using the account IDs from MySQL.
 * login_security (temporary sign-in lockout counters) is not backed up.
 *
 * Output: gzip JSON in gt_private/firebase_backups (outside public_html); the newest
 * --keep files are kept. Exit code 1 when any node could not be read (the file is still
 * written, with the failures listed under "_backup.errors").
 */

if (PHP_SAPI !== 'cli') {
    http_response_code(403);
    exit;
}

// GT_FB_URL / GT_FB_QUERY override the database only for local tests (emulator).
define('FB_URL', getenv('GT_FB_URL') ?: 'https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app');
define('FB_QUERY', getenv('GT_FB_QUERY') ?: '');
const FB_WHOLE_NODES = [
    'admin_settings', 'collection_logs', 'collection_progress', 'collection_schedule', 'complaints',
    'driver_routes', 'load_history', 'notifications', 'puroks', 'simulation_routes', 'system_logs',
    'truck_issues', 'truck_locations', 'trucks', 'users', 'weekly_collection_progress',
];

$opts = getopt('', ['out::', 'keep::', 'no-db']);
$outDir = isset($opts['out']) && $opts['out'] !== false ? rtrim($opts['out'], '/\\')
    : dirname(__DIR__, 2) . DIRECTORY_SEPARATOR . 'gt_private' . DIRECTORY_SEPARATOR . 'firebase_backups';
$keep = max(1, (int)($opts['keep'] ?? 14));

if (!is_dir($outDir) && !@mkdir($outDir, 0700, true)) {
    fwrite(STDERR, "firebase_backup: cannot create $outDir\n");
    exit(1);
}

function fb_get($path, &$error)
{
    $url = FB_URL . '/' . $path . '.json' . (FB_QUERY !== '' ? '?' . FB_QUERY : '');
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 120, CURLOPT_CONNECTTIMEOUT => 15]);
        $body = curl_exec($ch);
        $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $transportErr = curl_error($ch);
        curl_close($ch);
    } else {
        $body = @file_get_contents($url, false, stream_context_create(['http' => ['timeout' => 120, 'ignore_errors' => true]]));
        $status = (isset($http_response_header[0]) && preg_match('/\s(\d{3})\s/', $http_response_header[0], $m)) ? (int)$m[1] : 0;
        $transportErr = 'request failed';
    }
    if ($body === false || $status !== 200) {
        $error = "$path: " . ($body === false ? $transportErr : "HTTP $status");
        return null;
    }
    $data = json_decode($body, true);
    if ($data === null && trim($body) !== 'null') {
        $error = "$path: invalid JSON";
        return null;
    }
    return $data;
}

$backup = [];
$errors = [];

foreach (FB_WHOLE_NODES as $node) {
    $err = null;
    $value = fb_get($node, $err);
    if ($err !== null) {
        $errors[] = $err;
        continue;
    }
    if ($value !== null) $backup[$node] = $value;
}

// Per-account nodes, by the account IDs in MySQL.
$accounts = []; // [role, id]
if (!isset($opts['no-db'])) {
    try {
        require __DIR__ . '/db_config.php';
        foreach ($conn->query("SELECT resident_id FROM residents")->fetchAll(PDO::FETCH_COLUMN) as $id) $accounts[] = ['resident', (string)$id];
        foreach ($conn->query("SELECT user_id, role FROM users")->fetchAll(PDO::FETCH_ASSOC) as $r) $accounts[] = [strtolower((string)$r['role']), (string)$r['user_id']];
    } catch (Throwable $e) {
        $errors[] = 'mysql account list: ' . $e->getMessage();
    }
}
if (!$accounts && isset($backup['users']) && is_array($backup['users'])) {
    // Without MySQL: at least the drivers/admins known to Firebase.
    foreach ($backup['users'] as $id => $u) $accounts[] = [strtolower((string)($u['role'] ?? 'driver')), (string)$id];
}

foreach ($accounts as [$role, $id]) {
    if (!preg_match('/^[A-Za-z0-9_-]+$/', $id)) continue;
    $paths = ["notification_inbox/{$role}_{$id}"];
    if ($role === 'resident') $paths[] = "residents/$id";
    if ($role === 'driver') {
        $paths[] = "driver_settings/$id";
        $paths[] = "driver_sessions/$id";
    }
    foreach ($paths as $p) {
        $err = null;
        $value = fb_get($p, $err);
        if ($err !== null) {
            $errors[] = $err;
            continue;
        }
        if ($value === null) continue;
        [$node, $key] = explode('/', $p, 2);
        $backup[$node][$key] = $value;
    }
}

$backup['_backup'] = [
    'created_at' => date('c'),
    'source' => FB_URL,
    'nodes' => array_values(array_diff(array_keys($backup), ['_backup'])),
    'errors' => $errors,
];

$file = $outDir . DIRECTORY_SEPARATOR . 'firebase_' . date('Y-m-d_His') . '.json.gz';
$json = json_encode($backup, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
if ($json === false || file_put_contents($file, gzencode($json, 9), LOCK_EX) === false) {
    fwrite(STDERR, "firebase_backup: could not write $file\n");
    exit(1);
}

// Keep the newest $keep backups.
$all = glob($outDir . DIRECTORY_SEPARATOR . 'firebase_*.json.gz') ?: [];
rsort($all);
foreach (array_slice($all, $keep) as $old) @unlink($old);

printf("firebase_backup: %s (%d bytes, %d nodes, %d errors)\n", basename($file), filesize($file), count($backup['_backup']['nodes']), count($errors));
foreach ($errors as $e) fwrite(STDERR, "  $e\n");
exit($errors ? 1 : 0);
