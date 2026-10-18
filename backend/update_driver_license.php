<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';

// Only an administrator may change a driver's license number.
gt_require_role(['admin']);
gt_require_post();

$data = json_decode(file_get_contents("php://input"), true);
$driverId = (int)($data['driver_id'] ?? 0);
$license = trim((string)($data['license_number'] ?? ''));

if ($driverId <= 0 || $license === '' || strlen($license) > 40 || !preg_match('/^[a-zA-Z0-9!@#$%^&*(),.?":{}|<> -]+$/', $license)) {
    echo json_encode(["success" => false, "message" => "Enter a valid license number (letters, numbers, spaces and dashes)."]);
    exit;
}

try {
    $d = $conn->prepare("SELECT 1 FROM users WHERE user_id = ? AND LOWER(role) = 'driver'");
    $d->execute([$driverId]);
    if (!$d->fetch()) {
        echo json_encode(["success" => false, "message" => "Driver not found."]);
        exit;
    }
    // A license belongs to one driver.
    $c = $conn->prepare("SELECT name FROM users WHERE LOWER(license_number) = LOWER(?) AND user_id <> ? AND LOWER(role) = 'driver' AND is_archived = 0 LIMIT 1");
    $c->execute([$license, $driverId]);
    $other = $c->fetch(PDO::FETCH_ASSOC);
    if ($other) {
        echo json_encode(["success" => false, "conflict" => true,
            "message" => "That license number already belongs to " . $other['name'] . "."]);
        exit;
    }
    $u = $conn->prepare("UPDATE users SET license_number = ? WHERE user_id = ?");
    $u->execute([$license, $driverId]);
    echo json_encode(["success" => true, "driver_id" => $driverId, "license_number" => $license, "message" => "License number saved."]);
} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Could not save the license number."]);
}
