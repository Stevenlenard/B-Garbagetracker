<?php
header("Content-Type: application/json");
date_default_timezone_set('Asia/Manila');
require_once 'db_config.php';
require_once 'email_config.php';
require_once 'auth_token.php';

use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'PHPMailer/Exception.php';
require 'PHPMailer/PHPMailer.php';
require 'PHPMailer/SMTP.php';

/**
 * ONE Admin in-app notification per registration (the apps no longer write their own copy).
 * Returns true when Firebase accepted the write. A failure is logged, never fatal.
 */
function trigger_firebase_notification($type, $title, $message, $relatedId = null) {
    $url = "https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app/notifications.json";
    $data = [
        "type" => $type,
        "title" => $title,
        "message" => $message,
        "timestamp" => round(microtime(true) * 1000),
        "isRead" => false
    ];
    if ($relatedId !== null && $relatedId !== '') {
        $data["relatedId"] = (string)$relatedId;
    }

    $ch = curl_init($url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
    curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
    curl_setopt($ch, CURLOPT_TIMEOUT, 5); // 5 seconds timeout
    $out = curl_exec($ch);
    curl_close($ch);
    $ok = ($out !== false && $out !== '' && strpos((string)$out, '"error"') === false);
    if (!$ok) {
        error_log("register.php: admin in-app notification was not accepted by Firebase (type=$type)");
    }
    return $ok;
}

/**
 * Tries to email the Admin(s) about a pending driver application.
 *
 * Returns a status string for the server log only (it is never sent to the client):
 *   not_configured | no_recipient | smtp_accepted | failed
 * "smtp_accepted" means the SMTP server accepted the message for delivery. It does NOT prove
 * the message reached an inbox (spam filtering, bounces and mailbox rules happen afterwards).
 */
function gt_send_driver_application_email($conn, $name, $username, $email, $phone, $license) {
    foreach (['SMTP_HOST', 'SMTP_PORT', 'SMTP_USER', 'SMTP_PASS', 'SMTP_FROM'] as $c) {
        if (!defined($c) || trim((string)constant($c)) === '') {
            return 'not_configured';
        }
    }

    // Every admin who enabled e-mail notifications and has a valid address (max 5).
    $recipients = [];
    try {
        $stmt = $conn->prepare("SELECT email FROM users WHERE role = 'admin' AND email_notifications = 1");
        $stmt->execute();
        foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $addr = trim((string)($row['email'] ?? ''));
            if ($addr !== '' && filter_var($addr, FILTER_VALIDATE_EMAIL) && !in_array(strtolower($addr), array_map('strtolower', $recipients), true)) {
                $recipients[] = $addr;
            }
            if (count($recipients) >= 5) break;
        }
    } catch (Throwable $e) {
        error_log("register.php: could not read admin e-mail recipients (" . get_class($e) . ")");
        return 'failed';
    }
    if (count($recipients) === 0) {
        return 'no_recipient';
    }

    try {
        $mail = new PHPMailer(true);
        $mail->isSMTP();
        $mail->Host       = SMTP_HOST;
        $mail->SMTPAuth   = true;
        $mail->Username   = SMTP_USER;
        $mail->Password   = SMTP_PASS;
        $mail->SMTPSecure = PHPMailer::ENCRYPTION_STARTTLS;
        $mail->Port       = SMTP_PORT;
        $mail->Timeout    = 10;
        $mail->setFrom(SMTP_FROM, defined('SMTP_NAME') ? SMTP_NAME : 'Garbage Tracker');
        foreach ($recipients as $addr) {
            $mail->addAddress($addr);
        }
        $mail->isHTML(true);
        $mail->Subject = 'New Driver Application Pending Approval - Garbage Tracker';

        $timestamp = date("F j, Y, g:i a");
        $row = function ($label, $value) {
            return "<tr><td style='padding: 8px; border: 1px solid #eee; font-weight: bold; width: 30%;'>" . $label
                . "</td><td style='padding: 8px; border: 1px solid #eee;'>" . htmlspecialchars((string)$value) . "</td></tr>";
        };
        $mail->Body = "
            <div style='font-family: Arial, sans-serif; padding: 20px; border: 1px solid #ddd; border-radius: 8px;'>
                <h2 style='color: #00796B;'>New Driver Application</h2>
                <p>Hello Admin,</p>
                <p>A new driver has registered and is awaiting your approval in the system.</p>
                <table style='width: 100%; border-collapse: collapse; margin-top: 10px;'>"
                . $row('Driver Name:', $name)
                . $row('Username:', $username)
                . $row('Email:', $email)
                . $row('Phone:', $phone)
                . $row('License Number:', $license)
                . $row('Applied At:', $timestamp) . "
                </table>
                <p style='margin-top: 20px;'>Please log in to the <strong>Admin Dashboard -> User Management</strong> to review and approve this application.</p>
                <hr style='border: 0; border-top: 1px solid #eee;'>
                <p style='font-size: 12px; color: #7f8c8d;'>This is an automated message from the Garbage Tracker System.</p>
            </div>
        ";

        $mail->send();
        return 'smtp_accepted';
    } catch (Throwable $e) {
        // Class name only plus a short, credential-scrubbed hint: never the full SMTP transcript.
        $hint = substr(preg_replace('/\s+/', ' ', (string)$e->getMessage()), 0, 120);
        if (defined('SMTP_PASS') && SMTP_PASS !== '') $hint = str_replace(SMTP_PASS, '[redacted]', $hint);
        if (defined('SMTP_USER') && SMTP_USER !== '') $hint = str_replace(SMTP_USER, '[redacted]', $hint);
        error_log("register.php: driver application e-mail failed (" . get_class($e) . "): " . $hint);
        return 'failed';
    }
}

$data = json_decode(file_get_contents("php://input"));

if (!$data) {
    echo json_encode(["success" => false, "message" => "No data received"]);
    exit;
}

// Backend Consent Check: Reject registration if explicit terms acceptance is missing
$termsAccepted = isset($data->termsAccepted) ? $data->termsAccepted : (isset($data->terms_accepted) ? $data->terms_accepted : null);
if ($termsAccepted !== 1 && $termsAccepted !== '1' && $termsAccepted !== true) {
    http_response_code(400);
    echo json_encode([
        "success" => false,
        "message" => "Explicit acceptance of the Terms & Conditions and Privacy Policy is required."
    ]);
    exit;
}

if (!empty($data->username) && !empty($data->password) && !empty($data->role)) {
    // Public registration only creates Residents and Drivers. Admin accounts are never
    // self-registered (they are created by an administrator).
    $role = strtolower(trim((string)$data->role));
    if ($role !== 'resident' && $role !== 'driver') {
        http_response_code(403);
        echo json_encode(["success" => false, "message" => "This account type cannot be registered here."]);
        exit;
    }
    $data->role = $role;
    $data->username = trim((string)$data->username);

    // Driver accounts are created by an administrator (User Management > Add Driver), never by
    // public sign-up: a verified admin token is required and the account is active at once.
    $createdByAdmin = false;
    if ($role === 'driver') {
        $payload = gt_auth_secret() !== null ? gt_verify_token(gt_request_token()) : null;
        if ($payload === null || ($payload['role'] ?? '') !== 'admin') {
            http_response_code(403);
            echo json_encode(["success" => false, "message" => "Driver accounts are created by the barangay administrator. Please contact the barangay office."]);
            exit;
        }
        $createdByAdmin = true;
    }

    if (strlen($data->username) < 3 || strlen($data->username) > 50 || preg_match('/\s/', $data->username)) {
        echo json_encode(["success" => false, "message" => "Username must be 3-50 characters without spaces."]);
        exit;
    }
    if (strlen((string)$data->password) < 6) {
        echo json_encode(["success" => false, "message" => "Password must be at least 6 characters."]);
        exit;
    }
    if (!empty($data->email) && !filter_var($data->email, FILTER_VALIDATE_EMAIL)) {
        echo json_encode(["success" => false, "message" => "Please enter a valid email address."]);
        exit;
    }

    try {
        // Duplicate prevention across BOTH account tables (login accepts either table).
        $dupUser = $conn->prepare("SELECT 1 FROM users WHERE username = ?");
        $dupUser->execute([$data->username]);
        $dupRes = $conn->prepare("SELECT 1 FROM residents WHERE username = ?");
        $dupRes->execute([$data->username]);
        if ($dupUser->fetch() || $dupRes->fetch()) {
            echo json_encode(["success" => false, "message" => "That username is already taken."]);
            exit;
        }
        if (!empty($data->email)) {
            $dupEmailU = $conn->prepare("SELECT 1 FROM users WHERE email = ?");
            $dupEmailU->execute([$data->email]);
            $dupEmailR = $conn->prepare("SELECT 1 FROM residents WHERE email = ?");
            $dupEmailR->execute([$data->email]);
            if ($dupEmailU->fetch() || $dupEmailR->fetch()) {
                echo json_encode(["success" => false, "message" => "That email is already registered."]);
                exit;
            }
        }

        $hashed_password = password_hash($data->password, PASSWORD_BCRYPT);
        $name = !empty($data->name) ? $data->name : $data->username;

        if ($data->role === 'resident') {
            // Residents are auto-approved upon registration
            $query = "INSERT INTO residents (username, name, password_hash, email, phone, purok, complete_address, is_archived, approval_status, account_status)
                      VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'approved', 'active')";
            $stmt = $conn->prepare($query);

            $email = !empty($data->email) ? $data->email : "";
            $phone = !empty($data->phone) ? $data->phone : null;
            $purok = !empty($data->purok) ? $data->purok : "";
            $address = !empty($data->complete_address) ? $data->complete_address : "";

            $stmt->execute([$data->username, $name, $hashed_password, $email, $phone, $purok, $address]);

            // Residents are active immediately: one Admin in-app notification, never an e-mail.
            trigger_firebase_notification(
                'NEW_REGISTRATION',
                'New Resident Registered',
                "$name has registered as a Resident in $purok",
                $data->username
            );

            echo json_encode([
                "success" => true,
                "message" => "Registration successful. You can now log in.",
                "user_id" => (int)$conn->lastInsertId()
            ]);
            exit;
        }

        // For drivers (admin is rejected above)
        else if ($data->role === 'admin' || $data->role === 'driver') {
            $is_driver = ($data->role === 'driver');
            $is_archived = 0; // Do not use is_archived = 1 to represent pending
            // Created by an administrator: approved and able to log in immediately.
            $approval_status = ($is_driver && !$createdByAdmin) ? 'pending' : 'approved';
            $account_status = 'active';

            $query = "INSERT INTO users (username, name, email, password_hash, phone, license_number, preferred_truck, role, is_archived, approval_status, account_status)
                      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
            $stmt = $conn->prepare($query);

            $email = !empty($data->email) ? $data->email : "";
            $phone = !empty($data->phone) ? $data->phone : null;
            $license = !empty($data->license_number) ? $data->license_number : "";
            $truck = !empty($data->preferred_truck) ? $data->preferred_truck : null;

            $stmt->execute([$data->username, $name, $email, $hashed_password, $phone, $license, $truck, $data->role, $is_archived, $approval_status, $account_status]);
            $new_user_id = (int)$conn->lastInsertId();

            if ($is_driver && $createdByAdmin) {
                echo json_encode(["success" => true, "message" => "Driver account created. The driver can log in now.", "user_id" => $new_user_id]);
                exit;
            }

            if ($is_driver) {
                // Pending approval: exactly one Admin in-app notification ...
                trigger_firebase_notification(
                    'NEW_REGISTRATION',
                    'New Driver Application',
                    "$name has applied for a Driver role",
                    $data->username
                );

                // ... plus one e-mail attempt. The outcome is logged on the server only and
                // never changes the registration result.
                $mailStatus = gt_send_driver_application_email($conn, $name, $data->username, $email, $phone, $license);
                if ($mailStatus === 'smtp_accepted') {
                    error_log("register.php: driver application e-mail ACCEPTED by the SMTP server (inbox delivery not confirmed)");
                } else {
                    error_log("register.php: driver application e-mail not sent: $mailStatus");
                }
            }

            $msg = ($data->role === 'driver')
                ? "Registration submitted. Your account is pending administrator approval. You can log in once approved."
                : "Registration successful. You can now log in.";

            echo json_encode(["success" => true, "message" => $msg, "user_id" => $new_user_id]);
            exit;
        }

    } catch (PDOException $e) {
        // A concurrent duplicate that slipped past the pre-check hits the unique key.
        $isDuplicate = ($e->getCode() === '23000');
        error_log("register.php: " . $e->getMessage());
        echo json_encode([
            "success" => false,
            "message" => $isDuplicate
                ? "That username or email is already registered."
                : "Registration could not be completed. Please try again."
        ]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Incomplete data"]);
}
?>
