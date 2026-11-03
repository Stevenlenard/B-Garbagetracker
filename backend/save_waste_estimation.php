<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'waste_estimation_lib.php';

// Admin only, POST only. Saves the sourced parameters of the waste ESTIMATION and the confirmed area rows. It touches
// only the two waste_estimation_* tables: no load, weight, trip or forecast data.
$auth = gt_guard(['admin']);
gt_require_post();

$in = json_decode(file_get_contents('php://input'), true);
if (!is_array($in)) {
    http_response_code(400);
    echo json_encode(["success" => false, "message" => "Invalid request."]);
    exit;
}

function gt_we_reply($ok, $msg, $code = 200)
{
    if ($code !== 200) http_response_code($code);
    echo json_encode(["success" => $ok, "message" => $msg]);
    exit;
}

try {
    if (!gt_we_tables_exist($conn)) gt_we_reply(false, "Waste estimation is not set up on this server yet.", 409);

    $s = gt_we_validate_settings($in['settings'] ?? null);
    if (isset($s['error'])) gt_we_reply(false, $s['error'], 422);
    $rows = [];
    $areasIn = $in['areas'] ?? [];
    if (!is_array($areasIn) || count($areasIn) > 50) gt_we_reply(false, "Areas are invalid.", 422);
    foreach ($areasIn as $a) {
        $v = gt_we_validate_area($a);
        if (isset($v['error'])) gt_we_reply(false, $v['error'], 422);
        $rows[] = $v['ok'];
    }

    $by = (string)($auth['sub'] ?? '');
    $conn->beginTransaction();
    $st = $conn->prepare("INSERT INTO waste_estimation_settings
        (id, kg_per_capita_day, rate_source, kg_per_hectare_day, hectare_rate_source, seasonal_value, seasonal_source, seasonal_applies_to, seasonal_validated, seasonal_active, updated_by)
        VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE kg_per_capita_day = VALUES(kg_per_capita_day), rate_source = VALUES(rate_source),
          kg_per_hectare_day = VALUES(kg_per_hectare_day), hectare_rate_source = VALUES(hectare_rate_source),
          seasonal_value = VALUES(seasonal_value), seasonal_source = VALUES(seasonal_source), seasonal_applies_to = VALUES(seasonal_applies_to),
          seasonal_validated = VALUES(seasonal_validated), seasonal_active = VALUES(seasonal_active), updated_by = VALUES(updated_by)");
    $o = $s['ok'];
    $st->execute([$o['kg_per_capita_day'], $o['rate_source'], $o['kg_per_hectare_day'], $o['hectare_rate_source'], $o['seasonal_value'],
        $o['seasonal_source'], $o['seasonal_applies_to'], $o['seasonal_validated'], $o['seasonal_active'], $by]);

    $up = $conn->prepare("INSERT INTO waste_estimation_areas
        (area_key, area_name, size_m2, size_kind, size_source, size_verified, population, population_source, population_year, updated_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE area_name = VALUES(area_name), size_m2 = VALUES(size_m2), size_kind = VALUES(size_kind),
          size_source = VALUES(size_source), size_verified = VALUES(size_verified), population = VALUES(population),
          population_source = VALUES(population_source), population_year = VALUES(population_year), updated_by = VALUES(updated_by)");
    foreach ($rows as $r) {
        $up->execute([$r['area_key'], $r['area_name'], $r['size_m2'], $r['size_kind'], $r['size_source'], $r['size_verified'],
            $r['population'], $r['population_source'], $r['population_year'], $by]);
    }
    $conn->commit();
    gt_we_reply(true, "Saved.");
} catch (Throwable $e) {
    if ($conn->inTransaction()) $conn->rollBack();
    error_log('[save_waste_estimation] ' . $e->getMessage());
    gt_we_reply(false, "Could not save the waste estimation settings.", 500);
}
