<?php
/**
 * Public fleet counts for the help assistant (Truck Buddy) and the public page.
 * Returns COUNTS ONLY: no names, emails, phone numbers or ids. Read-only, no input.
 *
 *   drivers   approved, active driver accounts
 * (Trucks and service areas are counted by the app from the truck registry and the service
 *  areas the maps use, so every number matches what users see.)
 */
header("Content-Type: application/json");
header("Cache-Control: public, max-age=300");
require_once 'db_config.php';

try {
    // Rows approved before approval_status existed are NULL: treated as approved (as login.php does).
    $active = "role = 'driver'
        AND (is_archived IS NULL OR is_archived = 0)
        AND (approval_status IS NULL OR approval_status = 'approved')
        AND (account_status IS NULL OR account_status NOT IN ('archived', 'rejected', 'suspended'))";

    $drivers = (int)$conn->query("SELECT COUNT(*) FROM users WHERE $active")->fetchColumn();

    echo json_encode([
        "success" => true,
        "drivers" => $drivers,
    ]);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(["success" => false, "message" => "Counts are not available right now."]);
}
