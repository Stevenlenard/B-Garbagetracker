<?php
/**
 * Revocable sign-in sessions ("Stay signed in") with rotating refresh credentials.
 *
 *  - Access tokens are the existing signed tokens (auth_token.php), now SHORT-LIVED
 *    (GT_ACCESS_TTL) and carrying the session id (`sid`).
 *  - A refresh credential "<session_id>.<generation>.<mac>" renews them, where
 *    mac = HMAC(GT_AUTH_SECRET, session_id|salt|generation). The credential itself is
 *    never stored (only a random per-session salt and the current generation). Every
 *    refresh ROTATES it (generation + 1). Presenting any OLDER generation with a valid
 *    mac proves it was issued and already replaced: outside a short race window that is
 *    treated as theft and revokes the session. A forged mac revokes nothing.
 *  - A "Stay signed in" (persistent) session has NO calendar expiry and NO idle limit:
 *    it lasts until it is revoked. A non-persistent session ends after GT_IDLE_LIMIT of
 *    inactivity (it is only meant to outlive the 15-minute access token while in use).
 *  - Every refresh re-reads the account: deleted, archived, suspended/disabled, rejected,
 *    role changed or password changed => the session is revoked and the refresh refused.
 *  - Android receives the refresh credential in the response body (kept in the
 *    platform keystore by the app). Web receives it ONLY as a Secure, HttpOnly,
 *    SameSite=Strict cookie; cookie-authenticated calls also require the X-GT-CSRF
 *    header and a same-origin Origin header.
 *
 * Requires the auth_sessions table (deploy_prep/sql/09_...) and GT_AUTH_SECRET. Without
 * them login behaves exactly as before (legacy 12 h token or none).
 */

require_once __DIR__ . '/auth_token.php';

const GT_ACCESS_TTL = 900;          // 15 minutes
const GT_IDLE_LIMIT = 43200;        // 12 h of inactivity, NON-persistent sessions only
const GT_ROTATION_GRACE = 120;      // seconds: the previous credential is re-answered (parallel refresh / lost reply)
const GT_COOKIE_MAX_AGE = 34560000; // 400 days (the longest browsers accept); renewed on every refresh

function gt_session_now()
{
    if (defined('GT_TEST_HARNESS') && getenv('GT_SESSION_TEST_NOW')) return (int)getenv('GT_SESSION_TEST_NOW');
    return time();
}

function gt_session_dt($ts) { return date('Y-m-d H:i:s', $ts); }

/** Sessions need the server secret AND the auth_sessions table. */
function gt_sessions_available($conn)
{
    if (gt_auth_secret() === null) return false;
    try {
        $st = $conn->query("SHOW TABLES LIKE 'auth_sessions'");
        return $st && $st->rowCount() > 0;
    } catch (Exception $e) {
        return false;
    }
}

function gt_session_mac($sid, $salt, $gen)
{
    return gt_b64url_encode(hash_hmac('sha256', 'rt|' . $sid . '|' . $salt . '|' . (int)$gen, (string)gt_auth_secret(), true));
}

function gt_session_credential($sid, $salt, $gen) { return $sid . '.' . (int)$gen . '.' . gt_session_mac($sid, $salt, $gen); }

/** Fingerprint of the current password hash: changes whenever the password changes. */
function gt_session_pw_marker($passwordHash)
{
    return hash_hmac('sha256', 'pw|' . (string)$passwordHash, (string)gt_auth_secret());
}

function gt_session_role($role)
{
    $r = strtolower(trim((string)$role));
    return in_array($r, ['admin', 'driver', 'resident'], true) ? $r : null;
}

function gt_session_cookie_name($role, $id)
{
    return 'gtrs_' . $role . '_' . preg_replace('/[^0-9]/', '', (string)$id);
}

function gt_session_cookie_path()
{
    $dir = str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/backend/x.php'));
    return rtrim($dir, '/') . '/';
}

/** Sets (or, with $value null, deletes) the Web refresh cookie. */
function gt_session_set_cookie($role, $id, $value, $persistent)
{
    $name = gt_session_cookie_name($role, $id);
    $opts = [
        'path' => gt_session_cookie_path(),
        'secure' => true,
        'httponly' => true,
        'samesite' => 'Strict',
    ];
    if ($value === null) {
        $opts['expires'] = 1; // in the past: delete
        $value = '';
    } elseif ($persistent) {
        $opts['expires'] = gt_session_now() + GT_COOKIE_MAX_AGE;
    } // else: browser-session cookie (no expiry)
    if (defined('GT_TEST_HARNESS')) {
        $GLOBALS['__GT_COOKIES'][$name] = ['value' => $value, 'opts' => $opts];
        return;
    }
    setcookie($name, $value, $opts);
}

function gt_session_cookie_value($role, $id)
{
    $name = gt_session_cookie_name($role, $id);
    return isset($_COOKIE[$name]) && is_string($_COOKIE[$name]) ? $_COOKIE[$name] : null;
}

/**
 * Cookie-authenticated requests must carry the custom header (a cross-site form or
 * image cannot set it, and CORS here never allows credentials) and, when the browser
 * sends one, an Origin of this same host.
 */
function gt_session_csrf_ok()
{
    if (($_SERVER['HTTP_X_GT_CSRF'] ?? '') !== '1') return false;
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
    if ($origin === '') return true;
    $host = parse_url($origin, PHP_URL_HOST);
    $self = preg_replace('/:\d+$/', '', (string)($_SERVER['HTTP_HOST'] ?? ''));
    return $host !== null && $self !== '' && strcasecmp($host, $self) === 0;
}

function gt_session_random_id() { return bin2hex(random_bytes(16)); }
/** Splits "<sid>.<generation>.<mac>"; null if malformed. */
function gt_session_parse($credential)
{
    if (!is_string($credential) || !preg_match('/^([0-9a-f]{32})\.(\d{1,9})\.([A-Za-z0-9_-]{43})$/', $credential, $m)) return null;
    return [$m[1], (int)$m[2], $m[3]];
}

function gt_session_access_token($id, $role, $sid)
{
    $secret = gt_auth_secret();
    $now = gt_session_now();
    $payload = gt_b64url_encode(json_encode([
        'sub' => (string)$id,
        'role' => $role,
        'sid' => $sid,
        'iat' => $now,
        'exp' => $now + GT_ACCESS_TTL,
    ]));
    return $payload . '.' . gt_b64url_encode(hash_hmac('sha256', $payload, $secret, true));
}

/**
 * Current account row for [role, id], or ['blocked' => reason]. Reads every column so
 * older schemas (no approval_status / account_status) keep working.
 */
function gt_session_account($conn, $role, $id)
{
    if ($role === 'resident') {
        $st = $conn->prepare("SELECT * FROM residents WHERE resident_id = ?");
    } else {
        $st = $conn->prepare("SELECT * FROM users WHERE user_id = ?");
    }
    $st->execute([$id]);
    $row = $st->fetch(PDO::FETCH_ASSOC);
    if (!$row) return ['blocked' => 'account_deleted'];
    if ($role !== 'resident' && strtolower((string)($row['role'] ?? '')) !== $role) return ['blocked' => 'role_changed'];
    if ((int)($row['is_archived'] ?? 0) === 1) return ['blocked' => 'account_archived'];
    $acct = strtolower(trim((string)($row['account_status'] ?? '')));
    if (in_array($acct, ['archived', 'suspended', 'disabled', 'inactive', 'banned', 'deleted'], true)) return ['blocked' => 'account_' . $acct];
    $appr = strtolower(trim((string)($row['approval_status'] ?? '')));
    if ($appr === 'rejected') return ['blocked' => 'account_rejected'];
    // `pending` is not re-checked here: a session exists only after a login that passed the
    // approval gate (including its legacy-approved exception).
    return ['row' => $row];
}

/** Public profile (what login.php returns) from an account row. */
function gt_session_profile($role, array $row)
{
    $keys = $role === 'resident'
        ? ['username', 'name', 'email', 'phone', 'purok', 'complete_address', 'profile_picture']
        : ['username', 'name', 'email', 'phone', 'license_number', 'preferred_truck', 'role', 'two_factor_enabled', 'profile_picture'];
    $out = ['user_id' => $role === 'resident' ? $row['resident_id'] : $row['user_id'], 'role' => $role];
    foreach ($keys as $k) if (array_key_exists($k, $row)) $out[$k] = $row[$k];
    $out['role'] = $role;
    return $out;
}

function gt_session_revoke($conn, $sid, $reason)
{
    $conn->prepare("UPDATE auth_sessions SET revoked_at = ?, revoke_reason = ? WHERE session_id = ? AND revoked_at IS NULL")
         ->execute([gt_session_dt(gt_session_now()), $reason, $sid]);
}

/** Revokes every active session of an account (e.g. an admin action); returns nothing. */
function gt_session_revoke_all($conn, $role, $id, $reason)
{
    $conn->prepare("UPDATE auth_sessions SET revoked_at = ?, revoke_reason = ? WHERE role = ? AND user_id = ? AND revoked_at IS NULL")
         ->execute([gt_session_dt(gt_session_now()), $reason, $role, (int)$id]);
}

/**
 * Starts a session after a successful password (or 2FA) login and returns what the client
 * needs: ['access_token', 'expires_in', 'persistent', 'refresh_token' (Android only)].
 * Web gets the refresh credential as an HttpOnly cookie instead.
 */
function gt_session_start($conn, $role, $id, $passwordHash, $persistent, $platform)
{
    $sid = gt_session_random_id();
    $salt = bin2hex(random_bytes(16));
    $now = gt_session_dt(gt_session_now());
    $platform = $platform === 'web' ? 'web' : 'android';
    $conn->prepare("INSERT INTO auth_sessions (session_id, user_id, role, salt, generation, pw_marker, persistent, platform, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
         ->execute([$sid, (int)$id, $role, $salt, 1, gt_session_pw_marker($passwordHash), $persistent ? 1 : 0, $platform, $now, $now]);
    $credential = gt_session_credential($sid, $salt, 1);

    $out = [
        'access_token' => gt_session_access_token($id, $role, $sid),
        'expires_in' => GT_ACCESS_TTL,
        'persistent' => (bool)$persistent,
    ];
    if ($platform === 'web') {
        gt_session_set_cookie($role, $id, $credential, $persistent);
    } else {
        $out['refresh_token'] = $credential;
    }
    return $out;
}

/** Whether the login request opted in to sessions (old clients never send this). */
function gt_session_requested($data)
{
    return is_object($data) && isset($data->session_v) && (int)$data->session_v >= 1;
}

/**
 * Validates and rotates a refresh credential.
 * Returns ['ok' => true, ...client fields..., 'user' => profile] or
 *         ['ok' => false, 'code' => HTTP status, 'reason' => machine reason, 'message' => text].
 */
function gt_session_refresh($conn, $role, $id, $credential, $platform)
{
    $fail = function ($code, $reason, $message) { return ['ok' => false, 'code' => $code, 'reason' => $reason, 'message' => $message]; };
    $parsed = gt_session_parse($credential);
    if ($parsed === null) return $fail(401, 'no_session', 'Please sign in again.');
    [$sid, $gen, $mac] = $parsed;

    $st = $conn->prepare("SELECT * FROM auth_sessions WHERE session_id = ?");
    $st->execute([$sid]);
    $s = $st->fetch(PDO::FETCH_ASSOC);
    if (!$s || $s['role'] !== $role || (string)$s['user_id'] !== (string)(int)$id) return $fail(401, 'no_session', 'Please sign in again.');
    // A credential this server never issued (bad mac) is simply refused: knowing a session
    // id must not let anyone revoke that session.
    if (!hash_equals(gt_session_mac($sid, $s['salt'], $gen), $mac)) return $fail(401, 'no_session', 'Please sign in again.');
    if (!empty($s['revoked_at'])) return $fail(401, 'revoked', 'This sign-in was ended. Please sign in again.');

    $now = gt_session_now();
    if ((int)$s['persistent'] !== 1 && $now - strtotime($s['last_used_at']) > GT_IDLE_LIMIT) {
        gt_session_revoke($conn, $sid, 'idle');
        return $fail(401, 'expired', 'Your sign-in has ended. Please sign in again.');
    }

    $current = (int)$s['generation'];
    $reissue = false;
    if ($gen !== $current) {
        if ($gen === $current - 1 && !empty($s['rotated_at']) && $now - strtotime($s['rotated_at']) <= GT_ROTATION_GRACE) {
            // Just rotated: a parallel refresh, or the reply to the previous refresh was lost.
            // Hand out the CURRENT credential again (no further rotation).
            $reissue = true;
        } elseif ($gen < $current) {
            // A credential that was issued and already replaced is being used again: the
            // owner or a thief holds a copy. End the session for both.
            gt_session_revoke($conn, $sid, 'reuse_detected');
            return $fail(401, 'revoked', 'For your security this sign-in was ended. Please sign in again.');
        } else {
            return $fail(401, 'no_session', 'Please sign in again.');
        }
    }

    $acct = gt_session_account($conn, $role, $id);
    if (isset($acct['blocked'])) {
        gt_session_revoke($conn, $sid, $acct['blocked']);
        $msg = $acct['blocked'] === 'account_rejected' ? 'Your registration was not approved. Please contact the administrator.'
            : ($acct['blocked'] === 'role_changed' ? 'Your account role changed. Please sign in again.'
            : 'This account is no longer active. Please contact the administrator.');
        return $fail(403, $acct['blocked'], $msg);
    }
    $row = $acct['row'];
    if (!hash_equals((string)$s['pw_marker'], gt_session_pw_marker($row['password_hash'] ?? ''))) {
        gt_session_revoke($conn, $sid, 'password_changed');
        return $fail(401, 'password_changed', 'Your password was changed. Please sign in again.');
    }

    if ($reissue) {
        $next = $current;
        $conn->prepare("UPDATE auth_sessions SET last_used_at = ? WHERE session_id = ?")->execute([gt_session_dt($now), $sid]);
    } else {
        $next = $current + 1;
        $upd = $conn->prepare("UPDATE auth_sessions SET generation = ?, rotated_at = ?, last_used_at = ? WHERE session_id = ? AND generation = ?");
        $upd->execute([$next, gt_session_dt($now), gt_session_dt($now), $sid, $current]);
        if ($upd->rowCount() < 1) {
            // Another request rotated it between our read and our write.
            return $fail(409, 'retry', 'Sign-in was refreshed by another request. Retry.');
        }
    }
    $newCredential = gt_session_credential($sid, $s['salt'], $next);

    $persistent = (int)$s['persistent'] === 1;
    $out = [
        'ok' => true,
        'access_token' => gt_session_access_token($id, $role, $sid),
        'expires_in' => GT_ACCESS_TTL,
        'persistent' => $persistent,
        'user' => gt_session_profile($role, $row),
    ];
    if ($platform === 'web') {
        gt_session_set_cookie($role, $id, $newCredential, $persistent); // also renews the cookie lifetime
    } else {
        $out['refresh_token'] = $newCredential;
    }
    return $out;
}

/** Revokes the session behind a credential (any generation it issued). Idempotent. */
function gt_session_logout($conn, $role, $id, $credential)
{
    $parsed = gt_session_parse($credential);
    if ($parsed === null) return false;
    [$sid, $gen, $mac] = $parsed;
    $st = $conn->prepare("SELECT * FROM auth_sessions WHERE session_id = ?");
    $st->execute([$sid]);
    $s = $st->fetch(PDO::FETCH_ASSOC);
    if (!$s || $s['role'] !== $role || (string)$s['user_id'] !== (string)(int)$id) return false;
    if ($gen > (int)$s['generation'] || !hash_equals(gt_session_mac($sid, $s['salt'], $gen), $mac)) return false;
    gt_session_revoke($conn, $sid, 'logout');
    return true;
}

/** Reads role/user_id/platform/credential from a refresh or logout request. */
function gt_session_request_input()
{
    $data = json_decode(file_get_contents('php://input'));
    $role = gt_session_role($data->role ?? '');
    $id = isset($data->user_id) && preg_match('/^\d+$/', (string)$data->user_id) ? (int)$data->user_id : null;
    $platform = (($data->client ?? '') === 'web') ? 'web' : 'android';
    $credential = null;
    if ($role !== null && $id !== null) {
        $credential = $platform === 'web' ? gt_session_cookie_value($role, $id) : (string)($data->refresh_token ?? '');
    }
    return [$role, $id, $platform, $credential];
}
