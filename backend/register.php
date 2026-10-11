<?php
header("Content-Type: application/json");
date_default_timezone_set('Asia/Manila');
require_once 'db_config.php';
require_once 'email_config.php';

use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'PHPMailer/Exception.php';
require 'PHPMailer/PHPMailer.php';
require 'PHPMailer/SMTP.php';

function trigger_firebase_notification($type, $title, $message) {
    $url = "https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app/notifications.json";
    $data = [
        "type" => $type,
        "title" => $title,
        "message" => $message,
        "timestamp" => round(microtime(true) * 1000),
        "isRead" => false
    ];

    $ch = curl_init($url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
    curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
    curl_setopt($ch, CURLOPT_TIMEOUT, 5); // 5 seconds timeout
    curl_exec($ch);
    curl_close($ch);
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
    try {
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

            trigger_firebase_notification(
                'NEW_REGISTRATION',
                'New Resident Registered',
                "$name has registered as a Resident in $purok"
            );

            echo json_encode(["success" => true, "message" => "Registration successful. You can now log in."]);
            exit;
        }

        // For drivers/admins
        else if ($data->role === 'admin' || $data->role === 'driver') {
            $is_driver = ($data->role === 'driver');
            $is_archived = 0; // Do not use is_archived = 1 to represent pending
            $approval_status = $is_driver ? 'pending' : 'approved';
            $account_status = 'active';

            $query = "INSERT INTO users (username, name, email, password_hash, phone, license_number, preferred_truck, role, is_archived, approval_status, account_status)
                      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
            $stmt = $conn->prepare($query);

            $email = !empty($data->email) ? $data->email : "";
            $phone = !empty($data->phone) ? $data->phone : null;
            $license = !empty($data->license_number) ? $data->license_number : "";
            $truck = !empty($data->preferred_truck) ? $data->preferred_truck : null;

            $stmt->execute([$data->username, $name, $email, $hashed_password, $phone, $license, $truck, $data->role, $is_archived, $approval_status, $account_status]);

            if ($is_driver) {
                trigger_firebase_notification(
                    'NEW_REGISTRATION',
                    'New Driver Application',
                    "$name has applied for a Driver role"
                );

                // Send email notification to Admin if enabled
                try {
                    $adminStmt = $conn->prepare("SELECT email, email_notifications FROM users WHERE role = 'admin' LIMIT 1");
                    $adminStmt->execute();
                    $admin = $adminStmt->fetch();

                    if ($admin && $admin['email_notifications'] == 1 && !empty($admin['email'])) {
                        $mail = new PHPMailer(true);
                        $mail->isSMTP();
                        $mail->Host       = SMTP_HOST;
                        $mail->SMTPAuth   = true;
                        $mail->Username   = SMTP_USER;
                        $mail->Password   = SMTP_PASS;
                        $mail->SMTPSecure = PHPMailer::ENCRYPTION_STARTTLS;
                        $mail->Port       = SMTP_PORT;

                        $mail->setFrom(SMTP_FROM, SMTP_NAME);
                        $mail->addAddress($admin['email']);

                        $mail->isHTML(true);
                        $mail->Subject = 'New Driver Application Pending Approval - Garbage Tracker';

                        $timestamp = date("F j, Y, g:i a");

                        $mail->Body = "
                            <div style='font-family: Arial, sans-serif; padding: 20px; border: 1px solid #ddd; border-radius: 8px;'>
                                <h2 style='color: #00796B;'>New Driver Application</h2>
                                <p>Hello Admin,</p>
                                <p>A new driver has registered and is awaiting your approval in the system.</p>
                                <table style='width: 100%; border-collapse: collapse; margin-top: 10px;'>
                                    <tr>
                                        <td style='padding: 8px; border: 1px solid #eee; font-weight: bold; width: 30%;'>Driver Name:</td>
                                        <td style='padding: 8px; border: 1px solid #eee;'>$name</td>
                                    </tr>
                                    <tr>
                                        <td style='padding: 8px; border: 1px solid #eee; font-weight: bold;'>Username:</td>
                                        <td style='padding: 8px; border: 1px solid #eee;'>{$data->username}</td>
                                    </tr>
                                    <tr>
                                        <td style='padding: 8px; border: 1px solid #eee; font-weight: bold;'>Email:</td>
                                        <td style='padding: 8px; border: 1px solid #eee;'>$email</td>
                                    </tr>
                                    <tr>
                                        <td style='padding: 8px; border: 1px solid #eee; font-weight: bold;'>Phone:</td>
                                        <td style='padding: 8px; border: 1px solid #eee;'>$phone</td>
                                    </tr>
                                    <tr>
                                        <td style='padding: 8px; border: 1px solid #eee; font-weight: bold;'>License Number:</td>
                                        <td style='padding: 8px; border: 1px solid #eee;'>$license</td>
                                    </tr>
                                    <tr>
                                        <td style='padding: 8px; border: 1px solid #eee; font-weight: bold;'>Applied At:</td>
                                        <td style='padding: 8px; border: 1px solid #eee;'>$timestamp</td>
                                    </tr>
                                </table>
                                <p style='margin-top: 20px;'>Please log in to the <strong>Admin Dashboard -> User Management</strong> to review and approve or reject this application.</p>
                                <hr style='border: 0; border-top: 1px solid #eee;'>
                                <p style='font-size: 12px; color: #7f8c8d;'>This is an automated message from the Garbage Tracker System.</p>
                            </div>
                        ";

                        $mail->send();
                    }
                } catch (Exception $e) {
                    // Suppress email error so registration completes
                }
            }

            $msg = ($data->role === 'driver')
                ? "Registration submitted. Your account is pending administrator approval. You can log in once approved."
                : "Registration successful. You can now log in.";

            echo json_encode(["success" => true, "message" => $msg]);
            exit;
        }

    } catch (PDOException $e) {
        echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Incomplete data"]);
}
?>
