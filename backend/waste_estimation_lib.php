<?php
// Objective 2.2 waste estimation: shared helpers. Parameters are stored WITH their source; nothing has a default value.

function gt_we_tables_exist(PDO $conn): bool
{
    try {
        $n = (int)$conn->query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name IN ('waste_estimation_settings','waste_estimation_areas')")->fetchColumn();
        return $n === 2;
    } catch (Throwable $e) {
        return false;
    }
}

/** Number within [min,max] or null (empty). Returns false when present but invalid. */
function gt_we_num($v, float $min, float $max)
{
    if ($v === null || $v === '') return null;
    if (!is_numeric($v)) return false;
    $f = (float)$v;
    if (!is_finite($f) || $f < $min || $f > $max) return false;
    return $f;
}

function gt_we_text($v, int $max): string
{
    $s = trim((string)($v ?? ''));
    return mb_substr($s, 0, $max);
}

/** Validates the settings payload. Returns ['error' => msg] or ['ok' => cleaned]. */
function gt_we_validate_settings($in): array
{
    if (!is_array($in)) return ['error' => 'Settings are missing.'];
    $cap = gt_we_num($in['kg_per_capita_day'] ?? null, 0.01, 10);
    $ha = gt_we_num($in['kg_per_hectare_day'] ?? null, 0.01, 100000);
    $sv = gt_we_num($in['seasonal_value'] ?? 1, 0.1, 5);
    if ($cap === false) return ['error' => 'kg per person per day must be between 0.01 and 10.'];
    if ($ha === false) return ['error' => 'kg per hectare per day must be between 0.01 and 100000.'];
    if ($sv === false || $sv === null) return ['error' => 'Seasonal multiplier must be between 0.1 and 5.'];
    $rateSrc = gt_we_text($in['rate_source'] ?? '', 500);
    $haSrc = gt_we_text($in['hectare_rate_source'] ?? '', 500);
    $seaSrc = gt_we_text($in['seasonal_source'] ?? '', 500);
    if ($cap !== null && $rateSrc === '') return ['error' => 'A per-person rate needs its source.'];
    if ($ha !== null && $haSrc === '') return ['error' => 'A per-hectare rate needs its source.'];
    $active = !empty($in['seasonal_active']) ? 1 : 0;
    $validated = !empty($in['seasonal_validated']) ? 1 : 0;
    if (($active || $validated || $sv != 1.0) && $seaSrc === '') return ['error' => 'A seasonal multiplier needs its source and date.'];
    return ['ok' => [
        'kg_per_capita_day' => $cap, 'rate_source' => $rateSrc,
        'kg_per_hectare_day' => $ha, 'hectare_rate_source' => $haSrc,
        'seasonal_value' => $sv, 'seasonal_source' => $seaSrc,
        'seasonal_applies_to' => gt_we_text($in['seasonal_applies_to'] ?? '', 200),
        'seasonal_validated' => $validated, 'seasonal_active' => $active,
    ]];
}

/** Validates one area row. Returns ['error' => msg] or ['ok' => cleaned]. */
function gt_we_validate_area($a): array
{
    if (!is_array($a)) return ['error' => 'Area row is invalid.'];
    $key = strtolower(gt_we_text($a['area_key'] ?? '', 80));
    if ($key === '' || !preg_match('/^[a-z0-9_\-]+$/', $key)) return ['error' => 'Area key is invalid.'];
    $name = gt_we_text($a['area_name'] ?? '', 120);
    if ($name === '') return ['error' => "Area $key needs a name."];
    $m2 = gt_we_num($a['size_m2'] ?? null, 1, 1000000000);
    if ($m2 === false) return ['error' => "$name: size must be a positive number of square metres."];
    $kind = (string)($a['size_kind'] ?? 'none');
    if (!in_array($kind, ['polygon', 'manual', 'none'], true)) return ['error' => "$name: size kind is invalid."];
    if ($m2 === null) $kind = 'none';
    $sizeSrc = gt_we_text($a['size_source'] ?? '', 500);
    if ($m2 !== null && $sizeSrc === '') return ['error' => "$name: an area size needs its source."];
    $verified = (!empty($a['size_verified']) && $m2 !== null) ? 1 : 0;
    $pop = gt_we_num($a['population'] ?? null, 1, 5000000);
    if ($pop === false) return ['error' => "$name: population must be a positive whole number."];
    $popSrc = gt_we_text($a['population_source'] ?? '', 500);
    if ($pop !== null && $popSrc === '') return ['error' => "$name: a population needs its source."];
    $yr = gt_we_num($a['population_year'] ?? null, 1900, 2100);
    if ($yr === false) return ['error' => "$name: population year is invalid."];
    return ['ok' => [
        'area_key' => $key, 'area_name' => $name, 'size_m2' => $m2, 'size_kind' => $kind, 'size_source' => $sizeSrc,
        'size_verified' => $verified, 'population' => $pop === null ? null : (int)round($pop), 'population_source' => $popSrc,
        'population_year' => $yr === null ? null : (int)$yr,
    ]];
}
