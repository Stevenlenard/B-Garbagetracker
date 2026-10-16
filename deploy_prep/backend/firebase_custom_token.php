<?php
/**
 * PROTOTYPE - NOT DEPLOYED. Part of Stage 3 (Firebase Authentication) in ROLLOUT_PLAN.md.
 *
 * Mints a Firebase custom token for a user whose password login.php has ALREADY verified.
 * The app then calls FirebaseAuth.signInWithCustomToken(token); security rules read
 * `auth.token.role` and `auth.token.driver_id`.
 *
 * Secrets:
 *  - The service-account JSON is NEVER stored in this repository or under public_html.
 *    Put it outside the web root (e.g. /home/<user>/secrets/firebase-sa.json, chmod 600)
 *    and point FIREBASE_SERVICE_ACCOUNT_FILE at it (hPanel environment variable or a
 *    non-public PHP include). Rotate the key if it is ever exposed.
 *  - Use a dedicated service account with only the "Firebase Authentication Admin"
 *    / "Service Account Token Creator" capability, not the project owner key.
 *
 * Usage (inside login.php, after password_verify succeeded):
 *   require_once __DIR__ . '/firebase_custom_token.php';
 *   $token = firebase_custom_token('driver-' . $user['user_id'], [
 *       'role'      => $user['role'],            // admin | driver | resident
 *       'driver_id' => (string)$user['user_id'], // drivers only
 *   ]);
 *   $response['firebase_token'] = $token;        // additive field: older apps ignore it
 */

function firebase_b64url(string $data): string
{
    return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
}

/**
 * @param string $uid     Stable user identifier (<= 128 chars).
 * @param array  $claims  Developer claims (small; the whole token must stay < 1000 bytes).
 * @return string signed RS256 JWT valid for 55 minutes
 * @throws RuntimeException when the service account is not configured
 */
function firebase_custom_token(string $uid, array $claims = []): string
{
    $file = getenv('FIREBASE_SERVICE_ACCOUNT_FILE');
    if (!$file || !is_readable($file)) {
        throw new RuntimeException('Firebase service account is not configured.');
    }
    $sa = json_decode((string)file_get_contents($file), true);
    if (!is_array($sa) || empty($sa['client_email']) || empty($sa['private_key'])) {
        throw new RuntimeException('Invalid Firebase service account file.');
    }
    if ($uid === '' || strlen($uid) > 128) {
        throw new InvalidArgumentException('Invalid uid.');
    }
    // Reserved claim names must not be used as developer claims.
    foreach (['iss', 'sub', 'aud', 'iat', 'exp', 'uid', 'auth_time'] as $reserved) {
        if (array_key_exists($reserved, $claims)) {
            throw new InvalidArgumentException("Reserved claim: $reserved");
        }
    }

    $now = time();
    $header = ['alg' => 'RS256', 'typ' => 'JWT'];
    $payload = [
        'iss'    => $sa['client_email'],
        'sub'    => $sa['client_email'],
        'aud'    => 'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit',
        'iat'    => $now,
        'exp'    => $now + 3300,
        'uid'    => $uid,
        'claims' => $claims,
    ];

    $signingInput = firebase_b64url(json_encode($header)) . '.' . firebase_b64url(json_encode($payload));
    $signature = '';
    if (!openssl_sign($signingInput, $signature, $sa['private_key'], OPENSSL_ALGO_SHA256)) {
        throw new RuntimeException('Could not sign the Firebase custom token.');
    }
    return $signingInput . '.' . firebase_b64url($signature);
}
