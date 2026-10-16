<?php
header("Content-Type: application/json");
date_default_timezone_set('Asia/Manila');
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'auth_session_lib.php';
require_once 'rate_limit_lib.php';

$data = json_decode(file_get_contents("php://input"));

if (!$data || empty($data->email) || empty($data->otp)) {
    echo json_encode(["success" => false, "message" => "Email and OTP are required"]);
    exit;
}

$email = strtolower(trim((string)$data->email));
$otp = trim((string)$data->otp);
// 5 wrong codes -> the code is cancelled and a new one must be requested.
if (gt_rl_blocked('otp_verify', $email, 5, 900) > 0) {
    $conn->prepare("DELETE FROM password_resets WHERE email = ?")->execute([$email]);
    echo json_encode(["success" => false, "message" => "Too many wrong codes. Please request a new code."]);
    exit;
}

try {
    $now = date("Y-m-d H:i:s");

    // 1. Check password_resets table (Main storage for 2FA OTPs)
    $stmt = $conn->prepare("SELECT email FROM password_resets WHERE email = ? AND token = ? AND expiry > ?");
    $stmt->execute([$email, $otp, $now]);
    if ($stmt->fetch()) {
        gt_rl_clear('otp_verify', $email);
        // Sign-in (2FA) codes are used up now. A password-reset code stays valid for the final
        // reset step (reset_password_final.php checks it again and deletes it).
        if (($data->purpose ?? '') === 'login') {
            $conn->prepare("DELETE FROM password_resets WHERE email = ?")->execute([$email]);
        }

        $response = ["success" => true, "message" => "OTP verified successfully"];
        if (($data->purpose ?? '') === 'login') {
            $u = $conn->prepare("SELECT user_id, role, is_archived, password_hash FROM users WHERE email = ?");
            $u->execute([$email]);
            $row = $u->fetch(PDO::FETCH_ASSOC);
            if ($row && (int)$row['is_archived'] === 0) {
                $session = null;
                if (gt_session_requested($data) && gt_sessions_available($conn)) {
                    try {
                        $session = gt_session_start($conn, strtolower($row['role']), $row['user_id'], $row['password_hash'],
                            !empty($data->stay_signed_in), (($data->client ?? '') === 'web') ? 'web' : 'android');
                    } catch (Exception $e) {
                        $session = null;
                    }
                }
                if ($session !== null) {
                    $response['auth_token'] = $session['access_token'];
                    $response['session'] = $session;
                } else {
                    $token = gt_issue_token($row['user_id'], $row['role']);
                    if ($token !== null) $response['auth_token'] = $token;
                }
            }
        }
        echo json_encode($response);
        exit;
    }

    gt_rl_hit('otp_verify', $email, 900);
    echo json_encode(["success" => false, "message" => "Invalid or expired verification code"]);

} catch (PDOException $e) {
    gt_server_error($e);
}
?>