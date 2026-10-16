<?php
/**
 * Route optimization proxy: DISABLED (Mapbox Matrix containment).
 *
 * Replaces backend/route_optimization.php on Hostinger. The original file is not in the
 * repository; old Web builds POST {driver_lat, driver_lng, stops[]} here whenever their own
 * Mapbox request fails, and the original may forward that to the Mapbox Matrix API.
 *
 * This version makes NO outbound request of any kind (no curl, no file_get_contents on a URL,
 * no database). Every request, from any client or caller, gets the same JSON answer, so old
 * clients show "route optimization failed" instead of producing Matrix usage.
 *
 * Reversible: the original is kept as a backup OUTSIDE public_html (see
 * deploy_prep/MAPBOX_CONTAINMENT.md). Do not restore it while Matrix must stay disabled.
 */
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
http_response_code(200); // old clients read success:false and stop; no client retries on it

// At most one log line per 10 minutes, so old clients still looping cannot flood the log.
$mark = rtrim(sys_get_temp_dir(), '/\\') . '/gt_route_optimization_disabled.log_mark';
if (!is_file($mark) || (time() - (int)@filemtime($mark)) > 600) {
    @touch($mark);
    error_log('route_optimization.php: request refused (Matrix containment), method='
        . ($_SERVER['REQUEST_METHOD'] ?? '?'));
}

echo json_encode([
    'success' => false,
    'error' => 'ROUTE_OPTIMIZATION_DISABLED',
    'message' => 'Route optimization is turned off on the server. Live tracking is not affected.',
]);
