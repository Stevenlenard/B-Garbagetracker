<?php
/**
 * Backend regression tests for account registration, login/approval and the
 * complaint workflow. Runs the REAL backend/*.php files against an in-memory fake
 * database (see fake_pdo.php). Nothing production is contacted.
 *
 *   php test/php/run_tests.php
 */
$root = dirname(__DIR__, 2);
$backend = $root . '/backend';
$tmp = sys_get_temp_dir() . '/gt_php_tests_' . getmypid();
@mkdir($tmp, 0777, true);

$pass = 0;
$fail = 0;
$failures = [];

function call(string $script, ?array $json = null, ?array $post = null, array $env = []): array
{
    global $backend, $tmp, $state;
    $body = $tmp . '/body.json';
    $postFile = $tmp . '/post.json';
    @unlink($body);
    @unlink($postFile);
    if ($json !== null) file_put_contents($body, json_encode($json));
    if ($post !== null) file_put_contents($postFile, json_encode($post));
    $cmd = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/run_endpoint.php') . ' '
        . escapeshellarg($backend . '/' . $script) . ' ' . escapeshellarg($state) . ' '
        . escapeshellarg($body) . ' ' . escapeshellarg($postFile);
    foreach ($env as $k => $v) putenv("$k=$v");
    $out = shell_exec($cmd . ' 2>&1');
    foreach ($env as $k => $_) putenv($k);
    $decoded = json_decode((string)$out, true);
    return ['raw' => $out, 'json' => $decoded];
}

/** A driver application still PENDING (created before public driver sign-up was closed). */
function seed_pending_driver(string $username = 'driver01', string $email = 'juan@example.com'): void
{
    $db = db();
    $db['users'][] = [
        'user_id' => count($db['users'] ?? []) + 1, 'username' => $username, 'name' => 'Juan Driver', 'email' => $email,
        'password_hash' => password_hash('Secret#1', PASSWORD_BCRYPT), 'phone' => '09181234567', 'license_number' => 'N01-23-456789',
        'preferred_truck' => 'GT-007', 'role' => 'driver', 'is_archived' => 0, 'approval_status' => 'pending', 'account_status' => 'active',
    ];
    seed(['users' => $db['users']]);
}

function db(): array
{
    global $state;
    return is_file($state) ? unserialize(file_get_contents($state)) : [];
}

function seed(array $tables): void
{
    global $state;
    $cur = db();
    foreach ($tables as $t => $rows) $cur[$t] = $rows;
    file_put_contents($state, serialize($cur));
}

function reset_state(): void
{
    global $state;
    foreach (glob($state . '*') as $f) @unlink($f);
}

function check(string $name, bool $ok, string $detail = ''): void
{
    global $pass, $fail, $failures;
    if ($ok) {
        $pass++;
        echo "  PASS  $name\n";
    } else {
        $fail++;
        $failures[] = $name;
        echo "  FAIL  $name" . ($detail !== '' ? "  -> $detail" : '') . "\n";
    }
}

function begin(string $name): void
{
    global $state, $tmp;
    echo "\n$name\n";
    $state = $tmp . '/state.ser';
    reset_state();
}

$goodResident = [
    'username' => 'maria01', 'name' => 'Maria Santos', 'email' => 'maria@example.com',
    'password' => 'Secret#1', 'role' => 'resident', 'phone' => '09171234567',
    'purok' => 'Purok 1', 'complete_address' => 'Blk 1', 'termsAccepted' => 1,
];
$goodDriver = [
    'username' => 'driver01', 'name' => 'Juan Driver', 'email' => 'juan@example.com',
    'password' => 'Secret#1', 'role' => 'driver', 'phone' => '09181234567',
    'license_number' => 'N01-23-456789', 'preferred_truck' => 'GT-007', 'termsAccepted' => 1,
];

// ---------------------------------------------------------------- registration
begin('Resident registration');
$r = call('register.php', $goodResident);
check('resident registers successfully', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
check('response carries the new user_id', ($r['json']['user_id'] ?? 0) > 0);
$res = db()['residents'][0] ?? [];
check('resident is auto-approved and active', ($res['approval_status'] ?? '') === 'approved' && ($res['account_status'] ?? '') === 'active' && (int)($res['is_archived'] ?? 1) === 0);
check('password is stored hashed (bcrypt), never plain', isset($res['password_hash']) && $res['password_hash'] !== 'Secret#1' && password_verify('Secret#1', $res['password_hash']));
check('admin was notified through Firebase (server side)', is_file($state . '.curl'));

begin('Driver registration (public sign-up closed)');
$r = call('register.php', $goodDriver);
check('public driver sign-up is refused', ($r['json']['success'] ?? true) === false, $r['raw'] ?? '');
check('the message points to the barangay administrator', stripos($r['json']['message'] ?? '', 'administrator') !== false);
check('no driver row was created', count(db()['users'] ?? []) === 0);

begin('Registration safety');
$r = call('register.php', array_merge($goodResident, ['role' => 'admin', 'username' => 'evil']));
check('public registration of an ADMIN is refused', ($r['json']['success'] ?? true) === false);
check('no admin row was created', count(db()['users'] ?? []) === 0 && count(db()['residents'] ?? []) === 0);

$r = call('register.php', array_merge($goodResident, ['termsAccepted' => 0]));
check('terms must be accepted', ($r['json']['success'] ?? true) === false);

call('register.php', $goodResident);
$r = call('register.php', array_merge($goodResident, ['email' => 'other@example.com']));
check('duplicate username is refused with a clear message', ($r['json']['success'] ?? true) === false && stripos($r['json']['message'] ?? '', 'username') !== false, $r['raw'] ?? '');
$r = call('register.php', array_merge($goodResident, ['username' => 'maria02']));
check('duplicate email is refused with a clear message', ($r['json']['success'] ?? true) === false && stripos($r['json']['message'] ?? '', 'email') !== false);
seed_pending_driver();
$r = call('register.php', array_merge($goodResident, ['username' => 'driver01', 'email' => 'x@example.com']));
check('username already used by a USER account is refused for residents too', ($r['json']['success'] ?? true) === false);
check('exactly one resident and one driver exist', count(db()['residents']) === 1 && count(db()['users']) === 1);

$r = call('register.php', array_merge($goodResident, ['username' => 'ab']));
check('too-short username is refused', ($r['json']['success'] ?? true) === false);
$r = call('register.php', array_merge($goodResident, ['username' => 'new user']));
check('username with spaces is refused', ($r['json']['success'] ?? true) === false);
$r = call('register.php', array_merge($goodResident, ['username' => 'okname', 'password' => '123']));
check('short password is refused', ($r['json']['success'] ?? true) === false);
$r = call('register.php', array_merge($goodResident, ['username' => 'okname2', 'email' => 'not-an-email']));
check('invalid email is refused', ($r['json']['success'] ?? true) === false);
$r = call('register.php', ['username' => 'x']);
check('incomplete data is refused without a crash', ($r['json']['success'] ?? true) === false);
$r = call('register.php', array_merge($goodResident, ['username' => "o'brien"]));
check('apostrophes in the username do not break SQL (prepared statements)', ($r['json'] !== null));


// ---------------------------------------------------------------- login
begin('Login');
call('register.php', $goodResident);
seed_pending_driver(); // an application from before driver sign-up was closed
$r = call('login.php', ['username_or_email' => 'maria01', 'password' => 'Secret#1']);
check('resident can log in with username', ($r['json']['success'] ?? false) === true && ($r['json']['user']['role'] ?? '') === 'resident', $r['raw'] ?? '');
check('login response never includes the password hash', strpos($r['raw'] ?? '', 'password_hash') === false);
$r = call('login.php', ['username_or_email' => 'maria@example.com', 'password' => 'Secret#1']);
check('resident can log in with e-mail', ($r['json']['success'] ?? false) === true);
$r = call('login.php', ['username_or_email' => 'maria01', 'password' => 'wrong']);
check('wrong password is refused', ($r['json']['success'] ?? true) === false);
$r = call('login.php', ['username_or_email' => 'nobody', 'password' => 'Secret#1']);
check('unknown user is refused', ($r['json']['success'] ?? true) === false);

$r = call('login.php', ['username_or_email' => 'driver01', 'password' => 'Secret#1']);
check('PENDING driver cannot log in', ($r['json']['success'] ?? true) === false && stripos($r['json']['message'] ?? '', 'pending') !== false, $r['raw'] ?? '');

// ---------------------------------------------------------------- approval
begin('Driver approval');
seed_pending_driver();
$driverId = db()['users'][0]['user_id'];
$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver']);
check('admin approval succeeds', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$u = db()['users'][0];
check('approval_status becomes approved (what the admin list uses)', $u['approval_status'] === 'approved');
check('account is active and not archived', $u['account_status'] === 'active' && (int)$u['is_archived'] === 0);
$r = call('login.php', ['username_or_email' => 'driver01', 'password' => 'Secret#1']);
check('approved driver can log in', ($r['json']['success'] ?? false) === true && ($r['json']['user']['role'] ?? '') === 'driver', $r['raw'] ?? '');
$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver']);
check('approving twice is harmless (idempotent success)', ($r['json']['success'] ?? false) === true);
$r = call('approve_user.php', ['user_id' => 9999, 'role' => 'driver']);
check('approving an unknown user reports not found', ($r['json']['success'] ?? true) === false);

begin('Driver rejection');
seed_pending_driver();
$driverId = db()['users'][0]['user_id'];
call('reject_user.php', ['user_id' => $driverId, 'role' => 'driver']);
$r = call('login.php', ['username_or_email' => 'driver01', 'password' => 'Secret#1']);
check('REJECTED driver cannot log in', ($r['json']['success'] ?? true) === false && stripos($r['json']['message'] ?? '', 'not approved') !== false, $r['raw'] ?? '');

begin('Legacy accounts are not locked out');
// Approved by the OLD approve_user.php (only cleared is_archived): the row still says
// "pending", but the driver has been logging in for months.
seed([
    'users' => [[
        'user_id' => 5, 'username' => 'oldtimer', 'name' => 'Old Timer', 'email' => 'old@example.com',
        'role' => 'driver', 'is_archived' => 0, 'approval_status' => 'pending', 'account_status' => 'active',
        'password_hash' => password_hash('Secret#1', PASSWORD_BCRYPT), 'two_factor_enabled' => 0,
    ]],
    'access_logs' => [['user_id' => 5, 'username' => 'oldtimer', 'action' => 'Successful Login']],
]);
$r = call('login.php', ['username_or_email' => 'oldtimer', 'password' => 'Secret#1']);
check('legacy approved driver (status still "pending", has logged in) can log in', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');

begin('Older database without the approval columns');
seed([
    'users' => [[
        'user_id' => 6, 'username' => 'legacy', 'name' => 'Legacy', 'email' => 'l@example.com',
        'role' => 'driver', 'is_archived' => 0,
        'password_hash' => password_hash('Secret#1', PASSWORD_BCRYPT), 'two_factor_enabled' => 0,
    ]],
]);
$r = call('login.php', ['username_or_email' => 'legacy', 'password' => 'Secret#1'], null, ['GT_FAKE_MISSING_COLUMNS' => 'approval_status,account_status']);
check('login still works when approval_status does not exist', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$r = call('approve_user.php', ['user_id' => 6, 'role' => 'driver'], null, ['GT_FAKE_MISSING_COLUMNS' => 'approval_status,account_status']);
check('approval falls back to the archive flag on an older schema', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');

begin('Archived accounts');
seed([
    'users' => [[
        'user_id' => 7, 'username' => 'gone', 'name' => 'Gone', 'email' => 'g@example.com',
        'role' => 'driver', 'is_archived' => 1, 'approval_status' => 'approved',
        'password_hash' => password_hash('Secret#1', PASSWORD_BCRYPT), 'two_factor_enabled' => 0,
    ]],
]);
$r = call('login.php', ['username_or_email' => 'gone', 'password' => 'Secret#1']);
check('archived account cannot log in', ($r['json']['success'] ?? true) === false);

// ---------------------------------------------------------------- complaints
begin('Complaint submission');
call('register.php', $goodResident);
seed(['users' => [['user_id' => 1, 'username' => 'admin', 'role' => 'admin', 'email' => 'admin@example.com', 'email_notifications' => 1]]]);
$residentId = db()['residents'][0]['resident_id'];
$r = call('file_complaint.php', null, [
    'resident_id' => (string)$residentId, 'category' => 'Missed collection',
    'description' => 'Truck did not pass on Monday', 'purok' => 'Purok 1', 'location' => 'Corner St',
]);
check('complaint is accepted', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$c = db()['complaints'][0] ?? [];
check('category and description are stored exactly', ($c['category'] ?? '') === 'Missed collection' && ($c['description'] ?? '') === 'Truck did not pass on Monday');
check('complaint belongs to the submitting resident', (string)($c['resident_id'] ?? '') === (string)$residentId);
check('status starts as pending', ($c['status'] ?? '') === 'pending');
check('purok and location are stored', ($c['purok'] ?? '') === 'Purok 1' && ($c['location'] ?? '') === 'Corner St');
check('response returns the complaint id', ($r['json']['complaint_id'] ?? 0) > 0);

$r = call('file_complaint.php', null, ['resident_id' => '0', 'category' => 'X', 'description' => 'Y']);
check('resident id 0 (no session) is refused', ($r['json']['success'] ?? true) === false);
$r = call('file_complaint.php', null, ['resident_id' => '99999', 'category' => 'X', 'description' => 'Y']);
check('unknown resident is refused', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 1);
$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'X']);
check('missing description is refused', ($r['json']['success'] ?? true) === false);
$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'X', 'description' => str_repeat('a', 2500)]);
check('oversized description is refused', ($r['json']['success'] ?? true) === false);

$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'Other', 'description' => '<img src=x onerror=alert(1)>']);
$mail = is_file($state . '.mail') ? file_get_contents($state . '.mail') : '';
check('an admin e-mail was prepared for the complaint', $mail !== '');
check('HTML in a complaint is escaped in the admin e-mail', $mail !== '' && strpos($mail, '<img') === false && strpos($mail, '&lt;img') !== false);

// Anti-spam: 3 reports per resident in 24 hours (two are stored above: the first and the escaped HTML one).
$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'Other', 'description' => 'Third report']);
check('a third report within 24 hours is accepted', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$before = count(db()['complaints']);
$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'Other', 'description' => 'Fourth report']);
check('a fourth report within 24 hours is refused with a clear message', ($r['json']['success'] ?? true) === false
    && ($r['json']['limit_reached'] ?? false) === true && count(db()['complaints']) === $before, $r['raw'] ?? '');

begin('Complaint review and resolution');
call('register.php', $goodResident);
$residentId = db()['residents'][0]['resident_id'];
call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'Missed collection', 'description' => 'Not collected']);
$cid = db()['complaints'][0]['complaint_id'];

$r = call('update_complaint.php', null, ['complaint_id' => (string)$cid, 'status' => 'in_progress', 'admin_response' => 'Looking into it']);
check('admin can mark in progress', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
check('previous status is reported (pending)', ($r['json']['previous_status'] ?? '') === 'pending');
check('status change persisted', db()['complaints'][0]['status'] === 'in_progress');

$r = call('update_complaint.php', null, ['complaint_id' => (string)$cid, 'status' => 'resolved', 'admin_response' => 'Collected today']);
check('admin can resolve', ($r['json']['success'] ?? false) === true);
check('previous status is reported (in_progress)', ($r['json']['previous_status'] ?? '') === 'in_progress');
check('resolved status and response persisted', db()['complaints'][0]['status'] === 'resolved' && db()['complaints'][0]['admin_response'] === 'Collected today');

$r = call('update_complaint.php', null, ['complaint_id' => (string)$cid, 'status' => 'resolved', 'admin_response' => 'Collected today']);
check('re-resolving reports previous=resolved so the app can skip a second notification', ($r['json']['previous_status'] ?? '') === 'resolved');

$r = call('update_complaint.php', null, ['complaint_id' => '424242', 'status' => 'resolved']);
check('updating an unknown complaint fails (no notification will be sent)', ($r['json']['success'] ?? true) === false);
$r = call('update_complaint.php', null, ['status' => 'resolved']);
check('missing id is refused', ($r['json']['success'] ?? true) === false);

// ---------------------------------------------------------------- trip history (FULL / COMPLETED)
function hist(): array
{
    return db()['driver_trip_history'] ?? [];
}

$tripBase = ['trip_id' => 'trip-1', 'driver_id' => 7, 'driver_name' => 'Juan', 'truck_id' => 'GT-007'];

begin('Trip history: FULL freezes the collection record');
$r = call('save_trip_history.php', $tripBase + ['route_name' => 'Collection Route', 'route_status' => 'ACTIVE', 'start_time' => '8:00 AM', 'start_lat' => 13.75, 'start_lng' => 121.05]);
check('trip is created on start', ($r['json']['success'] ?? false) === true && count(hist()) === 1, $r['raw'] ?? '');
$r = call('save_trip_history.php', $tripBase + [
    'route_name' => 'Purok 1 · Purok 2', 'route_status' => 'FULL', 'full_time' => '2026-10-12T09:30:00',
    'start_time' => '8:00 AM', 'finish_lat' => 13.76, 'finish_lng' => 121.06, 'total_distance_km' => 4.2,
    'weight_kg' => 5000.0, 'weight_type' => 'ESTIMATED', 'areas_visited' => 'Purok 1 · Purok 2',
]);
$h = hist()[0];
check('FULL stores status, distance and end point', $h['route_status'] === 'FULL' && (float)$h['total_distance_km'] == 4.2 && (float)$h['finish_lat'] == 13.76, json_encode($h));
check('FULL time is persisted (Load History date)', !empty($h['full_time']) && strpos($h['full_time'], '2026-10-12 09:30') === 0);
check('estimated load and visited areas persisted', (float)$h['weight_kg'] == 5000.0 && $h['weight_type'] === 'ESTIMATED' && $h['areas_visited'] === 'Purok 1 · Purok 2');

// COMPLETED arrives later with a generic name and the CURRENT (landfill) position / longer distance.
$r = call('save_trip_history.php', $tripBase + [
    'route_name' => 'Collection Route', 'route_status' => 'COMPLETED', 'end_time' => '2026-10-12T11:00:00',
    'finish_lat' => 13.90, 'finish_lng' => 121.20, 'total_distance_km' => 19.8,
]);
$h = hist()[0];
check('COMPLETED sets the final status and end time', $h['route_status'] === 'COMPLETED' && strpos((string)$h['end_time'], '2026-10-12 11:00') === 0);
check('COMPLETED does NOT overwrite the collection distance', (float)$h['total_distance_km'] == 4.2, (string)$h['total_distance_km']);
check('COMPLETED does NOT move the collection end point', (float)$h['finish_lat'] == 13.76 && (float)$h['finish_lng'] == 121.06);
check('FULL time and load survive COMPLETED', strpos($h['full_time'], '2026-10-12 09:30') === 0 && (float)$h['weight_kg'] == 5000.0);
check('visited-area route name is not replaced by the generic name', $h['route_name'] === 'Purok 1 · Purok 2');
check('still exactly one history row for the trip', count(hist()) === 1);

$r = call('save_trip_history.php', $tripBase + ['route_name' => 'Collection Route', 'route_status' => 'ACTIVE', 'total_distance_km' => 30.0]);
$h = hist()[0];
check('a late ACTIVE write cannot reopen a completed trip or change its distance', $h['route_status'] === 'COMPLETED' && (float)$h['total_distance_km'] == 4.2);

begin('Trip history: retries and legacy trips');
call('save_trip_history.php', $tripBase + ['route_name' => 'Collection Route', 'route_status' => 'ACTIVE']);
call('save_trip_history.php', $tripBase + ['route_status' => 'FULL', 'full_time' => '2026-10-12T09:30:00', 'total_distance_km' => 4.2, 'finish_lat' => 13.76, 'finish_lng' => 121.06]);
call('save_trip_history.php', $tripBase + ['route_status' => 'FULL', 'full_time' => '2026-10-12T10:45:00', 'total_distance_km' => 6.0, 'finish_lat' => 13.8, 'finish_lng' => 121.1]);
$h = hist()[0];
check('a repeated FULL (double tap / retry) does not change the frozen record', (float)$h['total_distance_km'] == 4.2 && strpos($h['full_time'], '09:30') !== false && count(hist()) === 1);

seed(['driver_trip_history' => [['trip_id' => 'old-1', 'driver_id' => 7, 'route_status' => 'ACTIVE', 'total_distance_km' => 1.0, 'route_name' => 'Collection Route']]]);
call('save_trip_history.php', ['trip_id' => 'old-1', 'driver_id' => 7, 'route_status' => 'COMPLETED', 'total_distance_km' => 8.5, 'end_time' => '2026-10-12T12:00:00']);
$h = hist()[0];
check('a legacy trip (no FULL) still records its distance at COMPLETED', $h['route_status'] === 'COMPLETED' && (float)$h['total_distance_km'] == 8.5);

begin('Trip history: older schema and simulations');
$r = call('save_trip_history.php', $tripBase + ['route_status' => 'FULL', 'full_time' => '2026-10-12T09:30:00', 'total_distance_km' => 4.2, 'weight_kg' => 5000], null, ['GT_FAKE_MISSING_COLUMNS' => 'full_time,weight_kg,weight_type,areas_visited']);
check('works when the load-history columns do not exist yet', ($r['json']['success'] ?? false) === true && count(hist()) === 1, $r['raw'] ?? '');
reset_state();
$r = call('save_trip_history.php', $tripBase + ['route_status' => 'FULL', 'is_simulation' => true]);
check('simulation records are not written', ($r['json']['success'] ?? false) === true && count(hist()) === 0);

begin('Approval grace switch');
seed([
    'users' => [[
        'user_id' => 5, 'username' => 'oldtimer', 'name' => 'Old Timer', 'email' => 'old@example.com',
        'role' => 'driver', 'is_archived' => 0, 'approval_status' => 'pending', 'account_status' => 'active',
        'password_hash' => password_hash('Secret#1', PASSWORD_BCRYPT), 'two_factor_enabled' => 0,
    ]],
    'access_logs' => [['user_id' => 5, 'username' => 'oldtimer', 'action' => 'Successful Login']],
]);
$r = call('login.php', ['username_or_email' => 'oldtimer', 'password' => 'Secret#1'], null, ['GT_TEST_GRACE_OFF' => '1']);
check('with the grace switched OFF a still-pending account is blocked even with login history', ($r['json']['success'] ?? true) === false);
seed(['access_logs' => [['user_id' => 5, 'username' => 'oldtimer', 'action' => 'Login Attempt (Not Approved)']]]);
$r = call('login.php', ['username_or_email' => 'oldtimer', 'password' => 'Secret#1']);
check('"Login Attempt (Not Approved)" entries never authorize a pending driver', ($r['json']['success'] ?? true) === false);
seed(['users' => [[
        'user_id' => 8, 'username' => 'rej', 'name' => 'Rej', 'email' => 'rej@example.com',
        'role' => 'driver', 'is_archived' => 0, 'approval_status' => 'rejected',
        'password_hash' => password_hash('Secret#1', PASSWORD_BCRYPT), 'two_factor_enabled' => 0,
    ]],
    'access_logs' => [['user_id' => 8, 'username' => 'rej', 'action' => 'Successful Login']],
]);
$r = call('login.php', ['username_or_email' => 'rej', 'password' => 'Secret#1']);
check('a rejected account stays blocked even with a successful-login history', ($r['json']['success'] ?? true) === false);

// ---------------------------------------------------------------- load history / summary
function load_lib(array $rows, int $year): array
{
    global $backend, $tmp;
    $rowsFile = $tmp . '/rows.json';
    file_put_contents($rowsFile, json_encode($rows));
    $script = $tmp . '/lib_probe.php';
    file_put_contents($script, '<?php require "' . str_replace('\\', '/', $backend) . '/load_history_lib.php";
$rows = json_decode(file_get_contents("' . str_replace('\\', '/', $rowsFile) . '"), true);
$u = gt_unique_finalized_trips($rows);
echo json_encode([
  "ids" => array_column($u, "trip_id"),
  "summary" => gt_summarize_loads($u),
  "months" => gt_monthly_buckets($u, ' . $year . '),
]);');
    $out = shell_exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($script));
    return json_decode((string)$out, true) ?: ['raw' => $out];
}

begin('Load History: finalized collections only, one per trip');
$rows = [
    ['trip_id' => 'A', 'route_status' => 'FULL', 'full_time' => '2026-10-12 09:30:00', 'start_time' => '2026-10-12 08:00:00', 'weight_kg' => 5000, 'weight_type' => 'ESTIMATED', 'total_distance_km' => 4.2],
    ['trip_id' => 'A', 'route_status' => 'COMPLETED', 'full_time' => '2026-10-12 09:30:00', 'start_time' => '2026-10-12 08:00:00', 'weight_kg' => 5000, 'weight_type' => 'ESTIMATED', 'total_distance_km' => 4.2],
    ['trip_id' => 'B', 'route_status' => 'ACTIVE', 'start_time' => '2026-10-12 08:00:00', 'total_distance_km' => 25.0],
    ['trip_id' => 'C', 'route_status' => 'COMPLETED', 'start_time' => '2026-10-05 08:00:00', 'weight_kg' => 4200, 'weight_type' => 'MEASURED', 'total_distance_km' => 6.0],
    ['trip_id' => 'D', 'route_status' => 'INTERRUPTED', 'start_time' => '2026-10-06 08:00:00', 'total_distance_km' => 3.0],
    ['trip_id' => 'E', 'route_status' => 'ACTIVE', 'full_time' => '2026-10-07 10:00:00', 'start_time' => '2026-10-07 08:00:00', 'total_distance_km' => 2.0],
];
$r = load_lib($rows, 2026);
sort($r['ids']);
check('only finalized trips are loads (ACTIVE and INTERRUPTED are not)', $r['ids'] === ['A', 'C', 'E'], json_encode($r['ids'] ?? $r));
check('a trip present twice is counted once', count(array_keys($r['ids'], 'A')) === 1);
check('a stored FULL time makes a load even if the status text lags', in_array('E', $r['ids'], true));
check('summary totals: 3 loads, 14.2 t (5 + 4.2 measured + 5 default estimate)', $r['summary']['total_trips'] === 3 && abs($r['summary']['total_weight_kg'] - 14200) < 0.01, json_encode($r['summary']));
check('measured vs estimated counts', $r['summary']['measured_trips_count'] === 1 && $r['summary']['estimated_trips_count'] === 2);
check('estimates are never reported as all-measured', $r['summary']['is_all_measured'] === false);
$oct = $r['months'][9];
check('monthly chart uses the same loads (October = 3 trips, 14.2 t)', $oct['trip_count'] === 3 && abs($oct['total_weight_tons'] - 14.2) < 0.001, json_encode($oct));
$chartKg = array_sum(array_column($r['months'], 'total_weight_kg'));
check('chart total equals summary total (no second source of truth)', abs($chartKg - $r['summary']['total_weight_kg']) < 0.01);

begin('Load History: FULL then COMPLETED through save_trip_history is ONE load');
$base = ['trip_id' => 'trip-9', 'driver_id' => 7, 'driver_name' => 'Juan', 'truck_id' => 'GT-007'];
call('save_trip_history.php', $base + ['route_status' => 'FULL', 'full_time' => '2026-10-12T09:30:00', 'start_time' => '2026-10-12T08:00:00',
    'total_distance_km' => 4.2, 'finish_lat' => 13.76, 'finish_lng' => 121.06, 'weight_kg' => 5000, 'weight_type' => 'ESTIMATED']);
call('save_trip_history.php', $base + ['route_status' => 'FULL', 'full_time' => '2026-10-12T09:30:00', 'start_time' => '2026-10-12T08:00:00', 'total_distance_km' => 4.2]);
call('save_trip_history.php', $base + ['route_status' => 'COMPLETED', 'end_time' => '2026-10-12T11:00:00', 'total_distance_km' => 22.0, 'finish_lat' => 13.9, 'finish_lng' => 121.2]);
$other = ['trip_id' => 'trip-10', 'driver_id' => 9, 'driver_name' => 'Ana', 'truck_id' => 'GT-009'];
call('save_trip_history.php', $other + ['route_status' => 'FULL', 'full_time' => '2026-10-12T10:00:00', 'start_time' => '2026-10-12T08:30:00', 'total_distance_km' => 3.1]);
$rows = hist();
check('one stored row per trip id (2 trips)', count($rows) === 2, (string)count($rows));
$r = load_lib($rows, 2026);
check('both drivers each produce exactly one load', count($r['ids']) === 2 && $r['summary']['total_trips'] === 2);
$byId = [];
foreach ($rows as $row) $byId[$row['trip_id']] = $row;
check('the load keeps the FULL distance (4.2), not the landfill distance', (float)$byId['trip-9']['total_distance_km'] == 4.2);
check('driver and truck stay attached to their own trip', $byId['trip-9']['driver_id'] == 7 && $byId['trip-9']['truck_id'] === 'GT-007' && $byId['trip-10']['driver_id'] == 9 && $byId['trip-10']['truck_id'] === 'GT-009');
check('COMPLETED did not replace the FULL time', strpos($byId['trip-9']['full_time'], '09:30') !== false);

// ---------------------------------------------------------------- login identity contract
function seed_two_drivers(): void
{
    seed([
        'users' => [
            [
                'user_id' => 15, 'username' => 'Steven', 'name' => 'Steven Espaldon', 'email' => 'steven@example.com',
                'phone' => '09170000001', 'license_number' => 'N01', 'preferred_truck' => 'GT-007', 'role' => 'driver',
                'is_archived' => 0, 'approval_status' => 'approved', 'two_factor_enabled' => 0,
                'password_hash' => password_hash('Steven#Pass1', PASSWORD_BCRYPT),
            ],
            [
                'user_id' => 16, 'username' => 'Maria', 'name' => 'Maria Santos', 'email' => 'maria.driver@example.com',
                'phone' => '09170000002', 'license_number' => 'N02', 'preferred_truck' => 'GT-009', 'role' => 'driver',
                'is_archived' => 0, 'approval_status' => 'approved', 'two_factor_enabled' => 0,
                'password_hash' => password_hash('Maria#Pass2', PASSWORD_BCRYPT),
            ],
        ],
        'residents' => [
            [
                'resident_id' => 15, 'username' => 'Pedro', 'name' => 'Pedro Cruz', 'email' => 'pedro@example.com',
                'purok' => 'Purok 1', 'complete_address' => 'Blk 1', 'is_archived' => 0, 'approval_status' => 'approved',
                'password_hash' => password_hash('Pedro#Pass3', PASSWORD_BCRYPT),
            ],
        ],
    ]);
}

begin('Login identity: the typed identifier AND its password must both match');
seed_two_drivers();
$r = call('login.php', ['username_or_email' => 'Steven', 'password' => 'Steven#Pass1']);
check('correct username + correct password -> success', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
check('returns that driver\'s own identity (id, username, role, truck)',
    ($r['json']['user']['user_id'] ?? null) == 15 && ($r['json']['user']['username'] ?? '') === 'Steven'
    && ($r['json']['user']['role'] ?? '') === 'driver' && ($r['json']['user']['preferred_truck'] ?? '') === 'GT-007');
check('the response never contains the password hash', strpos($r['raw'] ?? '', 'password_hash') === false && strpos($r['raw'] ?? '', '$2y$') === false);

$r = call('login.php', ['username_or_email' => 'Labubu', 'password' => 'Steven#Pass1']);
check('UNKNOWN username + a real driver\'s correct password -> failure', ($r['json']['success'] ?? true) === false, $r['raw'] ?? '');
check('failure carries no user object', !isset($r['json']['user']));

$r = call('login.php', ['username_or_email' => 'Steven', 'password' => 'wrong-password']);
check('correct username + wrong password -> failure', ($r['json']['success'] ?? true) === false);

$r = call('login.php', ['username_or_email' => 'Maria', 'password' => 'Steven#Pass1']);
check('driver B username + driver A password -> failure', ($r['json']['success'] ?? true) === false);
$r = call('login.php', ['username_or_email' => 'Steven', 'password' => 'Maria#Pass2']);
check('driver A username + driver B password -> failure', ($r['json']['success'] ?? true) === false);

$r = call('login.php', ['username_or_email' => 'maria.driver@example.com', 'password' => 'Steven#Pass1']);
check('driver B EMAIL + driver A password -> failure (no OR shortcut through email)', ($r['json']['success'] ?? true) === false);

$r = call('login.php', ['username_or_email' => '', 'password' => 'Steven#Pass1']);
check('empty username + a valid password -> failure (no password-only login)', ($r['json']['success'] ?? true) === false);
$r = call('login.php', ['username_or_email' => 'Steven', 'password' => '']);
check('valid username + empty password -> failure', ($r['json']['success'] ?? true) === false);

$r = call('login.php', ['username_or_email' => 'Pedro', 'password' => 'Steven#Pass1']);
check('a RESIDENT username with a DRIVER password -> failure', ($r['json']['success'] ?? true) === false);

$r = call('login.php', ['username_or_email' => 'steven@example.com', 'password' => 'Steven#Pass1']);
check('the registered EMAIL is an intentional alias and resolves to the same driver',
    ($r['json']['success'] ?? false) === true && ($r['json']['user']['user_id'] ?? null) == 15 && ($r['json']['user']['username'] ?? '') === 'Steven');

$r = call('login.php', ['username_or_email' => 'Maria', 'password' => 'Maria#Pass2']);
check('a second driver authenticates as THAT driver (no identity mix)',
    ($r['json']['success'] ?? false) === true && ($r['json']['user']['user_id'] ?? null) == 16
    && ($r['json']['user']['preferred_truck'] ?? '') === 'GT-009' && ($r['json']['user']['name'] ?? '') === 'Maria Santos');

$r = call('login.php', ['username_or_email' => 'Pedro', 'password' => 'Pedro#Pass3']);
check('a resident with the SAME numeric id as a driver stays a resident',
    ($r['json']['success'] ?? false) === true && ($r['json']['user']['role'] ?? '') === 'resident' && ($r['json']['user']['user_id'] ?? null) == 15);

$log = db()['access_logs'] ?? [];
$okUsers = array_values(array_unique(array_map(function ($l) { return $l['username']; },
    array_filter($log, function ($l) { return strpos($l['action'], 'Successful Login') === 0; }))));
sort($okUsers);
check('the access log names the REAL account that authenticated, never the typed text',
    $okUsers === ['Maria', 'Pedro', 'Steven'] && !in_array('Labubu', array_column($log, 'username'), true), json_encode($okUsers));

// ---------------------------------------------------------------- authorization
const SECRET = 'unit-test-secret-unit-test-secret-0123456789';

function login_token(string $user, string $pass, array $env): ?string
{
    $r = call('login.php', ['username_or_email' => $user, 'password' => $pass], null, $env);
    return $r['json']['user']['auth_token'] ?? null;
}

begin('Authorization: legacy mode (no secret configured) keeps current clients working');
call('register.php', $goodResident);
seed_pending_driver();
$driverId = db()['users'][0]['user_id'];
$residentId = db()['residents'][0]['resident_id'];
$r = call('login.php', ['username_or_email' => 'maria01', 'password' => 'Secret#1']);
check('no token is issued while no secret is configured', !isset($r['json']['user']['auth_token']));
$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver']);
check('token-less approval still works (old APK / web)', ($r['json']['success'] ?? false) === true);
$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'X', 'description' => 'Y']);
check('token-less complaint still works', ($r['json']['success'] ?? false) === true);

begin('Authorization: token-optional mode (secret set, not enforced)');
$env = ['GT_TEST_AUTH_SECRET' => SECRET];
call('register.php', $goodResident);
seed_pending_driver('driver02', 'd2@example.com');
$driverId = db()['users'][0]['user_id'];
$residentId = db()['residents'][0]['resident_id'];
seed(['users' => array_merge(db()['users'], [[
    'user_id' => 90, 'username' => 'boss', 'name' => 'Boss', 'email' => 'boss@example.com', 'role' => 'admin',
    'is_archived' => 0, 'approval_status' => 'approved', 'two_factor_enabled' => 0,
    'password_hash' => password_hash('Admin#123', PASSWORD_BCRYPT),
]])]);
$resTok = login_token('maria01', 'Secret#1', $env);
$admTok = login_token('boss', 'Admin#123', $env);
check('resident login returns a token', is_string($resTok) && strpos($resTok, '.') !== false);
check('admin login returns a token', is_string($admTok));

$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver'], null, $env + ['GT_TEST_TOKEN' => $resTok]);
check('a RESIDENT token cannot approve a driver', ($r['json']['success'] ?? true) === false && db()['users'][0]['approval_status'] === 'pending', $r['raw'] ?? '');
$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver'], null, $env + ['GT_TEST_TOKEN' => $admTok]);
check('an ADMIN token can approve a driver', ($r['json']['success'] ?? false) === true && db()['users'][0]['approval_status'] === 'approved');
$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver'], null, $env);
check('legacy token-less request is still accepted in token-optional mode', ($r['json']['success'] ?? false) === true);

$r = call('file_complaint.php', null, ['resident_id' => '9999', 'category' => 'X', 'description' => 'Y'], $env + ['GT_TEST_TOKEN' => $resTok]);
check('a resident token cannot file under ANOTHER resident id', ($r['json']['success'] ?? true) === false && count(db()['complaints'] ?? []) === 0, $r['raw'] ?? '');
$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'X', 'description' => 'Y'], $env + ['GT_TEST_TOKEN' => $resTok]);
check('a resident token can file under its own id', ($r['json']['success'] ?? false) === true);
$cid = db()['complaints'][0]['complaint_id'];
$r = call('update_complaint.php', null, ['complaint_id' => (string)$cid, 'status' => 'resolved'], $env + ['GT_TEST_TOKEN' => $resTok]);
check('a resident token cannot resolve complaints', ($r['json']['success'] ?? true) === false && db()['complaints'][0]['status'] === 'pending');
$r = call('update_complaint.php', null, ['complaint_id' => (string)$cid, 'status' => 'resolved'], $env + ['GT_TEST_TOKEN' => $admTok]);
check('an admin cannot resolve without a resolution note', ($r['json']['code'] ?? '') === 'NOTE_REQUIRED' && db()['complaints'][0]['status'] === 'pending');
$r = call('update_complaint.php', null, ['complaint_id' => (string)$cid, 'status' => 'resolved', 'admin_response' => 'Garbage collected on Monday'], $env + ['GT_TEST_TOKEN' => $admTok]);
check('an admin token can resolve complaints', ($r['json']['success'] ?? false) === true && db()['complaints'][0]['status'] === 'resolved');

begin('Authorization: enforced mode');
$env = ['GT_TEST_AUTH_SECRET' => SECRET];
call('register.php', $goodResident);
seed_pending_driver();
$driverId = db()['users'][0]['user_id'];
$residentId = db()['residents'][0]['resident_id'];
seed(['users' => array_merge(db()['users'], [[
    'user_id' => 90, 'username' => 'boss', 'name' => 'Boss', 'email' => 'boss@example.com', 'role' => 'admin',
    'is_archived' => 0, 'approval_status' => 'approved', 'two_factor_enabled' => 0,
    'password_hash' => password_hash('Admin#123', PASSWORD_BCRYPT),
]])]);
$admTok = login_token('boss', 'Admin#123', $env);
$resTok = login_token('maria01', 'Secret#1', $env);
$enf = $env + ['GT_TEST_AUTH_ENFORCE' => '1'];

$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver'], null, $enf);
check('enforced: approving without a token is refused (401)', ($r['json']['success'] ?? true) === false && db()['users'][0]['approval_status'] === 'pending');
$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver'], null, $enf + ['GT_TEST_TOKEN' => 'forged.token']);
check('enforced: a forged token is refused', ($r['json']['success'] ?? true) === false);
// expired token
$expired = (function () { return null; })();
$r = call('approve_user.php', ['user_id' => $driverId, 'role' => 'driver'], null, $enf + ['GT_TEST_TOKEN' => $admTok]);
check('enforced: a valid admin token works', ($r['json']['success'] ?? false) === true);
$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'X', 'description' => 'Y'], $enf);
check('enforced: filing a complaint without a token is refused', ($r['json']['success'] ?? true) === false && count(db()['complaints'] ?? []) === 0);
$r = call('file_complaint.php', null, ['resident_id' => (string)$residentId, 'category' => 'X', 'description' => 'Y'], $enf + ['GT_TEST_TOKEN' => $resTok]);
check('enforced: the resident can file with their token', ($r['json']['success'] ?? false) === true);

begin('Authorization: token integrity');
$tmpTest = tempnam(sys_get_temp_dir(), 'gt');
file_put_contents($tmpTest, '<?php define("GT_AUTH_SECRET", "' . SECRET . '"); require "' . str_replace('\\', '/', $backend) . '/auth_token.php";
$t = gt_issue_token(5, "admin", 100, 1000);
echo json_encode([
  "ok" => gt_verify_token($t, 1050) !== null,
  "expired" => gt_verify_token($t, 1200) === null,
  "tampered" => gt_verify_token(substr($t, 0, -2) . "xx", 1050) === null,
  "payload_swapped" => gt_verify_token(strtr($t, ["a" => "b"]), 1050) === null,
  "role" => gt_verify_token($t, 1050)["role"],
]);');
$out = json_decode(shell_exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($tmpTest)), true);
@unlink($tmpTest);
check('a fresh token verifies', ($out['ok'] ?? false) === true);
check('an expired token is rejected', ($out['expired'] ?? false) === true);
check('a tampered signature is rejected', ($out['tampered'] ?? false) === true);
check('a modified payload is rejected', ($out['payload_swapped'] ?? false) === true);

begin('Authorization: 2FA step issues the token only for a LOGIN verification');
$env = ['GT_TEST_AUTH_SECRET' => SECRET];
seed([
    'users' => [[
        'user_id' => 91, 'username' => 'twofa', 'name' => 'Two', 'email' => 'two@example.com', 'role' => 'admin',
        'is_archived' => 0, 'approval_status' => 'approved', 'two_factor_enabled' => 0,
        'password_hash' => password_hash('Admin#123', PASSWORD_BCRYPT),
    ]],
    'password_resets' => [['email' => 'two@example.com', 'token' => '123456', 'expiry' => '2999-01-01 00:00:00']],
]);
$r = call('verify_otp.php', ['email' => 'two@example.com', 'otp' => '123456'], null, $env);
check('password-reset OTP never returns a login token', ($r['json']['success'] ?? false) === true && !isset($r['json']['auth_token']), $r['raw'] ?? '');
seed(['password_resets' => [['email' => 'two@example.com', 'token' => '123456', 'expiry' => '2999-01-01 00:00:00']]]);
$r = call('verify_otp.php', ['email' => 'two@example.com', 'otp' => '123456', 'purpose' => 'login'], null, $env);
check('a login OTP returns the token', !empty($r['json']['auth_token']), $r['raw'] ?? '');

// ---------------------------------------------------------------- admin endpoint authorization
function issue_token($id, string $role): string
{
    global $backend;
    $f = tempnam(sys_get_temp_dir(), 'gtt');
    file_put_contents($f, '<?php define("GT_AUTH_SECRET", "' . SECRET . '"); require "' . str_replace('\\', '/', $backend) . '/auth_token.php"; echo gt_issue_token(' . var_export($id, true) . ', ' . var_export($role, true) . ');');
    $t = trim((string)shell_exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($f)));
    @unlink($f);
    return $t;
}

// ---------------------------------------------------------------- admin creates drivers
begin('Admin creates driver accounts');
$adm = issue_token(1, 'admin');
seed(['users' => [['user_id' => 1, 'username' => 'admin', 'role' => 'admin', 'email' => 'admin@example.com', 'is_archived' => 0, 'approval_status' => 'approved', 'account_status' => 'active']]]);
$r = call('register.php', $goodDriver, null, ['GT_TEST_AUTH_SECRET' => SECRET, 'GT_TEST_TOKEN' => $adm]);
check('an administrator can create a driver account', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$drv = null;
foreach (db()['users'] as $u) if (($u['username'] ?? '') === 'driver01') $drv = $u;
check('the new driver is approved and active at once', ($drv['approval_status'] ?? '') === 'approved' && ($drv['account_status'] ?? '') === 'active' && ($drv['role'] ?? '') === 'driver');
$r = call('login.php', ['username_or_email' => 'driver01', 'password' => 'Secret#1']);
check('the driver can log in right away', ($r['json']['success'] ?? false) === true && ($r['json']['user']['role'] ?? '') === 'driver', $r['raw'] ?? '');
$r = call('register.php', array_merge($goodDriver, ['username' => 'driver02', 'email' => 'd2@example.com']), null, ['GT_TEST_AUTH_SECRET' => SECRET, 'GT_TEST_TOKEN' => issue_token(5, 'driver')]);
check('a driver token cannot create drivers', ($r['json']['success'] ?? true) === false);
$r = call('register.php', array_merge($goodDriver, ['username' => 'driver03', 'email' => 'd3@example.com']), null, ['GT_TEST_AUTH_SECRET' => SECRET, 'GT_TEST_TOKEN' => issue_token(7, 'resident')]);
check('a resident token cannot create drivers', ($r['json']['success'] ?? true) === false);
$r = call('register.php', array_merge($goodDriver, ['username' => 'driver 04', 'email' => 'd4@example.com']), null, ['GT_TEST_AUTH_SECRET' => SECRET, 'GT_TEST_TOKEN' => $adm]);
check('admin-created usernames follow the no-spaces rule', ($r['json']['success'] ?? true) === false);
$r = call('register.php', array_merge($goodDriver, ['email' => 'other@example.com']), null, ['GT_TEST_AUTH_SECRET' => SECRET, 'GT_TEST_TOKEN' => $adm]);
check('a duplicate driver username is refused', ($r['json']['success'] ?? true) === false && stripos($r['json']['message'] ?? '', 'username') !== false);

function seed_admin_world(): void
{
    reset_state();
    seed([
        'users' => [
            ['user_id' => 90, 'username' => 'boss', 'name' => 'Boss', 'email' => 'boss@example.com', 'role' => 'admin',
             'phone' => '0900', 'is_archived' => 0, 'approval_status' => 'approved', 'created_at' => '2026-01-01'],
            ['user_id' => 11, 'username' => 'drv1', 'name' => 'Driver One', 'email' => 'drv1@example.com', 'role' => 'driver',
             'phone' => '0911', 'license_number' => 'L-1', 'preferred_truck' => 'GT-007', 'is_archived' => 0,
             'approval_status' => 'approved', 'created_at' => '2026-01-02'],
            ['user_id' => 12, 'username' => 'oldarch', 'name' => 'Old Archived', 'email' => 'old@example.com', 'role' => 'driver',
             'is_archived' => 1, 'archived_at' => '2020-01-01 00:00:00', 'approval_status' => 'approved', 'created_at' => '2019-01-01'],
        ],
        'residents' => [
            ['resident_id' => 5, 'username' => 'res5', 'name' => 'Res Five', 'email' => 'r5@example.com', 'phone' => '0955',
             'purok' => 'Purok 2', 'complete_address' => 'Secret Street 5', 'is_archived' => 0, 'created_at' => '2026-02-01'],
            ['resident_id' => 6, 'username' => 'res6', 'name' => 'Res Six', 'email' => 'r6@example.com', 'phone' => '0966',
             'purok' => 'Purok 3', 'complete_address' => 'Secret Street 6', 'is_archived' => 0, 'created_at' => '2026-02-02'],
        ],
        'complaints' => [
            ['complaint_id' => 1, 'resident_id' => 5, 'category' => 'Missed', 'description' => 'a', 'status' => 'pending', 'is_archived' => 0, 'created_at' => '2019-01-01 00:00:00'],
            ['complaint_id' => 2, 'resident_id' => 6, 'category' => 'Missed', 'description' => 'b', 'status' => 'resolved', 'is_archived' => 0, 'created_at' => '2019-02-01 00:00:00'],
            ['complaint_id' => 3, 'resident_id' => 5, 'category' => 'Other', 'description' => 'c', 'status' => 'resolved', 'is_archived' => 1, 'created_at' => '2018-02-01 00:00:00'],
        ],
    ]);
}

$enf = ['GT_TEST_AUTH_SECRET' => SECRET, 'GT_TEST_AUTH_ENFORCE' => '1'];
$tok = ['admin' => issue_token(90, 'admin'), 'driver' => issue_token(11, 'driver'),
        'res5' => issue_token(5, 'resident'), 'res6' => issue_token(6, 'resident')];

begin('Admin endpoints: enforced mode');
seed_admin_world();
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => true], null, $enf);
check('archive_user: no token refused', ($r['json']['success'] ?? true) === false && (int)db()['users'][1]['is_archived'] === 0, $r['raw'] ?? '');
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => true], null, $enf + ['GT_TEST_TOKEN' => 'forged.token']);
check('archive_user: forged token refused', ($r['json']['success'] ?? true) === false && (int)db()['users'][1]['is_archived'] === 0);
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => true], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('archive_user: resident token refused (403)', ($r['json']['success'] ?? true) === false && (int)db()['users'][1]['is_archived'] === 0);
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => true], null, $enf + ['GT_TEST_TOKEN' => $tok['driver']]);
check('archive_user: driver token refused (403)', ($r['json']['success'] ?? true) === false && (int)db()['users'][1]['is_archived'] === 0);
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => true], null, $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
check('archive_user: admin token works', ($r['json']['success'] ?? false) === true && (int)db()['users'][1]['is_archived'] === 1);
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => false], null, $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
check('archive_user: admin can restore', ($r['json']['success'] ?? false) === true && (int)db()['users'][1]['is_archived'] === 0);

begin('Admin endpoints: get_users scoping and no automatic deletion');
seed_admin_world();
$r = call('get_users.php', null, null, $enf);
check('get_users: no token refused and no account data returned', ($r['json']['success'] ?? true) === false && !isset($r['json']['users']) && !isset($r['json']['residents']), $r['raw'] ?? '');
$r = call('get_users.php', null, null, $enf + ['GT_TEST_TOKEN' => 'forged.token']);
check('get_users: forged token refused', ($r['json']['success'] ?? true) === false);
$r = call('get_users.php', null, null, $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
$emails = array_column($r['json']['users'] ?? [], 'email');
check('get_users: admin gets the full lists (contact details included)',
    ($r['json']['success'] ?? false) === true && count($r['json']['residents'] ?? []) === 2 && in_array('drv1@example.com', $emails, true), $r['raw'] ?? '');
check('get_users: archived users older than 6 months are NOT deleted', count(db()['users']) === 3, (string)count(db()['users']));
$r = call('get_users.php', null, null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
$u = $r['json']['users'] ?? [];
$leak = false;
foreach ($u as $row) {
    foreach (['email', 'phone', 'license_number', 'username'] as $k) if (array_key_exists($k, $row)) $leak = true;
    if (($row['role'] ?? '') !== 'driver') $leak = true;
}
check('get_users: resident gets drivers only, no contact details, no resident rows',
    ($r['json']['success'] ?? false) === true && count($r['json']['residents'] ?? [1]) === 0 && count($u) === 2 && !$leak, $r['raw'] ?? '');
check('get_users: resident view keeps what dashboards use (name, truck, archived flag)',
    isset($u[0]['name'], $u[0]['preferred_truck'], $u[0]['is_archived']));
check('get_users: nothing was deleted by any call', count(db()['users']) === 3 && count(db()['residents']) === 2);

begin('Admin endpoints: delete_user (admin any, others only themselves)');
seed_admin_world();
$r = call('delete_user.php', ['user_id' => 6, 'role' => 'resident'], null, $enf);
check('delete_user: no token refused', ($r['json']['success'] ?? true) === false && count(db()['residents']) === 2);
$r = call('delete_user.php', ['user_id' => 6, 'role' => 'resident'], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('delete_user: a resident cannot delete another resident', ($r['json']['success'] ?? true) === false && count(db()['residents']) === 2);
$r = call('delete_user.php', ['user_id' => 11, 'role' => 'driver'], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('delete_user: a resident cannot delete a driver', ($r['json']['success'] ?? true) === false && count(db()['users']) === 3);
$r = call('delete_user.php', ['user_id' => 5, 'role' => 'driver'], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('delete_user: role/id mismatch is refused', ($r['json']['success'] ?? true) === false && count(db()['residents']) === 2);
$r = call('delete_user.php', ['user_id' => 5, 'role' => 'resident'], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('delete_user: a resident can delete their own account', ($r['json']['success'] ?? false) === true && count(db()['residents']) === 1);
$r = call('delete_user.php', ['user_id' => 11, 'role' => 'driver'], null, $enf + ['GT_TEST_TOKEN' => $tok['driver']]);
check('delete_user: a driver can delete their own account', ($r['json']['success'] ?? false) === true && count(db()['users']) === 2);
$r = call('delete_user.php', ['user_id' => 6, 'role' => 'resident'], null, $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
check('delete_user: admin can delete any account', ($r['json']['success'] ?? false) === true && count(db()['residents']) === 0);

begin('Admin endpoints: complaints (retained; delete/archive authorized)');
seed_admin_world();
$r = call('delete_complaint.php', ['complaint_id' => 1], null, $enf);
check('delete_complaint: no token refused, record kept', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 3);
$r = call('delete_complaint.php', ['complaint_id' => 2], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('delete_complaint: resident cannot delete another resident\'s complaint', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 3);
$r = call('delete_complaint.php', ['complaint_id' => 1], null, $enf + ['GT_TEST_TOKEN' => $tok['driver']]);
check('delete_complaint: driver token refused', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 3);
$r = call('delete_complaint.php', ['complaint_id' => 1], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('delete_complaint: resident can delete their own', ($r['json']['success'] ?? false) === true && count(db()['complaints']) === 2);
$r = call('delete_complaint.php', ['complaint_id' => 2], null, $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
check('delete_complaint: admin can delete', ($r['json']['success'] ?? false) === true && count(db()['complaints']) === 1);
seed_admin_world();
$r = call('bulk_delete_complaints.php', ['complaint_ids' => '1,2'], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('bulk_delete: resident refused', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 3);
$r = call('bulk_delete_complaints.php', ['complaint_ids' => '1,2'], null, $enf);
check('bulk_delete: no token refused', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 3);
$r = call('bulk_delete_complaints.php', ['complaint_ids' => '1,2'], null, $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
check('bulk_delete: admin works', ($r['json']['success'] ?? false) === true && count(db()['complaints']) === 1);
seed_admin_world();
$r = call('archive_complaint.php', ['complaint_id' => 1, 'is_archived' => 1], null, $enf + ['GT_TEST_TOKEN' => $tok['res5']]);
check('archive_complaint: resident refused', ($r['json']['success'] ?? true) === false && (int)db()['complaints'][0]['is_archived'] === 0);
$r = call('archive_complaint.php', ['complaint_id' => 1, 'is_archived' => 1], null, $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
check('archive_complaint: admin works and the record is kept', ($r['json']['success'] ?? false) === true && (int)db()['complaints'][0]['is_archived'] === 1 && count(db()['complaints']) === 3);
$r = call('get_users.php', null, null, $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
check('no automatic deletion: old complaints (2018/2019) survive every read', count(db()['complaints']) === 3);
$r = call('update_complaint.php', null, ['complaint_id' => '1', 'status' => 'resolved', 'admin_response' => 'Collected by the morning crew'], $enf + ['GT_TEST_TOKEN' => $tok['admin']]);
check('complaint resolution workflow still works', ($r['json']['success'] ?? false) === true && count(db()['complaints']) === 3, $r['raw'] ?? '');

begin('Admin endpoints: legacy / token-optional rollout keeps current clients working');
seed_admin_world();
$r = call('get_users.php');
check('legacy: get_users without a token still returns the full list', ($r['json']['success'] ?? false) === true && count($r['json']['residents'] ?? []) === 2);
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => true]);
check('legacy: archive_user without a token still works', ($r['json']['success'] ?? false) === true);
$opt = ['GT_TEST_AUTH_SECRET' => SECRET];
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => false], null, $opt);
check('token-optional: token-less admin client still works', ($r['json']['success'] ?? false) === true);
$r = call('archive_user.php', ['user_id' => 11, 'role' => 'driver', 'is_archived' => true], null, $opt + ['GT_TEST_TOKEN' => $tok['res5']]);
check('token-optional: a valid token of the wrong role is refused', ($r['json']['success'] ?? true) === false);

// ---------------------------------------------------------------- registration notifications and e-mail
function curl_count(): int
{
    global $state;
    $f = $state . '.curl';
    return is_file($f) ? count(json_decode(file_get_contents($f), true) ?: []) : 0;
}

function mails(): array
{
    global $state;
    $f = $state . '.mail';
    if (!is_file($f)) return [];
    return array_values(array_filter(array_map('json_decode', file($f, FILE_IGNORE_NEW_LINES))));
}

function errlog(): string
{
    global $state;
    return is_file($state . '.errlog') ? file_get_contents($state . '.errlog') : '';
}

$stubCfg = (string)file_get_contents(__DIR__ . '/stubs/email_config.php');
preg_match("/SMTP_PASS',\s*'([^']*)'/", $stubCfg, $pm);
$stubPass = $pm[1] ?? '';

function two_admins(): void
{
    seed(['users' => [
        ['user_id' => 1, 'username' => 'admin1', 'role' => 'admin', 'email' => 'a1@example.com', 'email_notifications' => 1, 'is_archived' => 0],
        ['user_id' => 2, 'username' => 'admin2', 'role' => 'admin', 'email' => 'a2@example.com', 'email_notifications' => 0, 'is_archived' => 0],
        ['user_id' => 3, 'username' => 'admin3', 'role' => 'admin', 'email' => 'a3@example.com', 'email_notifications' => 1, 'is_archived' => 0],
    ]]);
}

begin('Registration: Resident is auto-approved, one Admin notification, no e-mail');
reset_state();
two_admins();
$r = call('register.php', $goodResident);
check('resident registration succeeds', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$row = db()['residents'][0] ?? [];
check('resident is approved and active without Admin action',
    ($row['approval_status'] ?? '') === 'approved' && ($row['account_status'] ?? '') === 'active' && (int)($row['is_archived'] ?? 1) === 0);
check('exactly one Admin in-app notification is written by the server', curl_count() === 1, (string)curl_count());
check('no e-mail is sent to the Admin for a Resident', count(mails()) === 0);
$r = call('login.php', ['username_or_email' => $goodResident['username'], 'password' => $goodResident['password']]);
check('the resident can log in immediately', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');

begin('Registration: a driver created by the admin gets no application e-mail or pending notice');
reset_state();
two_admins();
$r = call('register.php', $goodDriver, null, ['GT_TEST_AUTH_SECRET' => SECRET, 'GT_TEST_TOKEN' => issue_token(1, 'admin')]);
check('admin-created driver succeeds', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$drv = null;
foreach (db()['users'] as $u) if (($u['role'] ?? '') === 'driver') $drv = $u;
check('admin-created driver is approved (nothing to review)', ($drv['approval_status'] ?? '') === 'approved');
check('no driver-application e-mail is sent', count(mails()) === 0, (string)count(mails()));
check('no "new driver application" notification is written', curl_count() === 0, (string)curl_count());

// ---------------------------------------------------------------- resident complaint -> admin
function complaint_world(): void
{
    reset_state();
    seed([
        'users' => [
            ['user_id' => 90, 'username' => 'boss', 'name' => 'Boss', 'email' => 'boss@example.com', 'role' => 'admin', 'email_notifications' => 0, 'is_archived' => 0],
            ['user_id' => 11, 'username' => 'drv1', 'name' => 'Driver', 'email' => 'd@example.com', 'role' => 'driver', 'is_archived' => 0],
        ],
        'residents' => [
            ['resident_id' => 5, 'username' => 'res5', 'name' => 'Res Five', 'email' => 'r5@example.com', 'purok' => 'Purok 2', 'is_archived' => 0],
            ['resident_id' => 6, 'username' => 'res6', 'name' => 'Res Six', 'email' => 'r6@example.com', 'purok' => 'Purok 3', 'is_archived' => 0],
        ],
        'complaints' => [
            ['complaint_id' => 1, 'resident_id' => 6, 'category' => 'Missed', 'description' => 'old resolved', 'status' => 'resolved',
             'purok' => 'Purok 3', 'location' => 'Purok 3', 'is_archived' => 1, 'created_at' => '2024-01-01 08:00:00'],
        ],
    ]);
}

$enf = ['GT_TEST_AUTH_SECRET' => SECRET, 'GT_TEST_AUTH_ENFORCE' => '1'];
$tAdmin = issue_token(90, 'admin');
$tRes5 = issue_token(5, 'resident');
$tRes6 = issue_token(6, 'resident');
$tDrv = issue_token(11, 'driver');
$submit = ['resident_id' => '5', 'category' => 'Uncollected Garbage', 'description' => 'pa collect ng trash', 'purok' => 'Purok 2', 'location' => 'Purok 2'];

begin('Complaint flow: Resident submission is saved once and notifies the Admin once');
complaint_world();
$r = call('file_complaint.php', null, $submit, $enf + ['GT_TEST_TOKEN' => $tRes5]);
check('submission succeeds and returns the new complaint id', ($r['json']['success'] ?? false) === true && ($r['json']['complaint_id'] ?? 0) > 1, $r['raw'] ?? '');
$rows = db()['complaints'];
check('exactly one new row was saved (no duplicate)', count($rows) === 2, (string)count($rows));
$new = end($rows);
check('row carries the resident, category, description and pending status',
    (string)$new['resident_id'] === '5' && $new['category'] === 'Uncollected Garbage' && $new['description'] === 'pa collect ng trash' && $new['status'] === 'pending');
check('exactly one Admin in-app notification is written by the server', curl_count() === 1, (string)curl_count());

begin('Complaint flow: Admin and the Resident can see it; others cannot');
complaint_world();
call('file_complaint.php', null, $submit, $enf + ['GT_TEST_TOKEN' => $tRes5]);
$r = call('get_complaints.php', null, null, $enf + ['GT_TEST_TOKEN' => $tAdmin]);
$data = $r['json']['data'] ?? [];
$mine = array_values(array_filter($data, function ($c) { return $c['description'] === 'pa collect ng trash'; }));
check('Admin sees the new complaint', ($r['json']['success'] ?? false) === true && count($mine) === 1, $r['raw'] ?? '');
check('Admin sees resident name, complaint purok/location and pending status',
    ($mine[0]['full_name'] ?? '') === 'Res Five' && ($mine[0]['purok'] ?? '') === 'Purok 2' && ($mine[0]['location'] ?? '') === 'Purok 2' && ($mine[0]['status'] ?? '') === 'pending');
check('Admin pending count includes it', count(array_filter($data, function ($c) { return $c['status'] === 'pending'; })) === 1);
check('archived and resolved complaints are retained in the Admin list',
    count(array_filter($data, function ($c) { return (int)$c['is_archived'] === 1 && $c['status'] === 'resolved'; })) === 1);
$r = call('get_complaints.php', null, null, $enf + ['GT_TEST_TOKEN' => $tRes5]);
$ids = array_column($r['json']['data'] ?? [], 'description');
check('the submitting resident sees their own complaint', in_array('pa collect ng trash', $ids, true));
check('the resident sees no other resident\'s complaint', !in_array('old resolved', $ids, true) && count($ids) === 1, json_encode($ids));
$r = call('get_complaints.php', null, null, $enf + ['GT_TEST_TOKEN' => $tRes6]);
$ids = array_column($r['json']['data'] ?? [], 'description');
check('another resident cannot see it, and keeps their own history incl. archived', !in_array('pa collect ng trash', $ids, true) && in_array('old resolved', $ids, true));

begin('Complaint flow: invalid or unauthorized requests');
complaint_world();
$r = call('file_complaint.php', null, $submit, $enf);
check('no token refused and nothing saved', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 1);
$r = call('file_complaint.php', null, $submit, $enf + ['GT_TEST_TOKEN' => $tRes6]);
check('a resident cannot file under another resident id', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 1);
$r = call('file_complaint.php', null, array_merge($submit, ['description' => '']), $enf + ['GT_TEST_TOKEN' => $tRes5]);
check('missing description is rejected with a clear message', ($r['json']['success'] ?? true) === false && count(db()['complaints']) === 1);
$r = call('get_complaints.php', null, null, $enf);
check('listing without a token is refused', ($r['json']['success'] ?? true) === false && !isset($r['json']['data']));
$r = call('get_complaints.php', null, null, $enf + ['GT_TEST_TOKEN' => $tDrv]);
check('driver token cannot list resident complaints', ($r['json']['success'] ?? true) === false);
$r = call('get_complaints.php');
check('legacy (no secret configured) listing keeps working for current clients', ($r['json']['success'] ?? false) === true && count($r['json']['data'] ?? []) === 1);

begin('Complaint flow: older database without purok/location columns still saves');
complaint_world();
$r = call('file_complaint.php', null, $submit, $enf + ['GT_TEST_TOKEN' => $tRes5, 'GT_FAKE_COMPLAINT_MISSING' => 'purok,location']);
check('submission succeeds on the reduced schema', ($r['json']['success'] ?? false) === true && count(db()['complaints']) === 2, $r['raw'] ?? '');
$r = call('get_complaints.php', null, null, $enf + ['GT_TEST_TOKEN' => $tAdmin, 'GT_FAKE_COMPLAINT_MISSING' => 'purok,location']);
check('Admin still sees it (area falls back to the resident purok)',
    count(array_filter($r['json']['data'] ?? [], function ($c) { return $c['description'] === 'pa collect ng trash' && $c['purok'] === 'Purok 2'; })) === 1, $r['raw'] ?? '');

begin('Complaint flow: an e-mail problem never fails or duplicates the submission');
complaint_world();
seed(['users' => [['user_id' => 90, 'username' => 'boss', 'role' => 'admin', 'email' => 'boss@example.com', 'email_notifications' => 1, 'is_archived' => 0]]]);
$r = call('file_complaint.php', null, $submit, $enf + ['GT_TEST_TOKEN' => $tRes5, 'GT_FAKE_MAIL_FAIL' => '1']);
check('submission still succeeds when SMTP fails', ($r['json']['success'] ?? false) === true && count(db()['complaints']) === 2, $r['raw'] ?? '');
check('the response is clean JSON with no SMTP details', stripos($r['raw'], 'authenticate') === false && stripos($r['raw'], 'smtp') === false);

// ---------------------------------------------------------------- route assignments
// "Now" is pinned to 2026-10-13 10:00 Asia/Manila (02:00 UTC).
const A_NOW = 1791856800; // 2026-10-13T02:00:00Z
function assignment_world(): void
{
    reset_state();
    seed([
        'users' => [
            ['user_id' => 90, 'username' => 'boss', 'name' => 'Boss', 'email' => 'boss@example.com', 'role' => 'admin', 'is_archived' => 0],
            ['user_id' => 11, 'username' => 'drv1', 'name' => 'Driver One', 'email' => 'd1@example.com', 'role' => 'driver', 'preferred_truck' => 'GT-007', 'is_archived' => 0],
            ['user_id' => 12, 'username' => 'drvarch', 'name' => 'Archived', 'email' => 'd2@example.com', 'role' => 'driver', 'is_archived' => 1],
            ['user_id' => 13, 'username' => 'drv3', 'name' => 'Driver Three', 'email' => 'd3@example.com', 'role' => 'driver', 'preferred_truck' => 'GT-009', 'is_archived' => 0],
        ],
    ]);
}
function a_row(int $id, string $date, int $driver, string $truck, ?string $cancelled = null): array
{
    return ['assignment_id' => $id, 'assignment_date' => $date, 'driver_id' => $driver, 'truck_id' => $truck, 'notes' => null,
        'created_by' => 90, 'cancelled_at' => $cancelled, 'cancelled_by' => null,
        'driver_day_key' => $cancelled ? null : "$driver|$date", 'truck_day_key' => $cancelled ? null : strtoupper($truck) . "|$date"];
}

$aBase = ['GT_ASSIGNMENT_TEST_NOW' => (string)A_NOW];
$aSec = $aBase + ['GT_TEST_AUTH_SECRET' => SECRET];
$tA = issue_token(90, 'admin');
$tD11 = issue_token(11, 'driver');
$tD13 = issue_token(13, 'driver');
$tR5 = issue_token(5, 'resident');
$newA = ['assignment_date' => '2026-10-13', 'driver_id' => 11, 'truck_id' => 'GT-007',
    'areas' => [['key' => 'central_purok_1', 'name' => 'Central (Purok 1)'], ['key' => 'purok_2', 'name' => 'Purok 2']]];
$recentStartMs = (A_NOW - 600) * 1000;

begin('Assignments: authorization is strict (no token-less path, fail closed without a secret)');
assignment_world();
foreach (['get_assignments.php', 'save_assignment.php', 'cancel_assignment.php', 'link_assignment_trip.php'] as $ep) {
    $r = call($ep, $newA + ['assignment_id' => 1, 'trip_id' => 't1', 'trip_started_at_ms' => $recentStartMs], null, $aBase);
    check("$ep refuses while no auth secret is configured (legacy mode)", ($r['json']['success'] ?? true) === false && stripos($r['raw'], 'not available') !== false, $r['raw'] ?? '');
    $r = call($ep, $newA + ['assignment_id' => 1, 'trip_id' => 't1', 'trip_started_at_ms' => $recentStartMs], null, $aSec);
    check("$ep refuses a token-less request even with enforcement OFF", ($r['json']['success'] ?? true) === false && stripos($r['raw'], 'log in') !== false, $r['raw'] ?? '');
}
check('no assignment row was written by refused requests', count(db()['route_assignments'] ?? []) === 0);
$r = call('save_assignment.php', $newA, null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('a driver cannot create assignments', ($r['json']['success'] ?? true) === false && count(db()['route_assignments']) === 0, $r['raw'] ?? '');
$r = call('cancel_assignment.php', ['assignment_id' => 1], null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('a driver cannot cancel assignments', ($r['json']['success'] ?? true) === false);
$r = call('get_assignments.php', ['start_date' => '2026-10-13'], null, $aSec + ['GT_TEST_TOKEN' => $tR5]);
check('a resident cannot list assignments', ($r['json']['success'] ?? true) === false);
$r = call('link_assignment_trip.php', ['trip_id' => 't1', 'truck_id' => 'GT-007', 'trip_started_at_ms' => $recentStartMs], null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('an admin token cannot link trips (driver-only)', ($r['json']['success'] ?? true) === false);

begin('Assignments: create, validate and prevent overlaps');
assignment_world();
$r = call('save_assignment.php', $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('admin creates an assignment for today (Asia/Manila)', ($r['json']['success'] ?? false) === true && ($r['json']['data']['status'] ?? '') === 'PENDING' && count($r['json']['data']['areas'] ?? []) === 2, $r['raw'] ?? '');
$r = call('save_assignment.php', ['truck_id' => 'GT-010'] + $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('second assignment for the same driver/day is refused', ($r['json']['success'] ?? true) === false && count(db()['route_assignments']) === 1, $r['raw'] ?? '');
$r = call('save_assignment.php', ['driver_id' => 13, 'truck_id' => 'gt-007'] + $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('the same truck (any letter case) on the same day is refused', ($r['json']['success'] ?? true) === false && count(db()['route_assignments']) === 1, $r['raw'] ?? '');
$r = call('save_assignment.php', ['assignment_date' => '2026-10-12'] + $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('a past date is refused (no invented historical schedules)', ($r['json']['success'] ?? true) === false);
$r = call('save_assignment.php', ['driver_id' => 12, 'assignment_date' => '2026-10-14'] + $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('an archived driver is refused', ($r['json']['success'] ?? true) === false);
$r = call('save_assignment.php', ['areas' => [], 'assignment_date' => '2026-10-14'] + $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('an assignment without areas is refused', ($r['json']['success'] ?? true) === false);
$r = call('save_assignment.php', ['driver_id' => 13, 'truck_id' => 'GT-009', 'assignment_date' => '2026-10-14'] + $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('another driver/truck on another day is accepted', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$r = call('get_assignments.php', ['start_date' => '2026-10-01', 'end_date' => '2026-10-31'], null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
$own = $r['json']['data'] ?? [];
check('a driver lists ONLY their own assignments', count($own) === 1 && (int)$own[0]['driver_id'] === 11, $r['raw'] ?? '');
$r = call('get_assignments.php', ['start_date' => '2026-10-01', 'end_date' => '2026-10-31', 'driver_id' => 13], null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('a driver cannot widen the list with a driver_id filter', count($r['json']['data'] ?? []) === 1 && (int)$r['json']['data'][0]['driver_id'] === 11);

begin('Assignments: trip linking (driver app)');
assignment_world();
seed(['route_assignments' => [a_row(1, '2026-10-13', 11, 'GT-007')],
      'route_assignment_areas' => [['assignment_id' => 1, 'area_key' => 'purok_2', 'area_name' => 'Purok 2', 'sequence_order' => 0]]]);
$link = ['trip_id' => 'trip_A', 'truck_id' => 'GT-007', 'trip_started_at_ms' => $recentStartMs];
$r = call('link_assignment_trip.php', $link, null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('the owner links today\'s trip to their assignment', ($r['json']['linked'] ?? false) === true && (int)$r['json']['assignment_id'] === 1, $r['raw'] ?? '');
$r = call('link_assignment_trip.php', $link, null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('linking again is idempotent (one link row)', ($r['json']['linked'] ?? false) === true && count(db()['route_assignment_trips']) === 1);
$r = call('get_assignments.php', ['start_date' => '2026-10-13'], null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('a linked open trip makes the assignment IN_PROGRESS', ($r['json']['data'][0]['status'] ?? '') === 'IN_PROGRESS', $r['raw'] ?? '');
$r = call('link_assignment_trip.php', ['trip_id' => 'trip_B', 'truck_id' => 'GT-099'] + $link, null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('a different truck is not linked', ($r['json']['linked'] ?? true) === false && ($r['json']['reason'] ?? '') === 'truck_mismatch');
$r = call('link_assignment_trip.php', ['trip_id' => 'trip_C'] + $link, null, $aSec + ['GT_TEST_TOKEN' => $tD13]);
check('another driver cannot attach a trip to driver 11\'s assignment', ($r['json']['linked'] ?? true) === false && ($r['json']['reason'] ?? '') === 'no_assignment');
$r = call('link_assignment_trip.php', ['trip_id' => 'trip_D', 'trip_started_at_ms' => (A_NOW - 3 * 86400) * 1000] + $link, null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('an old trip start cannot be back-linked', ($r['json']['linked'] ?? true) === false && ($r['json']['reason'] ?? '') === 'invalid_request');
seed(['driver_trip_history' => [['trip_id' => 'trip_E', 'driver_id' => 13, 'truck_id' => 'GT-007', 'route_status' => 'ACTIVE']]]);
$r = call('link_assignment_trip.php', ['trip_id' => 'trip_E'] + $link, null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('a trip recorded for another driver is refused', ($r['json']['linked'] ?? true) === false && ($r['json']['reason'] ?? '') === 'not_owner');
check('only the one legitimate link exists', count(db()['route_assignment_trips']) === 1);

begin('Assignments: save_trip_history links only with a verified matching driver token');
assignment_world();
seed(['route_assignments' => [a_row(1, '2026-10-13', 11, 'GT-007')]]);
$hist = ['trip_id' => 'trip_H', 'driver_id' => 11, 'truck_id' => 'GT-007', 'route_status' => 'FULL', 'start_time' => '2026-10-13T08:30:00'];
$r = call('save_trip_history.php', $hist, null, $aSec);
check('token-less (legacy) save still stores the trip', ($r['json']['success'] ?? false) === true && count(db()['driver_trip_history']) === 1, $r['raw'] ?? '');
check('... but writes no assignment link', count(db()['route_assignment_trips'] ?? []) === 0 && !isset($r['json']['assignment_link']));
$r = call('save_trip_history.php', $hist, null, $aSec + ['GT_TEST_TOKEN' => $tD13]);
check('another driver\'s token does not link driver 11\'s trip', count(db()['route_assignment_trips'] ?? []) === 0);
$r = call('save_trip_history.php', $hist, null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
check('the owner\'s FULL save links the trip', ($r['json']['assignment_link']['linked'] ?? false) === true && count(db()['route_assignment_trips']) === 1, $r['raw'] ?? '');
$r = call('get_assignments.php', ['start_date' => '2026-10-13'], null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('FULL keeps the assignment IN_PROGRESS (not finalized)', ($r['json']['data'][0]['status'] ?? '') === 'IN_PROGRESS', $r['raw'] ?? '');
$r = call('save_trip_history.php', ['route_status' => 'COMPLETED', 'end_time' => '2026-10-13T11:00:00'] + $hist, null, $aSec + ['GT_TEST_TOKEN' => $tD11]);
$r = call('get_assignments.php', ['start_date' => '2026-10-13'], null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('COMPLETED closes the assignment', ($r['json']['data'][0]['status'] ?? '') === 'COMPLETED', $r['raw'] ?? '');
check('the link snapshot keeps the final status (survives history retention)', strtoupper((string)(db()['route_assignment_trips'][0]['trip_status'] ?? '')) === 'COMPLETED');
reset_state();
$r = call('save_trip_history.php', $hist, null, $aSec + ['GT_TEST_TOKEN' => $tD11, 'GT_FAKE_NO_ASSIGNMENT_TABLES' => '1']);
check('save_trip_history works when the assignment tables do not exist', ($r['json']['success'] ?? false) === true && !isset($r['json']['assignment_link']), $r['raw'] ?? '');

begin('Assignments: statuses, cancellation and completion rate');
assignment_world();
seed([
    'route_assignments' => [
        a_row(1, '2026-10-10', 11, 'GT-007'),            // past, no trip      -> MISSED
        a_row(2, '2026-10-11', 11, 'GT-007'),            // past, open trip    -> IN_PROGRESS
        a_row(3, '2026-10-12', 11, 'GT-007'),            // past, completed    -> COMPLETED
        a_row(4, '2026-10-12', 13, 'GT-009', '2026-10-11 09:00:00'), // cancelled
        a_row(5, '2026-10-15', 13, 'GT-009'),            // future             -> PENDING
    ],
    'route_assignment_trips' => [
        ['trip_id' => 'tr2', 'assignment_id' => 2, 'link_source' => 'DRIVER_APP', 'trip_status' => null],
        ['trip_id' => 'tr3', 'assignment_id' => 3, 'link_source' => 'TRIP_HISTORY', 'trip_status' => 'COMPLETED'],
    ],
    'driver_trip_history' => [['trip_id' => 'tr2', 'driver_id' => 11, 'route_status' => 'FULL']],
]);
$r = call('get_assignments.php', ['start_date' => '2026-10-01', 'end_date' => '2026-10-31'], null, $aSec + ['GT_TEST_TOKEN' => $tA]);
$by = [];
foreach ($r['json']['data'] ?? [] as $it) $by[$it['assignment_id']] = $it['status'];
check('past date without a trip is MISSED', ($by[1] ?? '') === 'MISSED', json_encode($by));
check('past date with a linked trip awaiting finalization is NOT missed', ($by[2] ?? '') === 'IN_PROGRESS', json_encode($by));
check('completed trip closes the assignment', ($by[3] ?? '') === 'COMPLETED');
check('cancelled stays CANCELLED; future is PENDING', ($by[4] ?? '') === 'CANCELLED' && ($by[5] ?? '') === 'PENDING');
$s = $r['json']['summary'] ?? [];
check('completion rate = completed due / due (cancelled and future excluded): 1/3', ($s['due'] ?? 0) === 3 && abs(($s['completion_rate'] ?? 0) - 33.3) < 0.01, json_encode($s));
$r = call('get_assignments.php', ['start_date' => '2026-10-20', 'end_date' => '2026-10-31'], null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('no due assignments -> completion rate is null (Not available)', array_key_exists('completion_rate', $r['json']['summary'] ?? []) && $r['json']['summary']['completion_rate'] === null, $r['raw'] ?? '');
$r = call('cancel_assignment.php', ['assignment_id' => 2], null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('an in-progress assignment cannot be cancelled', ($r['json']['success'] ?? true) === false);
$r = call('save_assignment.php', ['assignment_id' => 2, 'assignment_date' => '2026-10-16'] + $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('an in-progress assignment cannot be edited', ($r['json']['success'] ?? true) === false);
$r = call('cancel_assignment.php', ['assignment_id' => 5], null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('a pending assignment is cancelled (row kept)', ($r['json']['data']['status'] ?? '') === 'CANCELLED' && count(db()['route_assignments']) === 5, $r['raw'] ?? '');
$r = call('save_assignment.php', ['driver_id' => 13, 'truck_id' => 'GT-009', 'assignment_date' => '2026-10-15'] + $newA, null, $aSec + ['GT_TEST_TOKEN' => $tA]);
check('cancelling releases the driver/truck day for a new assignment', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');

begin('Trip history: no automatic deletion of completed trips');
$src = file_get_contents($backend . '/save_trip_history.php');
check('save_trip_history.php contains no DELETE statement', stripos($src, 'DELETE FROM') === false);
check('the former retention lock/purge is gone', stripos($src, 'retention_lock') === false && stripos($src, 'OFFSET 200') === false);

// ---------------------------------------------------------------- saved sign-in sessions
function cookies_set(): array
{
    global $state;
    $f = $state . '.cookies';
    return is_file($f) ? (json_decode(file_get_contents($f), true) ?: []) : [];
}

function token_payload(?string $t): array
{
    if (!$t || strpos($t, '.') === false) return [];
    $p = explode('.', $t)[0];
    return json_decode(base64_decode(strtr($p, '-_', '+/') . str_repeat('=', (4 - strlen($p) % 4) % 4)), true) ?: [];
}

$sec = ['GT_TEST_AUTH_SECRET' => SECRET];
$T0 = 1790000000; // fixed "now" for session tests
$sessionLogin = function (array $extra = [], array $env = []) use ($sec, $T0) {
    return call('login.php', array_merge(['username_or_email' => 'maria01', 'password' => 'Secret#1', 'session_v' => 1, 'client' => 'android', 'stay_signed_in' => true], $extra), null,
        $sec + ['GT_SESSION_TEST_NOW' => (string)$T0] + $env);
};
$refresh = function (array $body, int $now, array $env = []) use ($sec) {
    return call('session_refresh.php', $body, null, $sec + ['GT_SESSION_TEST_NOW' => (string)$now] + $env);
};

begin('Sessions: only opted-in clients on a configured server get one');
call('register.php', $goodResident);
$rid = db()['residents'][0]['resident_id'];
$r = call('login.php', ['username_or_email' => 'maria01', 'password' => 'Secret#1'], null, $sec);
$lp = token_payload($r['json']['user']['auth_token'] ?? null);
check('old client (no session_v): legacy token, no session block', isset($r['json']['user']['auth_token']) && !isset($r['json']['session']) && !isset($lp['sid']), $r['raw'] ?? '');
check('old client: legacy token still lasts 12 h', ($lp['exp'] ?? 0) - ($lp['iat'] ?? 0) === 43200);
$r = $sessionLogin([], ['GT_FAKE_NO_SESSION_TABLES' => '1']);
check('table not migrated yet: legacy behaviour, login still succeeds', ($r['json']['success'] ?? false) === true && !isset($r['json']['session']), $r['raw'] ?? '');
$r = call('login.php', ['username_or_email' => 'maria01', 'password' => 'Secret#1', 'session_v' => 1, 'client' => 'android', 'stay_signed_in' => true]);
check('no server secret: no token and no session (no tokenless session)', ($r['json']['success'] ?? false) === true && !isset($r['json']['session']) && !isset($r['json']['user']['auth_token']));
check('no session row was created without a secret or table', count(db()['auth_sessions'] ?? []) === 0);

begin('Sessions: Android "Stay signed in" login, rotation and no expiry');
call('register.php', $goodResident);
$rid = db()['residents'][0]['resident_id'];
$r = $sessionLogin();
$ses = $r['json']['session'] ?? [];
$rt1 = $ses['refresh_token'] ?? '';
$ap = token_payload($ses['access_token'] ?? null);
check('session block with refresh credential (Android)', $rt1 !== '' && ($ses['persistent'] ?? null) === true, $r['raw'] ?? '');
check('access token is short-lived (15 min) and names the session', ($ap['exp'] ?? 0) - ($ap['iat'] ?? 0) === 900 && !empty($ap['sid']) && ($ap['role'] ?? '') === 'resident');
check('user.auth_token is the same short-lived access token', ($r['json']['user']['auth_token'] ?? '') === ($ses['access_token'] ?? '-'));
$row = db()['auth_sessions'][0] ?? [];
$mac1 = explode('.', $rt1)[2] ?? 'missing';
check('the refresh credential is never stored (only salt + generation)', strlen($mac1) === 43 && strpos(serialize(db()['auth_sessions']), $mac1) === false && ($row['generation'] ?? 0) == 1);
check('no password material in the session row', strpos(serialize($row), 'Secret#1') === false && ($row['persistent'] ?? 0) == 1);

$body = ['role' => 'resident', 'user_id' => $rid, 'client' => 'android'];
$r = $refresh($body + ['refresh_token' => $rt1], $T0 + 600);
$rt2 = $r['json']['refresh_token'] ?? '';
check('refresh issues a new access token and ROTATES the refresh credential', ($r['json']['success'] ?? false) === true && $rt2 !== '' && $rt2 !== $rt1, $r['raw'] ?? '');
check('refresh returns the current profile (role re-read from the database)', ($r['json']['user']['role'] ?? '') === 'resident' && strpos($r['raw'] ?? '', 'password_hash') === false);
$r = $refresh($body + ['refresh_token' => $rt1], $T0 + 650);
check('lost reply / parallel refresh: the previous credential within 120 s gets the CURRENT one again',
    ($r['json']['success'] ?? false) === true && ($r['json']['refresh_token'] ?? '') === $rt2 && empty(db()['auth_sessions'][0]['revoked_at']) && (db()['auth_sessions'][0]['generation'] ?? 0) == 2, $r['raw'] ?? '');
$twoYears = $T0 + 2 * 365 * 86400;
$r = $refresh($body + ['refresh_token' => $rt2], $twoYears);
$rt3 = $r['json']['refresh_token'] ?? '';
check('persistent session still refreshes after 2 years without use (no fixed expiry)', ($r['json']['success'] ?? false) === true, $r['raw'] ?? '');
$r = $refresh($body + ['refresh_token' => $rt1], $twoYears + 100);
check('reusing an old rotated credential = compromise: refused', ($r['json']['reason'] ?? '') === 'revoked', $r['raw'] ?? '');
check('...and the whole session is revoked', (db()['auth_sessions'][0]['revoke_reason'] ?? '') === 'reuse_detected');
$r = $refresh($body + ['refresh_token' => $rt3], $twoYears + 200);
check('the newest credential of that session no longer works either', ($r['json']['success'] ?? true) === false);

begin('Sessions: non-persistent sessions end when idle; persistent never');
call('register.php', $goodResident);
$rid = db()['residents'][0]['resident_id'];
$r = $sessionLogin(['stay_signed_in' => false]);
$rt = $r['json']['session']['refresh_token'] ?? '';
check('non-persistent session is marked as such', ($r['json']['session']['persistent'] ?? null) === false && (db()['auth_sessions'][0]['persistent'] ?? 1) == 0);
$r = $refresh(['role' => 'resident', 'user_id' => $rid, 'client' => 'android', 'refresh_token' => $rt], $T0 + 3600);
$rt = $r['json']['refresh_token'] ?? '';
check('used within the idle window: refreshes', ($r['json']['success'] ?? false) === true);
$r = $refresh(['role' => 'resident', 'user_id' => $rid, 'client' => 'android', 'refresh_token' => $rt], $T0 + 3600 + 13 * 3600);
check('13 h idle: non-persistent session expired', ($r['json']['reason'] ?? '') === 'expired', $r['raw'] ?? '');

begin('Sessions: account changes revoke sessions');
$adminRow = ['user_id' => 1, 'username' => 'boss', 'name' => 'Boss', 'email' => 'boss@example.com', 'role' => 'admin',
    'password_hash' => password_hash('Secret#1', PASSWORD_DEFAULT), 'is_archived' => 0, 'two_factor_enabled' => 0, 'approval_status' => 'approved'];
$adminLogin = function () use ($sec, $T0) {
    return call('login.php', ['username_or_email' => 'boss', 'password' => 'Secret#1', 'session_v' => 1, 'client' => 'android', 'stay_signed_in' => true], null, $sec + ['GT_SESSION_TEST_NOW' => (string)$T0]);
};
$abody = ['role' => 'admin', 'user_id' => 1, 'client' => 'android'];
$cases = [
    'archived' => function (&$u) { $u['is_archived'] = 1; },
    'suspended (account_status)' => function (&$u) { $u['account_status'] = 'suspended'; },
    'rejected' => function (&$u) { $u['approval_status'] = 'rejected'; },
    'role changed' => function (&$u) { $u['role'] = 'driver'; },
    'password changed' => function (&$u) { $u['password_hash'] = password_hash('NewPass#2', PASSWORD_DEFAULT); },
];
foreach ($cases as $label => $mutate) {
    seed(['users' => [$adminRow], 'auth_sessions' => []]);
    $rt = $adminLogin()['json']['session']['refresh_token'] ?? '';
    $u = $adminRow;
    $mutate($u);
    seed(['users' => [$u]]);
    $r = $refresh($abody + ['refresh_token' => $rt], $T0 + 60);
    check("$label: refresh refused", ($r['json']['success'] ?? true) === false && $rt !== '', $r['raw'] ?? '');
    check("$label: session revoked server-side", !empty(db()['auth_sessions'][0]['revoked_at']));
}
seed(['users' => [$adminRow], 'auth_sessions' => []]);
$rt = $adminLogin()['json']['session']['refresh_token'] ?? '';
seed(['users' => []]);
$r = $refresh($abody + ['refresh_token' => $rt], $T0 + 60);
check('deleted account: refresh refused and revoked', ($r['json']['reason'] ?? '') === 'account_deleted' && !empty(db()['auth_sessions'][0]['revoked_at']), $r['raw'] ?? '');

begin('Sessions: logout, forged and cross-account credentials');
seed(['users' => [$adminRow], 'auth_sessions' => []]);
call('register.php', $goodResident);
$rid = db()['residents'][0]['resident_id'];
$rtA = $adminLogin()['json']['session']['refresh_token'] ?? '';
$rtR = $sessionLogin()['json']['session']['refresh_token'] ?? '';
$r = $refresh(['role' => 'admin', 'user_id' => $rid, 'client' => 'android', 'refresh_token' => $rtR], $T0 + 5);
check('a resident credential cannot be used as an admin', ($r['json']['success'] ?? true) === false);
$r = $refresh(['role' => 'admin', 'user_id' => 2, 'client' => 'android', 'refresh_token' => $rtA], $T0 + 5);
check('a credential cannot be used for another user id', ($r['json']['success'] ?? true) === false);
$r = $refresh(['role' => 'admin', 'user_id' => 1, 'client' => 'android', 'refresh_token' => explode('.', $rtA)[0] . '.1.' . str_repeat('A', 43)], $T0 + 5);
check('a forged secret is refused (and does not revoke the real session)', ($r['json']['success'] ?? true) === false && empty(db()['auth_sessions'][0]['revoked_at']));
$r = call('session_logout.php', ['role' => 'admin', 'user_id' => 1, 'client' => 'android', 'refresh_token' => $rtA], null, $sec + ['GT_SESSION_TEST_NOW' => (string)($T0 + 9)]);
check('logout revokes the session', ($r['json']['revoked'] ?? false) === true && (db()['auth_sessions'][0]['revoke_reason'] ?? '') === 'logout', $r['raw'] ?? '');
$r = $refresh(['role' => 'admin', 'user_id' => 1, 'client' => 'android', 'refresh_token' => $rtA], $T0 + 10);
check('after logout the credential is dead', ($r['json']['reason'] ?? '') === 'revoked');
$r = $refresh(['role' => 'resident', 'user_id' => $rid, 'client' => 'android', 'refresh_token' => $rtR], $T0 + 10);
check('logging one account out leaves the other account session alone', ($r['json']['success'] ?? false) === true);
$r = call('session_refresh.php', ['role' => 'resident', 'user_id' => $rid, 'client' => 'android', 'refresh_token' => $rtR], null, []);
check('server without a secret: refresh answers 503 unavailable (never a token)', ($r['json']['reason'] ?? '') === 'unavailable' && !isset($r['json']['access_token']));

begin('Sessions: Web uses an HttpOnly cookie with CSRF protection');
call('register.php', $goodResident);
$rid = db()['residents'][0]['resident_id'];
$r = $sessionLogin(['client' => 'web']);
$ck = cookies_set();
$name = 'gtrs_resident_' . $rid;
check('Web login: no refresh credential in the response body', isset($r['json']['session']) && strpos($r['raw'] ?? '', '"refresh_token"') === false, $r['raw'] ?? '');
check('Web login: refresh cookie is Secure, HttpOnly, SameSite=Strict, scoped to the backend', isset($ck[$name]) && $ck[$name]['opts']['secure'] === true && $ck[$name]['opts']['httponly'] === true && $ck[$name]['opts']['samesite'] === 'Strict' && $ck[$name]['opts']['path'] === '/backend/', json_encode($ck));
check('Stay signed in: cookie lasts the browser maximum (400 days)', ($ck[$name]['opts']['expires'] ?? 0) === $T0 + 34560000);
$cookieVal = $ck[$name]['value'] ?? '';
$wbody = ['role' => 'resident', 'user_id' => $rid, 'client' => 'web'];
$r = $refresh($wbody, $T0 + 30, ['GT_TEST_COOKIES' => json_encode([$name => $cookieVal])]);
check('Web refresh without the CSRF header is refused', ($r['json']['reason'] ?? '') === 'csrf', $r['raw'] ?? '');
$r = $refresh($wbody, $T0 + 30, ['GT_TEST_COOKIES' => json_encode([$name => $cookieVal]), 'GT_TEST_CSRF' => '1', 'GT_TEST_ORIGIN' => 'https://evil.example']);
check('Web refresh from another origin is refused', ($r['json']['reason'] ?? '') === 'csrf');
$r = $refresh($wbody, $T0 + 30, ['GT_TEST_COOKIES' => json_encode([$name => $cookieVal]), 'GT_TEST_CSRF' => '1', 'GT_TEST_ORIGIN' => 'https://app.example.test']);
$ck2 = cookies_set();
check('same-origin Web refresh succeeds; the credential stays out of the body', ($r['json']['success'] ?? false) === true && !isset($r['json']['refresh_token']), $r['raw'] ?? '');
check('the cookie is rotated and its lifetime renewed', ($ck2[$name]['value'] ?? $cookieVal) !== $cookieVal && ($ck2[$name]['opts']['expires'] ?? 0) === $T0 + 30 + 34560000);
$r = call('session_logout.php', $wbody, null, $sec + ['GT_SESSION_TEST_NOW' => (string)($T0 + 40), 'GT_TEST_COOKIES' => json_encode([$name => $ck2[$name]['value'] ?? '']), 'GT_TEST_CSRF' => '1']);
$ck3 = cookies_set();
check('Web logout revokes the session and deletes the cookie', ($r['json']['revoked'] ?? false) === true && ($ck3[$name]['opts']['expires'] ?? 0) === 1 && ($ck3[$name]['value'] ?? 'x') === '', $r['raw'] ?? '');
$r = $sessionLogin(['client' => 'web', 'stay_signed_in' => false]);
$ck4 = cookies_set();
check('without Stay signed in the Web cookie is a browser-session cookie', isset($ck4[$name]) && !isset($ck4[$name]['opts']['expires']));

begin('Sessions: 2FA login also creates the session');
$tfa = $adminRow; $tfa['two_factor_enabled'] = 1;
seed(['users' => [$tfa], 'auth_sessions' => [], 'password_resets' => []]);
$r = call('login.php', ['username_or_email' => 'boss', 'password' => 'Secret#1', 'session_v' => 1, 'client' => 'android', 'stay_signed_in' => true], null, $sec);
check('2FA step: no token or session before the code is verified', ($r['json']['message'] ?? '') === '2FA_REQUIRED' && !isset($r['json']['session']) && count(db()['auth_sessions']) === 0, $r['raw'] ?? '');
seed(['password_resets' => [['email' => 'boss@example.com', 'token' => '123456', 'expiry' => '2099-01-01 00:00:00']]]);
$r = call('verify_otp.php', ['email' => 'boss@example.com', 'otp' => '123456', 'purpose' => 'login', 'session_v' => 1, 'client' => 'android', 'stay_signed_in' => true], null, $sec);
check('verified 2FA: session with refresh credential', !empty($r['json']['session']['refresh_token']) && ($r['json']['auth_token'] ?? '') === ($r['json']['session']['access_token'] ?? '-'), $r['raw'] ?? '');

// ---------------------------------------------------------------- complaint center / lifecycle
function fb_log(): array
{
    global $state;
    return is_file($state . '.curl_log') ? (json_decode(file_get_contents($state . '.curl_log'), true) ?: []) : [];
}

/** PUT requests whose URL ends with notifications/<key>.json */
function fb_puts(string $key): array
{
    return array_values(array_filter(fb_log(), function ($e) use ($key) {
        return $e['method'] === 'PUT' && substr($e['url'], -strlen("/notifications/$key.json")) === "/notifications/$key.json";
    }));
}

function fb_all_puts(): array
{
    return array_values(array_filter(fb_log(), function ($e) { return $e['method'] === 'PUT'; }));
}

function center_world(bool $lifecycle = false): void
{
    reset_state();
    $cats = ['Uncollected Garbage', 'Spilled Waste', 'Schedule Issue'];
    $resolvedAt = [5 => '2026-10-01 10:00:00', 15 => '2026-10-03 09:00:00', 20 => '2026-10-02 09:00:00', 25 => '2026-10-05 09:00:00'];
    $rows = [];
    for ($i = 1; $i <= 25; $i++) {
        $res = $i % 2 === 1 ? 5 : 6;
        $status = $i % 5 === 0 ? 'resolved' : ($i % 5 === 1 ? 'in_progress' : 'pending');
        if ($i === 10) $status = 'Completed';     // older spelling, still Resolved
        if ($i === 6) $status = 'In Progress';    // older spelling, still In Progress
        $row = [
            'complaint_id' => $i, 'resident_id' => $res, 'category' => $cats[$i % 3], 'description' => "complaint $i",
            'status' => $status, 'admin_response' => $status === 'resolved' ? 'done' : '',
            'purok' => $i === 2 ? '' : ($res === 5 ? 'Purok 2' : 'Purok 3'), 'location' => '',
            'created_at' => sprintf('2026-09-%02d 08:00:00', $i), 'is_archived' => 0,
        ];
        if ($lifecycle) {
            $row += ['updated_at' => null, 'in_progress_at' => null, 'resolved_at' => $resolvedAt[$i] ?? null,
                     'resolved_by' => null, 'resolved_by_name' => null];
        }
        $rows[] = $row;
    }
    seed([
        'users' => [['user_id' => 90, 'username' => 'boss', 'name' => 'Boss', 'email' => 'boss@example.com', 'role' => 'admin', 'is_archived' => 0]],
        'residents' => [
            ['resident_id' => 5, 'username' => 'res5', 'name' => 'Res Five', 'email' => 'r5@example.com', 'purok' => 'Purok 2', 'is_archived' => 0],
            ['resident_id' => 6, 'username' => 'res6', 'name' => 'Res Six', 'email' => 'r6@example.com', 'purok' => 'Purok 3', 'is_archived' => 0],
        ],
        'complaints' => $rows,
        'complaint_status_history' => [],
    ]);
}

function center(array $q, array $env = []): array
{
    global $enf, $tAdmin;
    return call('complaint_center.php', null, $q, $env + $enf + ['GT_TEST_TOKEN' => $tAdmin]);
}

function ids(array $r): array
{
    return array_map(function ($c) { return (int)$c['id']; }, $r['json']['data'] ?? []);
}

function complaint_row(int $id): array
{
    foreach (db()['complaints'] as $c) if ((int)$c['complaint_id'] === $id) return $c;
    return [];
}

function upd(array $post, array $env = []): array
{
    global $enf, $tAdmin;
    return call('update_complaint.php', null, $post, $env + $enf + ['GT_TEST_TOKEN' => $tAdmin]);
}

begin('Complaint lifecycle: Pending -> In Progress -> Resolved, one notification each, to the complainant only');
center_world();
$r = upd(['complaint_id' => '7', 'status' => 'in_progress']);
check('admin marks a pending complaint In Progress', ($r['json']['success'] ?? false) === true && ($r['json']['changed'] ?? false) === true
    && complaint_row(7)['status'] === 'in_progress', $r['raw'] ?? '');
check('the In Progress notification was delivered', ($r['json']['notification'] ?? '') === 'sent');
$p = fb_puts('complaint_in_progress_7');
$n = $p ? json_decode($p[0]['body'], true) : [];
check('exactly one In Progress notification record', count($p) === 1);
check('it targets only the complaining resident (id 5, role resident)', ($n['resident_id'] ?? '') === '5' && ($n['targetRole'] ?? '') === 'resident');
check('it carries the real complaint id and the required wording',
    ($n['complaint_id'] ?? 0) === 7 && ($n['type'] ?? '') === 'COMPLAINT_IN_PROGRESS' && ($n['title'] ?? '') === 'Complaint In Progress'
    && strpos($n['message'] ?? '', 'Your complaint #007 is now being reviewed by the barangay administrator.') === 0
    && strpos($n['message'] ?? '', 'Complaint History') !== false, json_encode($n));
check('no notification goes to any other resident or a broadcast node',
    count(fb_all_puts()) === 1 && count(array_filter(fb_log(), function ($e) { return $e['method'] === 'POST'; })) === 0);

$r = upd(['complaint_id' => '7', 'status' => 'in_progress']);
check('repeating In Progress (double click / retry) changes nothing', ($r['json']['success'] ?? false) === true && ($r['json']['changed'] ?? true) === false);
check('...and does not create a second notification', count(fb_puts('complaint_in_progress_7')) === 1 && ($r['json']['notification'] ?? '') === 'already');

$r = upd(['complaint_id' => '7', 'status' => 'resolved', 'admin_response' => 'ok']);
check('resolving without a meaningful note is refused', ($r['json']['code'] ?? '') === 'NOTE_REQUIRED' && complaint_row(7)['status'] === 'in_progress');
check('...and sends no Resolved notification', count(fb_puts('complaint_resolved_7')) === 0);
$r = upd(['complaint_id' => '7', 'status' => 'resolved', 'admin_response' => '          ']);
check('a blank note is refused too', ($r['json']['code'] ?? '') === 'NOTE_REQUIRED');

$r = upd(['complaint_id' => '7', 'status' => 'resolved', 'admin_response' => 'Garbage collected by truck GT-007 on Monday.']);
check('admin resolves with a resolution note', ($r['json']['success'] ?? false) === true && ($r['json']['changed'] ?? false) === true
    && complaint_row(7)['status'] === 'resolved' && complaint_row(7)['admin_response'] === 'Garbage collected by truck GT-007 on Monday.', $r['raw'] ?? '');
check('previous status is still reported for older Admin apps', ($r['json']['previous_status'] ?? '') === 'in_progress');
$p = fb_puts('complaint_resolved_7');
$n = $p ? json_decode($p[0]['body'], true) : [];
check('one Resolved notification with the required wording',
    count($p) === 1 && ($n['type'] ?? '') === 'COMPLAINT_RESOLVED' && ($n['title'] ?? '') === 'Complaint Resolved'
    && ($n['message'] ?? '') === 'Your complaint #007 has been marked as resolved. Tap to view the resolution details.' && ($n['resident_id'] ?? '') === '5');
check('the Resolved notification uses the key older Admin apps check (no duplicate with them)', isset($p[0]) && strpos($p[0]['url'], '/notifications/complaint_resolved_7.json') !== false);

$r = upd(['complaint_id' => '7', 'status' => 'resolved', 'admin_response' => 'Second admin also resolving it']);
check('resolving twice: success, nothing changed, the first note is kept', ($r['json']['changed'] ?? true) === false
    && complaint_row(7)['admin_response'] === 'Garbage collected by truck GT-007 on Monday.');
check('...and still exactly one Resolved notification', count(fb_puts('complaint_resolved_7')) === 1 && ($r['json']['previous_status'] ?? '') === 'resolved');

$r = upd(['complaint_id' => '7', 'status' => 'in_progress']);
check('a resolved complaint cannot be moved back to In Progress (no reopening)', ($r['json']['code'] ?? '') === 'ALREADY_RESOLVED' && complaint_row(7)['status'] === 'resolved');
$r = upd(['complaint_id' => '8', 'status' => 'pending']);
check('Pending is never a target status', ($r['json']['success'] ?? true) === false && complaint_row(8)['status'] === 'pending');
$r = upd(['complaint_id' => '8', 'status' => 'archived']);
check('unknown statuses are refused', ($r['json']['success'] ?? true) === false && complaint_row(8)['status'] === 'pending');
$r = upd(['complaint_id' => '8 OR 1=1', 'status' => 'resolved', 'admin_response' => 'Injected request here']);
check('a non-numeric complaint id is refused', ($r['json']['success'] ?? true) === false && complaint_row(8)['status'] === 'pending');

$r = upd(['complaint_id' => '8', 'status' => 'resolved', 'admin_response' => 'Resolved directly from pending']);
check('a Pending complaint may be resolved directly (with a note)', ($r['json']['changed'] ?? false) === true && complaint_row(8)['status'] === 'resolved'
    && count(fb_puts('complaint_resolved_8')) === 1 && count(fb_puts('complaint_in_progress_8')) === 0);
$r = upd(['complaint_id' => '6', 'status' => 'in_progress']);
check('an older "In Progress" spelling counts as already in progress', ($r['json']['changed'] ?? true) === false && complaint_row(6)['status'] === 'In Progress');

begin('Complaint lifecycle: only an Admin can change a status');
center_world();
$r = upd(['complaint_id' => '7', 'status' => 'in_progress'], ['GT_TEST_TOKEN' => $tRes5]);
check('the complaining resident cannot change the status', ($r['json']['success'] ?? true) === false && complaint_row(7)['status'] === 'pending');
$r = upd(['complaint_id' => '7', 'status' => 'resolved', 'admin_response' => 'Resident trying to resolve'], ['GT_TEST_TOKEN' => $tRes6]);
check('another resident cannot change it', ($r['json']['success'] ?? true) === false && complaint_row(7)['status'] === 'pending');
$r = upd(['complaint_id' => '7', 'status' => 'resolved', 'admin_response' => 'Driver trying to resolve'], ['GT_TEST_TOKEN' => $tDrv]);
check('a driver cannot change it', ($r['json']['success'] ?? true) === false && complaint_row(7)['status'] === 'pending');
$r = upd(['complaint_id' => '7', 'status' => 'in_progress'], ['GT_TEST_TOKEN' => '']);
check('enforced mode: no token, no change', ($r['json']['success'] ?? true) === false && complaint_row(7)['status'] === 'pending');
check('refused requests send no notification', count(fb_all_puts()) === 0);

begin('Complaint lifecycle: concurrent Admin actions and notification failures');
center_world();
$r = upd(['complaint_id' => '9', 'status' => 'resolved', 'admin_response' => 'Late admin resolution text'], ['GT_FAKE_RACE_STATUS' => 'resolved']);
check('two admins resolving at once: the late request reports success without a second transition',
    ($r['json']['success'] ?? false) === true && ($r['json']['changed'] ?? true) === false, $r['raw'] ?? '');
check('...and does not overwrite the winner\'s resolution note', complaint_row(9)['admin_response'] === '');
center_world();
$r = upd(['complaint_id' => '9', 'status' => 'in_progress'], ['GT_FAKE_RACE_STATUS' => 'resolved']);
check('In Progress after another admin resolved it is a reported conflict', ($r['json']['code'] ?? '') === 'CONFLICT' && complaint_row(9)['status'] === 'resolved');
check('the conflicting request sends no notification', count(fb_all_puts()) === 0);

center_world();
$r = upd(['complaint_id' => '12', 'status' => 'resolved', 'admin_response' => 'Collected and area cleaned'], ['GT_FAKE_FIREBASE_FAIL' => '1']);
check('Firebase down: the resolution is still saved', ($r['json']['success'] ?? false) === true && complaint_row(12)['status'] === 'resolved', $r['raw'] ?? '');
check('...the failed delivery is reported, not claimed', ($r['json']['notification'] ?? '') === 'failed');
check('...and logged on the server', strpos(errlog(), 'complaint_resolved_12') !== false);
$r = upd(['complaint_id' => '12', 'status' => 'resolved', 'admin_response' => 'Collected and area cleaned']);
check('retrying delivers the notification once, without a second transition',
    ($r['json']['changed'] ?? true) === false && ($r['json']['notification'] ?? '') === 'sent'
    && count(array_filter(fb_puts('complaint_resolved_12'), function ($e) { return true; })) === 2);
$r = upd(['complaint_id' => '12', 'status' => 'resolved', 'admin_response' => 'Collected and area cleaned']);
check('after a successful delivery a retry finds it and writes nothing', ($r['json']['notification'] ?? '') === 'already' && count(fb_puts('complaint_resolved_12')) === 2);

upd(['complaint_id' => '13', 'status' => 'resolved', 'admin_response' => 'Collected and area cleaned'], ['GT_FAKE_FIREBASE_FAIL' => '1']);
$r = upd(['complaint_id' => '13', 'status' => 'resolved']);
check('retrying the notification of a resolved complaint needs no note and keeps the saved one',
    ($r['json']['success'] ?? false) === true && ($r['json']['notification'] ?? '') === 'sent'
    && complaint_row(13)['admin_response'] === 'Collected and area cleaned', $r['raw'] ?? '');

begin('Complaint lifecycle: ENUM status column keeps its own spelling');
center_world();
$r = upd(['complaint_id' => '7', 'status' => 'in_progress'], ['GT_FAKE_STATUS_TYPE' => "enum('Pending','In Progress','Resolved')"]);
check('In Progress is stored as the ENUM member', complaint_row(7)['status'] === 'In Progress', $r['raw'] ?? '');

begin('Complaint lifecycle with the (not yet applied) migration: timestamps, resolver and history');
center_world(true);
$hist = ['GT_FAKE_COMPLAINT_HISTORY' => '1'];
upd(['complaint_id' => '7', 'status' => 'in_progress', 'admin_response' => 'Checking with the driver'], $hist);
$r = upd(['complaint_id' => '7', 'status' => 'resolved', 'admin_response' => 'Garbage collected on the next trip.'], $hist);
$c = complaint_row(7);
check('in_progress_at, resolved_at and the resolving admin are stored',
    !empty($c['in_progress_at']) && !empty($c['resolved_at']) && (int)$c['resolved_by'] === 90 && $c['resolved_by_name'] === 'Boss', json_encode($c));
$h = db()['complaint_status_history'];
check('each transition is recorded once in the status history', count($h) === 2
    && $h[0]['from_status'] === 'pending' && $h[0]['to_status'] === 'in_progress'
    && $h[1]['from_status'] === 'in_progress' && $h[1]['to_status'] === 'resolved' && $h[1]['note'] === 'Garbage collected on the next trip.'
    && $h[1]['changed_by_name'] === 'Boss', json_encode($h));
upd(['complaint_id' => '7', 'status' => 'resolved', 'admin_response' => 'Garbage collected on the next trip.'], $hist);
check('a repeated request adds no history entry', count(db()['complaint_status_history']) === 2);
$r = center(['action' => 'detail', 'complaint_id' => '7'], $hist);
$ev = $r['json']['history'] ?? [];
check('details return the complaint with its resolution data',
    ($r['json']['data']['status'] ?? '') === 'resolved' && ($r['json']['data']['admin_response'] ?? '') === 'Garbage collected on the next trip.'
    && ($r['json']['data']['resolved_by_name'] ?? '') === 'Boss' && !empty($r['json']['data']['resolved_at']), $r['raw'] ?? '');
check('details return the full history: submitted, in progress, resolved',
    count($ev) === 3 && $ev[0]['to_status'] === 'pending' && $ev[1]['to_status'] === 'in_progress' && $ev[2]['to_status'] === 'resolved');

begin('Complaint Center: Active and Resolved Archive come from the database, paginated');
center_world(true);
$r = center(['scope' => 'active', 'per_page' => 10]);
check('Active page 1: 10 newest pending/in-progress complaints', ids($r) === [24, 23, 22, 21, 19, 18, 17, 16, 14, 13], $r['raw'] ?? '');
check('Active total counts every match, not just the page', ($r['json']['total'] ?? 0) === 20 && ($r['json']['has_more'] ?? false) === true);
check('counters are real database totals per state', ($r['json']['counts'] ?? []) === ['pending' => 15, 'in_progress' => 5, 'resolved' => 5], json_encode($r['json']['counts'] ?? null));
$r2 = center(['scope' => 'active', 'per_page' => 10, 'page' => 2]);
check('Active page 2 continues without gaps or repeats', ids($r2) === [12, 11, 9, 8, 7, 6, 4, 3, 2, 1] && ($r2['json']['has_more'] ?? true) === false);
$r3 = center(['scope' => 'active', 'per_page' => 10, 'page' => 3]);
check('a page past the end is empty but keeps the total', ids($r3) === [] && ($r3['json']['total'] ?? 0) === 20);
$all = array_merge(ids($r), ids($r2));
check('no resolved complaint appears in Active', !array_intersect($all, [5, 10, 15, 20, 25]));
$r = center(['scope' => 'resolved']);
check('Resolved Archive: resolved only (older "Completed" included), newest resolution first', ids($r) === [25, 15, 20, 5, 10], $r['raw'] ?? '');
$r = center(['scope' => 'active', 'per_page' => 999]);
check('page size is capped at 50', ($r['json']['per_page'] ?? 0) === 50);
$r = center(['scope' => 'active', 'per_page' => 1]);
check('page size has a floor of 5', ($r['json']['per_page'] ?? 0) === 5 && count(ids($r)) === 5);

begin('Complaint Center: search and filters run on the server');
center_world(true);
$r = center(['scope' => 'active', 'q' => '#006']);
check('search by complaint id (#006)', ids($r) === [6]);
$r = center(['scope' => 'active', 'q' => '13']);
check('search by plain id (13)', ids($r) === [13]);
$r = center(['scope' => 'active', 'q' => 'six', 'per_page' => 50]);
check('search by complainant name', ids($r) === [24, 22, 18, 16, 14, 12, 8, 6, 4, 2], json_encode(ids($r)));
$r = center(['scope' => 'resolved', 'q' => 'five']);
check('search works in the Resolved Archive (older records too)', ids($r) === [25, 15, 5]);
$r = center(['scope' => 'active', 'status' => 'pending', 'per_page' => 50]);
check('status filter: Pending only', ($r['json']['total'] ?? 0) === 15 && !in_array(1, ids($r), true) && !in_array(6, ids($r), true));
$r = center(['scope' => 'active', 'status' => 'in_progress']);
check('status filter: In Progress only (older spelling included)', ids($r) === [21, 16, 11, 6, 1]);
$r = center(['scope' => 'resolved', 'status' => 'pending']);
check('a status filter cannot pull pending complaints into the Archive', ids($r) === [25, 15, 20, 5, 10]);
$r = center(['scope' => 'active', 'category' => 'Spilled Waste', 'per_page' => 50]);
$expect = [];
for ($i = 25; $i >= 1; $i--) if ($i % 3 === 1 && $i % 5 !== 0) $expect[] = $i;
check('category filter', ids($r) === $expect, json_encode(ids($r)));
$r = center(['scope' => 'active', 'location' => 'Purok 3', 'per_page' => 50]);
check('location filter (a complaint without its own purok uses the resident\'s)', ids($r) === [24, 22, 18, 16, 14, 12, 8, 6, 4, 2], json_encode(ids($r)));
$r = center(['scope' => 'active', 'location' => 'dos riles|purok 3', 'per_page' => 50]);
check('location filter accepts the area\'s alias terms (any match)', ids($r) === [24, 22, 18, 16, 14, 12, 8, 6, 4, 2], json_encode(ids($r)));
$r = center(['scope' => 'active', 'location' => 'nowhere|elsewhere']);
check('location aliases that match nothing return nothing', ($r['json']['success'] ?? false) === true && ids($r) === []);
$r = center(['scope' => 'active', 'date_from' => '2026-09-20', 'date_to' => '2026-09-22']);
check('submission date range (inclusive)', ids($r) === [22, 21]);
$r = center(['scope' => 'resolved', 'date_from' => '2026-10-02', 'date_to' => '2026-10-03']);
check('Archive filters by resolution date', ids($r) === [15, 20]);
$r = center(['scope' => 'resolved', 'date_from' => '2026-09-10', 'date_to' => '2026-09-10']);
check('complaints resolved before the migration fall back to their submission date', ids($r) === [10]);
$r = center(['scope' => 'active', 'date_from' => '2026-02-30']);
check('an invalid date is ignored, not an error', ($r['json']['success'] ?? false) === true && ($r['json']['total'] ?? 0) === 20);
$r = center(['scope' => 'active', 'category' => "x' OR '1'='1"]);
check('filter values are bound parameters (no injection)', ($r['json']['success'] ?? false) === true && ids($r) === []);
$r = center(['scope' => 'active', 'q' => '100%']);
check('LIKE wildcards in a search are literal', ($r['json']['success'] ?? false) === true && ids($r) === []);
$r = center(['scope' => 'active', 'category' => 'Spilled Waste', 'location' => 'Purok 2', 'q' => 'five']);
$expect = array_values(array_filter($expect, function ($i) { return $i % 2 === 1; }));
check('filters combine', ids($r) === $expect, json_encode(ids($r)));

begin('Complaint Center: resolving moves the complaint from Active to the Archive');
center_world();
$before = center(['scope' => 'active', 'per_page' => 50]);
upd(['complaint_id' => '24', 'status' => 'resolved', 'admin_response' => 'Resolved after inspection today']);
$after = center(['scope' => 'active', 'per_page' => 50]);
$arch = center(['scope' => 'resolved']);
check('it leaves Active', in_array(24, ids($before), true) && !in_array(24, ids($after), true) && ($after['json']['total'] ?? 0) === 19);
check('it appears in the Resolved Archive (record kept, not copied)', in_array(24, ids($arch), true) && count(db()['complaints']) === 25);
check('counters follow the persisted status', ($after['json']['counts'] ?? []) === ['pending' => 14, 'in_progress' => 5, 'resolved' => 6]);

begin('Complaint Center: authorization');
center_world();
$r = call('complaint_center.php', null, ['scope' => 'active'], $enf + ['GT_TEST_TOKEN' => $tRes5]);
check('a resident cannot list all complaints', ($r['json']['success'] ?? true) === false && !isset($r['json']['data']));
$r = call('complaint_center.php', null, ['scope' => 'active'], $enf + ['GT_TEST_TOKEN' => $tDrv]);
check('a driver cannot list resident complaints', ($r['json']['success'] ?? true) === false);
$r = call('complaint_center.php', null, ['scope' => 'active'], $enf);
check('enforced mode: no token refused', ($r['json']['success'] ?? true) === false);
$r = call('complaint_center.php', null, ['action' => 'detail', 'complaint_id' => '7'], $enf + ['GT_TEST_TOKEN' => $tRes5]);
check('the complaining resident can open their own complaint', ($r['json']['data']['id'] ?? 0) === 7 && ($r['json']['data']['full_name'] ?? '') === 'Res Five');
$r = call('complaint_center.php', null, ['action' => 'detail', 'complaint_id' => '8'], $enf + ['GT_TEST_TOKEN' => $tRes5]);
check('a resident cannot open another resident\'s complaint', ($r['json']['success'] ?? true) === false && !isset($r['json']['data']));
$r = call('complaint_center.php', null, ['action' => 'detail', 'complaint_id' => '8'], $enf + ['GT_TEST_TOKEN' => $tDrv]);
check('a driver cannot open resident complaints', ($r['json']['success'] ?? true) === false);
$r = call('complaint_center.php', null, ['action' => 'detail', 'complaint_id' => '424242'], $enf + ['GT_TEST_TOKEN' => $tAdmin]);
check('an unknown complaint is "not found"', ($r['json']['success'] ?? true) === false);

begin('Complaint Center: legacy token-less mode and older schema still work');
center_world();
$r = call('complaint_center.php', null, ['scope' => 'active', 'per_page' => 5]);
check('legacy mode (no server secret): Admin list works as get_complaints does', ($r['json']['success'] ?? false) === true && count(ids($r)) === 5, $r['raw'] ?? '');
$r = call('complaint_center.php', null, ['scope' => 'active', 'location' => 'Purok 3', 'per_page' => 50], ['GT_FAKE_COMPLAINT_MISSING' => 'purok,location']);
check('without purok/location columns the location filter uses the resident purok', ($r['json']['success'] ?? false) === true && count(ids($r)) === 10, $r['raw'] ?? '');
$r = call('get_complaints.php', null, null, $enf + ['GT_TEST_TOKEN' => $tRes5]);
check('get_complaints.php (resident history) still returns only the resident\'s complaints',
    ($r['json']['success'] ?? false) === true && count($r['json']['data'] ?? []) === 13
    && !array_filter($r['json']['data'], function ($c) { return (string)$c['resident_id'] !== '5'; }));

// ---------------------------------------------------------------- Load History on older schemas
begin('get_load_history.php works on a server without the load-history columns');
reset_state();
$r = call('get_load_history.php', null, null, ['GT_FAKE_MISSING_COLUMNS' => 'full_time,weight_kg,weight_type,areas_visited']);
check('older schema (no full_time / weight columns): JSON success, no SQL error', ($r['json']['success'] ?? null) === true, substr((string)$r['raw'], 0, 300));
$r = call('get_load_history.php');
check('full schema: JSON success', ($r['json']['success'] ?? null) === true, substr((string)$r['raw'], 0, 300));
$src = (string)file_get_contents($backend . '/get_load_history.php');
check('query uses h.full_time only when the column exists', strpos($src, '$hasFull') !== false && strpos($src, 'DESCRIBE $table') !== false);

begin('get_ai_load_summary.php: older schema, estimated weights, AI off');
reset_state();
$r = call('get_ai_load_summary.php', null, null, ['GT_FAKE_MISSING_COLUMNS' => 'full_time,weight_kg,weight_type,areas_visited']);
check('older schema: JSON success (no SQL error)', ($r['json']['success'] ?? null) === true, substr((string)$r['raw'], 0, 300));
check('AI disabled: summary is not AI-generated and no outbound request', ($r['json']['is_ai_generated'] ?? null) === false && curl_count() === 0);
$r = call('get_ai_load_summary.php');
check('full schema: JSON success', ($r['json']['success'] ?? null) === true, substr((string)$r['raw'], 0, 300));
$src = (string)file_get_contents($backend . '/get_ai_load_summary.php');
check('missing weight counted as ESTIMATED 5,000 kg, not as zero', strpos($src, 'COALESCE(h.weight_kg, 5000)') !== false && strpos($src, 'COUNT(*) * 5000') !== false && strpos($src, 'ESTIMATED') !== false);

// ---------------------------------------------------------------- Mapbox Matrix containment
begin('route_optimization.php replacement (deploy_prep/hostinger) makes no outbound request');
reset_state();
$stubRel = '../deploy_prep/hostinger/backend/route_optimization.php';
$stubSrc = (string)file_get_contents($backend . '/' . $stubRel);
$before = is_file($state . '.curl_log') ? count(file($state . '.curl_log')) : 0;
$r = call($stubRel, ['driver_lat' => 13.95, 'driver_lng' => 121.16, 'stops' => [['name' => 'A', 'lat' => 13.951, 'lng' => 121.161], ['name' => 'B', 'lat' => 13.952, 'lng' => 121.162]]]);
check('old-client request: success false, ROUTE_OPTIMIZATION_DISABLED', ($r['json']['success'] ?? null) === false && ($r['json']['error'] ?? '') === 'ROUTE_OPTIMIZATION_DISABLED', $r['raw'] ?? '');
$r2 = call($stubRel, null, ['anything' => 'x']);
check('any other request gets the same answer', ($r2['json']['error'] ?? '') === 'ROUTE_OPTIMIZATION_DISABLED', $r2['raw'] ?? '');
$after = is_file($state . '.curl_log') ? count(file($state . '.curl_log')) : 0;
check('no curl request was made', $after === $before && curl_count() === 0);
check('source has no outbound call, no token, no Mapbox URL',
    !preg_match('/curl_|file_get_contents|fopen|fsockopen|stream_context|api\.mapbox\.com|pk\.ey|sk\.ey|require|include/i', preg_replace('#/\*.*?\*/#s', '', $stubSrc)));
foreach (glob($backend . '/*.php') as $f) {
    if (stripos((string)file_get_contents($f), 'api.mapbox.com') !== false) { check('no backend file calls Mapbox: ' . basename($f), false); }
}
check('no file in backend/ calls api.mapbox.com', true);

// ---------------------------------------------------------------- summary
echo "\n" . str_repeat('-', 60) . "\n";
echo "PHP backend regression: $pass passed, $fail failed\n";
if ($fail) {
    echo "Failed:\n - " . implode("\n - ", $failures) . "\n";
}
foreach (glob($tmp . '/*') as $f) @unlink($f);
@rmdir($tmp);
exit($fail ? 1 : 0);
