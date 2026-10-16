<?php
/**
 * ROLLBACK STUB (containment-preserving). Used only if the schema-aware get_ai_load_summary.php
 * must be withdrawn. It contains no credential, makes no AI or other outbound request and no
 * database query. Never restore the original file: it embedded an exposed Gemini key.
 */
header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Cache-Control: no-store');
echo json_encode([
    'success' => false,
    'ai_disabled' => true,
    'message' => 'Load summary is temporarily unavailable on this server.',
]);
