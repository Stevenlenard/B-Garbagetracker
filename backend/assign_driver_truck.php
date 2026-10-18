<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';

// Only an administrator may assign a truck to a driver.
gt_require_role(['admin']);
gt_require_post();

$data = json_decode(file_get_contents("php://input"), true);
$driverId = (int)($data['driver_id'] ?? 0);
$truckId = trim((string)($data['truck_id'] ?? ''));   // '' = remove the assignment

if ($driverId <= 0 || ($truckId !== '' && !preg_match('/^[A-Za-z0-9 _.\-]{1,30}$/', $truckId))) {
    echo json_encode(["success" => false, "message" => "Invalid driver or truck."]);
    exit;
}

try {
    $d = $conn->prepare("SELECT name, is_archived FROM users WHERE user_id = ? AND LOWER(role) = 'driver'");
    $d->execute([$driverId]);
    $driver = $d->fetch(PDO::FETCH_ASSOC);
    if (!$driver) {
        echo json_encode(["success" => false, "message" => "Driver not found."]);
        exit;
    }
    if ($truckId !== '') {
        // One truck, one active driver.
        $c = $conn->prepare("SELECT name FROM users WHERE LOWER(preferred_truck) = LOWER(?) AND user_id <> ? AND LOWER(role) = 'driver' AND is_archived = 0 LIMIT 1");
        $c->execute([$truckId, $driverId]);
        $other = $c->fetch(PDO::FETCH_ASSOC);
        if ($other) {
            echo json_encode(["success" => false, "conflict" => true,
                "message" => "$truckId is already assigned to " . $other['name'] . "."]);
            exit;
        }
    }
    $u = $conn->prepare("UPDATE users SET preferred_truck = ? WHERE user_id = ?");
    $u->execute([$truckId === '' ? null : $truckId, $driverId]);
    echo json_encode(["success" => true, "driver_id" => $driverId, "truck_id" => $truckId === '' ? null : $truckId,
        "message" => $truckId === '' ? "Truck removed." : "Truck assigned."]);
} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Could not save the assignment."]);
}
