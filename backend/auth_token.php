<?php
/**
 * Optional, backward-compatible request authorization.
 *
 * login.php (and the 2FA step) issue a signed token; sensitive endpoints check it.
 * Nothing changes until the server is configured, so existing APKs and the Web build
 * keep working during a coordinated rollout:
 *
 *   mode            GT_AUTH_SECRET   GT_AUTH_ENFORCE   behaviour
 *   ----------------------------------------------------------------------------
 *   legacy (today)  not set          -                 no tokens issued, no checks
 *   token-optional  set              not true          tokens issued; a VALID token
 *                                                      of the wrong role is refused;
 *                                                      requests without a token are
 *                                                      still accepted (old clients)
 *   enforced        set              true              a valid token with the right
 *                                                      role is required (401/403)
 *
 * Server-only configuration lives in backend/auth_config.php, which is NOT in git:
 *
 *   <?php
 *   define('GT_AUTH_SECRET', '<64+ random characters>');
 *   define('GT_AUTH_ENFORCE', false);   // switch to true only after all clients are updated
 *
 * The token travels in the `X-GT-Token` header (Hostinger/Apache can strip the
 * Authorization header, so a custom header is used).
 */

@include_once 'auth_config.php';

function gt_b64url_encode($raw)
{
    return rtrim(strtr(base64_encode($raw), '+/', '-_'), '=');
}

function gt_b64url_decode($text)
{
    $pad = strlen($text) % 4;
    if ($pad) $text .= str_repeat('=', 4 - $pad);
    return base64_decode(strtr($text, '-_', '+/'), true);
}

function gt_auth_secret()
{
    if (defined('GT_AUTH_SECRET') && is_string(GT_AUTH_SECRET) && strlen(GT_AUTH_SECRET) >= 32) {
        return GT_AUTH_SECRET;
    }
    return null;
}

function gt_auth_enforced()
{
    return gt_auth_secret() !== null && defined('GT_AUTH_ENFORCE') && GT_AUTH_ENFORCE === true;
}

/** Signed token for [role, id], or null while no secret is configured. */
function gt_issue_token($id, $role, $ttlSeconds = 43200, $now = null)
{
    $secret = gt_auth_secret();
    if ($secret === null) return null;
    $now = $now ?? time();
    $payload = gt_b64url_encode(json_encode([
        'sub' => (string)$id,
        'role' => strtolower((string)$role),
        'iat' => $now,
        'exp' => $now + $ttlSeconds,
    ]));
    $sig = gt_b64url_encode(hash_hmac('sha256', $payload, $secret, true));
    return $payload . '.' . $sig;
}

/** Payload array for a valid, unexpired token; otherwise null. */
function gt_verify_token($token, $now = null)
{
    $secret = gt_auth_secret();
    if ($secret === null || !is_string($token) || strpos($token, '.') === false) return null;
    list($payload, $sig) = explode('.', $token, 2);
    $expected = gt_b64url_encode(hash_hmac('sha256', $payload, $secret, true));
    if (!hash_equals($expected, $sig)) return null;
    $json = gt_b64url_decode($payload);
    $data = $json === false ? null : json_decode($json, true);
    if (!is_array($data) || !isset($data['sub'], $data['role'], $data['exp'])) return null;
    if ((int)$data['exp'] < ($now ?? time())) return null;
    return $data;
}

function gt_request_token()
{
    if (!empty($_SERVER['HTTP_X_GT_TOKEN'])) return trim($_SERVER['HTTP_X_GT_TOKEN']);
    $h = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
    if (stripos($h, 'Bearer ') === 0) return trim(substr($h, 7));
    return null;
}

function gt_auth_fail($code, $message)
{
    http_response_code($code);
    echo json_encode(["success" => false, "message" => $message]);
    exit;
}

/**
 * The request must come from one of [$roles].
 * Returns the token payload, or null for an accepted legacy (token-less) request.
 */
function gt_require_role(array $roles)
{
    $roles = array_map('strtolower', $roles);
    $payload = gt_verify_token(gt_request_token());
    if ($payload !== null) {
        if (!in_array($payload['role'], $roles, true)) {
            gt_auth_fail(403, "You are not allowed to perform this action.");
        }
        return $payload;
    }
    if (gt_auth_enforced()) {
        gt_auth_fail(401, "Please log in again.");
    }
    return null;
}

/**
 * STRICT variant for features that never had a token-less client (route assignments):
 * a valid token with one of [$roles] is ALWAYS required, whatever GT_AUTH_ENFORCE says.
 * Fails closed (503) while no secret is configured, so no unauthenticated write path exists.
 * Returns the token payload.
 */
function gt_require_verified_role(array $roles)
{
    if (gt_auth_secret() === null) {
        gt_auth_fail(503, "This feature is not available until server authorization is configured.");
    }
    $payload = gt_verify_token(gt_request_token());
    if ($payload === null) {
        gt_auth_fail(401, "Please log in again.");
    }
    if (!in_array($payload['role'], array_map('strtolower', $roles), true)) {
        gt_auth_fail(403, "You are not allowed to perform this action.");
    }
    return $payload;
}

/** The request must be made by [$role] user [$id] (e.g. a resident filing their own complaint). */
function gt_require_subject($role, $id)
{
    $payload = gt_verify_token(gt_request_token());
    if ($payload !== null) {
        if ($payload['role'] !== strtolower($role) || (string)$payload['sub'] !== (string)$id) {
            gt_auth_fail(403, "You can only act on your own account.");
        }
        return $payload;
    }
    if (gt_auth_enforced()) {
        gt_auth_fail(401, "Please log in again.");
    }
    return null;
}

/* ---------------------------------------------------------------------------------------------
 * Bundle 1 (server-side authorization on every endpoint)
 * ------------------------------------------------------------------------------------------- */

/**
 * Every protected endpoint: a valid token with one of [$roles] is required, always (no token-less
 * legacy access). Returns the token payload ['sub' => id, 'role' => role, ...].
 */
function gt_guard(array $roles)
{
    return gt_require_verified_role($roles);
}

/** Requests that change or delete data must be POST (no destructive links). */
function gt_require_post()
{
    if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        gt_auth_fail(405, "Use POST for this action.");
    }
}

/**
 * The account a self-service request acts on: ALWAYS the caller's own account from the token.
 * A different id or role sent by the client is refused (IDOR protection).
 * Returns [role, id].
 */
function gt_acting_account(array $auth, $claimedId = null, $claimedRole = null)
{
    $role = strtolower((string)$auth['role']);
    $id = (string)$auth['sub'];
    $ci = ($claimedId === null || $claimedId === '') ? null : (string)$claimedId;
    $cr = ($claimedRole === null || $claimedRole === '') ? null : strtolower((string)$claimedRole);
    if (($ci !== null && $ci !== $id) || ($cr !== null && $cr !== $role)) {
        gt_auth_fail(403, "You can only change your own account.");
    }
    return [$role, $id];
}

/** Generic error for clients; the detail goes to the server log only (no schema/SQL leaks). */
function gt_server_error($e, $message = "Something went wrong. Please try again.")
{
    error_log('[GT] ' . basename($_SERVER['SCRIPT_NAME'] ?? '') . ': ' . ($e instanceof Throwable ? $e->getMessage() : (string)$e));
    echo json_encode(["success" => false, "message" => $message]);
}
