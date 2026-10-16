<?php
header("Content-Type: application/json");
require_once 'auth_token.php';
$gtAuth = gt_guard(['admin']); // Bundle 1
gt_require_post();
$backup_dir = 'backups/';

// Handle both POST (JSON) and GET for flexibility
$data = json_decode(file_get_contents("php://input"), true);
$filename = $data['filename'] ?? null; // POST only (no destructive GET links)

if (!$filename) {
    echo json_encode(["success" => false, "message" => "Filename not specified"]);
    exit;
}

$file = basename($filename); // Security: prevent directory traversal
$filepath = $backup_dir . $file;

if (file_exists($filepath)) {
    if (unlink($filepath)) {
        echo json_encode(["success" => true, "message" => "Backup deleted successfully"]);
    } else {
        echo json_encode(["success" => false, "message" => "Failed to delete file"]);
    }
} else {
    echo json_encode(["success" => false, "message" => "File not found"]);
}
?>
