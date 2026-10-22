<?php
/**
 * Public fleet counts for the help assistant (Truck Buddy) and the public page.
 * Returns COUNTS ONLY: no names, emails, phone numbers or ids. Read-only, no input.
 *
 *   drivers   approved, active driver accounts
 * (Trucks and service areas are counted by the app from the truck registry and the service
 *  areas the maps use, so every number matches what users see.)
 *
 * The answer is kept for 60 s in a server-side cache file, so many visitors at once do not each
 * open a database connection (the shared hosting limits simultaneous MySQL connections).
 */
header("Content-Type: application/json");
header("Cache-Control: public, max-age=300");

const GT_STATS_CACHE_SECONDS = 60;
$cacheFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'gt_public_stats_' . md5(__DIR__) . '.json';

$cached = @file_get_contents($cacheFile);
if ($cached !== false && (time() - (int)@filemtime($cacheFile)) < GT_STATS_CACHE_SECONDS) {
    echo $cached;
    exit;
}

require_once 'db_config.php';

try {
    // Rows approved before approval_status existed are NULL: treated as approved (as login.php does).
    $active = "role = 'driver'
        AND (is_archived IS NULL OR is_archived = 0)
        AND (approval_status IS NULL OR approval_status = 'approved')
        AND (account_status IS NULL OR account_status NOT IN ('archived', 'rejected', 'suspended'))";

    $drivers = (int)$conn->query("SELECT COUNT(*) FROM users WHERE $active")->fetchColumn();

    $json = json_encode([
        "success" => true,
        "drivers" => $drivers,
    ]);
    // Written to a temporary name and renamed, so a reader never sees a half-written file.
    $tmp = $cacheFile . '.' . getmypid() . '.tmp';
    if (@file_put_contents($tmp, $json, LOCK_EX) !== false) {
        @rename($tmp, $cacheFile);
    }
    echo $json;
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(["success" => false, "message" => "Counts are not available right now."]);
}
