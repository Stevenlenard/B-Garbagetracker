<?php
/**
 * UPDATE TRIP UNLOADED WEIGHT
 * Allows authorized users to record a measured weight in kg for a completed FULL trip.
 */

header("Content-Type: application/json");
require_once 'db_config.php';

$rawInput = file_get_contents("php://input");
$data = json_decode($rawInput, true);

if (!$data) {
    $data = $_POST;
}

$trip_id = $data['trip_id'] ?? null;
$weight_kg = $data['weight_kg'] ?? null;

if (empty($trip_id)) {
    echo json_encode(["success" => false, "message" => "Trip ID is required."]);
    exit;
}

if (!is_numeric($weight_kg) || (float)$weight_kg < 0) {
    echo json_encode(["success" => false, "message" => "Weight must be a non-negative number."]);
    exit;
}

$weight_kg = (float)$weight_kg;
$weight_tons = round($weight_kg / 1000.0, 2);

try {
    $tableCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_history'");
    if ($tableCheck->rowCount() == 0) {
        echo json_encode(["success" => false, "message" => "Trip history table does not exist."]);
        exit;
    }

    $stmt = $conn->prepare("
        UPDATE driver_trip_history
        SET weight_kg = ?, weight_type = 'MEASURED'
        WHERE trip_id = ?
    ");
    $stmt->execute([$weight_kg, $trip_id]);

    if ($stmt->rowCount() == 0) {
        $stmtInsert = $conn->prepare("
            INSERT INTO driver_trip_history (trip_id, driver_id, weight_kg, weight_type)
            VALUES (?, 0, ?, 'MEASURED')
            ON DUPLICATE KEY UPDATE weight_kg = ?, weight_type = 'MEASURED'
        ");
        $stmtInsert->execute([$trip_id, $weight_kg, $weight_kg]);
    }

    echo json_encode([
        "success" => true,
        "message" => "Trip weight updated successfully.",
        "trip_id" => $trip_id,
        "weight_kg" => $weight_kg,
        "weight_tons" => $weight_tons,
        "weight_type" => "MEASURED",
        "is_measured" => true
    ]);

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
