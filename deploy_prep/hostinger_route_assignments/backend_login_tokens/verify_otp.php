<?php
header("Content-Type: application/json");
date_default_timezone_set('Asia/Manila');
require_once 'db_config.php';
require_once 'auth_token.php';

$data = json_decode(file_get_contents("php://input"));

if (!$data || empty($data->email) || empty($data->otp)) {
    echo json_encode(["success" => false, "message" => "Email and OTP are required"]);
    exit;
}

$email = $data->email;
$otp = $data->otp;

try {
    $now = date("Y-m-d H:i:s");

    // 1. Check password_resets table (Main storage for 2FA OTPs)
    $stmt = $conn->prepare("SELECT email FROM password_resets WHERE email = ? AND token = ? AND expiry > ?");
    $stmt->execute([$email, $otp, $now]);
    if ($stmt->fetch()) {
        // Clean up the OTP after successful verification
        $conn->prepare("DELETE FROM password_resets WHERE email = ?")->execute([$email]);

        $response = ["success" => true, "message" => "OTP verified successfully"];
        if (($data->purpose ?? '') === 'login') {
            $u = $conn->prepare("SELECT user_id, role, is_archived FROM users WHERE email = ?");
            $u->execute([$email]);
            $row = $u->fetch(PDO::FETCH_ASSOC);
            if ($row && (int)$row['is_archived'] === 0) {
                $token = gt_issue_token($row['user_id'], $row['role']);
                if ($token !== null) $response['auth_token'] = $token;
            }
        }
        echo json_encode($response);
        exit;
    }

    echo json_encode(["success" => false, "message" => "Invalid or expired verification code"]);

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>