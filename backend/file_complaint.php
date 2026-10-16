<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'email_config.php';
require_once 'auth_token.php';

// PHPMailer Includes
use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'PHPMailer/Exception.php';
require 'PHPMailer/PHPMailer.php';
require 'PHPMailer/SMTP.php';

/**
 * ONE Admin in-app notification per saved complaint (written here, after the INSERT, so it
 * cannot exist without the complaint and does not depend on the resident's device).
 */
function gt_notify_admin_complaint($complaintId, $residentId, $residentName, $purok, $category) {
    $url = "https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app/notifications.json";
    $payload = [
        "type" => "RESIDENT_COMPLAINT",
        "title" => "New Resident Complaint",
        "message" => $residentName . " filed a complaint in " . $purok . ": " . $category,
        "resident_id" => (int)$residentId,
        "complaint_id" => (int)$complaintId,
        "timestamp" => round(microtime(true) * 1000),
        "isRead" => false
    ];
    try {
        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($payload));
        curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
        curl_setopt($ch, CURLOPT_TIMEOUT, 5);
        $out = curl_exec($ch);
        curl_close($ch);
        if ($out === false || $out === '' || strpos((string)$out, '"error"') !== false) {
            error_log("file_complaint.php: admin in-app notification was not accepted by Firebase (complaint $complaintId)");
        }
    } catch (Throwable $e) {
        error_log("file_complaint.php: admin in-app notification failed (" . get_class($e) . ")");
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $resident_id = $_POST['resident_id'] ?? null;
    $category = $_POST['category'] ?? null;
    $description = $_POST['description'] ?? null;
    $purok_input = $_POST['purok'] ?? null;
    $location = $_POST['location'] ?? null;

    $category = $category !== null ? trim((string)$category) : null;
    $description = $description !== null ? trim((string)$description) : null;

    if ($resident_id) {
        // A resident can only file complaints under their own id.
        gt_require_subject('resident', $resident_id);
    }

    if ($resident_id && $category && $description) {
        if (strlen($description) > 2000 || strlen($category) > 100) {
            echo json_encode(["success" => false, "message" => "The complaint is too long."]);
            exit;
        }
        try {
            // The complaint must belong to a real, active resident account.
            $resStmt = $conn->prepare("SELECT name, purok, is_archived FROM residents WHERE resident_id = ?");
            $resStmt->execute([$resident_id]);
            $resident = $resStmt->fetch();
            if (!$resident || (isset($resident['is_archived']) && $resident['is_archived'] == 1)) {
                echo json_encode(["success" => false, "message" => "Resident account not found. Please log in again."]);
                exit;
            }
            $resident_name = $resident['name'] ?? "Resident";
            $purok = !empty($purok_input) ? $purok_input : ($resident['purok'] ?? "Unknown");
            $location_str = !empty($location) ? $location : $purok;

            // Insert only into columns that exist in the deployed table (older databases may
            // not have purok/location). The complaint itself is always saved.
            $existing = $conn->query("DESCRIBE complaints")->fetchAll(PDO::FETCH_COLUMN);
            $fields = ['resident_id', 'category', 'description', 'status'];
            $values = [$resident_id, $category, $description, 'pending'];
            if (in_array('purok', $existing, true)) { $fields[] = 'purok'; $values[] = $purok; }
            if (in_array('location', $existing, true)) { $fields[] = 'location'; $values[] = $location_str; }
            $query = "INSERT INTO complaints (" . implode(', ', $fields) . ") VALUES ("
                   . implode(', ', array_fill(0, count($fields), '?')) . ")";
            $stmt = $conn->prepare($query);
            $stmt->execute($values);
            $new_complaint_id = (int)$conn->lastInsertId();

            gt_notify_admin_complaint($new_complaint_id, $resident_id, $resident_name, $purok, $category);

            // EMAIL NOTIFICATION TO ADMIN
            try {
                $adminStmt = $conn->prepare("SELECT email, email_notifications FROM users WHERE role = 'admin' LIMIT 1");
                $adminStmt->execute();
                $admin = $adminStmt->fetch();

                if ($admin && $admin['email_notifications'] == 1 && !empty($admin['email'])
                    && defined('SMTP_HOST') && defined('SMTP_USER') && defined('SMTP_PASS')
                    && defined('SMTP_PORT') && defined('SMTP_FROM')) {
                    $mail = new PHPMailer(true);
                    $mail->isSMTP();
                    $mail->Host       = SMTP_HOST;
                    $mail->SMTPAuth   = true;
                    $mail->Username   = SMTP_USER;
                    $mail->Password   = SMTP_PASS;
                    $mail->SMTPSecure = PHPMailer::ENCRYPTION_STARTTLS;
                    $mail->Port       = SMTP_PORT;

                    $mail->setFrom(SMTP_FROM, defined('SMTP_NAME') ? SMTP_NAME : 'Garbage Tracker');
                    $mail->addAddress($admin['email']);

                    $mail->isHTML(true);
                    $mail->Subject = 'New Resident Complaint Filed - Garbage Tracker';
                    $mail->Body    = "
                        <div style='font-family: Arial, sans-serif; padding: 20px; border: 1px solid #ddd;'>
                            <h2 style='color: #d32f2f;'>New Complaint Received</h2>
                            <p>Hello Admin,</p>
                            <p>A resident has filed a new complaint. Here are the details:</p>
                            <ul>
                                <li><strong>Resident:</strong> " . htmlspecialchars((string)$resident_name) . "</li>
                                <li><strong>Purok:</strong> " . htmlspecialchars((string)$purok) . "</li>
                                <li><strong>Specific Location:</strong> " . htmlspecialchars((string)$location_str) . "</li>
                                <li><strong>Category:</strong> " . htmlspecialchars((string)$category) . "</li>
                                <li><strong>Description:</strong> " . htmlspecialchars((string)$description) . "</li>
                            </ul>
                            <p>Please log in to the system to address this issue.</p>
                        </div>
                    ";
                    $mail->send();
                }
            } catch (Throwable $e) {
                // The complaint is already saved: a mail problem must never turn the response
                // into a failure (the resident would resubmit and create duplicates).
                error_log("file_complaint.php: admin e-mail failed (" . get_class($e) . ")");
            }

            echo json_encode(["success" => true, "message" => "Complaint filed successfully", "complaint_id" => $new_complaint_id]);
        } catch (PDOException $e) {
            error_log("file_complaint.php: " . $e->getMessage());
            echo json_encode(["success" => false, "message" => "The complaint could not be saved. Please try again."]);
        }
    } else {
        echo json_encode(["success" => false, "message" => "Missing data"]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Invalid request method"]);
}
?>
