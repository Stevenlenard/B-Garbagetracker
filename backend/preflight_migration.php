<?php
// CLI-only read-only preflight check script for Phase 1 account migration
if (php_sapi_name() !== 'cli') {
    http_response_code(403);
    echo "Access denied. This preflight script can only be run from the command line (CLI).\n";
    exit(1);
}

require_once 'db_config.php';

try {
    echo "=== PHASE 1 MIGRATION READ-ONLY PREFLIGHT REPORT ===\n\n";

    // 1. Database Engine & Version
    $versionStmt = $conn->query("SELECT VERSION()");
    $dbVersion = $versionStmt->fetchColumn();
    echo "Database Engine / Version: $dbVersion\n";
    echo "Environment Classification: UNVERIFIED (connection destination 'localhost' is relative to PHP runner; development vs production status is unverified)\n\n";

    // 2. Check table 'schema_migrations' and column 'migration_name' using exact metadata check scoped to DATABASE()
    $tblCheck = $conn->prepare("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?");
    $tblCheck->execute(['schema_migrations']);
    $markerTableExists = $tblCheck->fetchColumn() > 0;

    $markerExists = false;
    $markerSchemaRecognized = false;
    if ($markerTableExists) {
        $colCheck = $conn->prepare("SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?");
        $colCheck->execute(['schema_migrations', 'migration_name']);
        $hasMigrationName = $colCheck->fetchColumn() > 0;

        if ($hasMigrationName) {
            $markerSchemaRecognized = true;
            $mStmt = $conn->prepare("SELECT COUNT(*) FROM schema_migrations WHERE migration_name = ?");
            $mStmt->execute(['phase1_account_lifecycle_separation_v2']);
            $markerExists = $mStmt->fetchColumn() > 0;
        }
    }

    echo "Migration Marker Table ('schema_migrations') Exists: " . ($markerTableExists ? "YES" : "NO") . "\n";
    if ($markerTableExists && !$markerSchemaRecognized) {
        echo "Marker Schema Status: UNRECOGNIZED (table exists but 'migration_name' column is missing)\n";
    } else {
        echo "Migration 'phase1_account_lifecycle_separation_v2' Marker Exists: " . ($markerExists ? "YES" : "NO") . "\n";
    }
    echo "\n";

    // 3. Inspect Tables & Columns for users and residents using exact metadata matching
    foreach (['users', 'residents'] as $table) {
        $tCheck = $conn->prepare("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?");
        $tCheck->execute([$table]);
        $tableExists = $tCheck->fetchColumn() > 0;

        if (!$tableExists) {
            echo "--- Table: `$table` (MISSING) ---\n\n";
            continue;
        }

        echo "--- Table: `$table` (EXISTS) ---\n";
        $colStmt = $conn->prepare("SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ?");
        $colStmt->execute([$table]);
        $colNames = $colStmt->fetchAll(PDO::FETCH_COLUMN);

        $hasIsArchived = in_array('is_archived', $colNames);
        $hasArchivedAt = in_array('archived_at', $colNames);
        $hasApprovalStatus = in_array('approval_status', $colNames);
        $hasAccountStatus = in_array('account_status', $colNames);
        $hasRole = in_array('role', $colNames);

        echo "Columns Present:\n";
        echo "  - is_archived: " . ($hasIsArchived ? "YES" : "COLUMN MISSING") . "\n";
        echo "  - archived_at: " . ($hasArchivedAt ? "YES" : "COLUMN MISSING") . "\n";
        echo "  - approval_status: " . ($hasApprovalStatus ? "YES" : "COLUMN MISSING") . "\n";
        echo "  - account_status: " . ($hasAccountStatus ? "YES" : "COLUMN MISSING") . "\n";
        echo "  - role: " . ($hasRole ? "YES" : "COLUMN MISSING") . "\n";

        // Total count
        $total = $conn->query("SELECT COUNT(*) FROM `$table`")->fetchColumn();
        echo "Total Records: $total\n\n";

        // Aggregate combinations of available status fields
        $selectCols = [];
        $groupCols = [];

        if ($hasIsArchived) {
            $selectCols[] = "is_archived";
            $groupCols[] = "is_archived";
        } else {
            $selectCols[] = "'N/A' as is_archived";
        }

        if ($hasArchivedAt) {
            $selectCols[] = "CASE WHEN archived_at IS NULL THEN 'absent (NULL)' ELSE 'present (not NULL)' END as archived_at_state";
            $groupCols[] = "archived_at_state";
        } else {
            $selectCols[] = "'COLUMN MISSING' as archived_at_state";
        }

        if ($hasApprovalStatus) {
            $selectCols[] = "COALESCE(approval_status, 'SQL NULL') as approval_status";
            $groupCols[] = "approval_status";
        } else {
            $selectCols[] = "'COLUMN MISSING' as approval_status";
        }

        if ($hasAccountStatus) {
            $selectCols[] = "COALESCE(account_status, 'SQL NULL') as account_status";
            $groupCols[] = "account_status";
        } else {
            $selectCols[] = "'COLUMN MISSING' as account_status";
        }

        if ($hasRole) {
            $selectCols[] = "COALESCE(role, 'SQL NULL') as role";
            $groupCols[] = "role";
        }

        $selectSql = implode(", ", $selectCols);
        $groupSql = implode(", ", $groupCols);

        $combos = $conn->query("SELECT $selectSql, COUNT(*) as cnt FROM `$table` GROUP BY $groupSql")->fetchAll(PDO::FETCH_ASSOC);

        echo "Aggregate Status Field Combinations:\n";
        foreach ($combos as $c) {
            $legacyFlag = $c['is_archived'] ?? 'N/A';
            $tsState = $c['archived_at_state'] ?? 'N/A';
            $appStat = $c['approval_status'] ?? 'N/A';
            $accStat = $c['account_status'] ?? 'N/A';
            $roleVal = $hasRole ? ($c['role'] ?? 'N/A') : null;
            $cnt = $c['cnt'];

            echo "  * legacy flag = $legacyFlag | archive timestamp = $tsState | approval status = $appStat | account status = $accStat" . ($hasRole ? " | role = $roleVal" : "") . " -> Count: $cnt";

            // Flag contradictory or ambiguous combinations using neutral terms
            $isAmbiguous = false;
            $ambiguityReason = "";
            if ($legacyFlag == 1 && $tsState === 'absent (NULL)') {
                $isAmbiguous = true;
                $ambiguityReason = "Ambiguous legacy record (legacy flag = 1 without archive timestamp; cannot distinguish pending registration from un-timestamped archive)";
            } elseif ($legacyFlag === '0' && $tsState === 'present (not NULL)') {
                $isAmbiguous = true;
                $ambiguityReason = "Contradictory state (legacy flag = 0 but archive timestamp is present)";
            }

            if ($isAmbiguous) {
                echo " [!] CONTRADICTORY/AMBIGUOUS: $ambiguityReason";
            }
            echo "\n";
        }
        echo "\n";
    }

    echo "Preflight analysis completed successfully with zero write operations.\n";
    echo "Note: Earlier migration defaults cannot necessarily be distinguished from genuine admin decisions.\n";

} catch (Exception $e) {
    echo "Preflight Error: " . $e->getMessage() . "\n";
    exit(1);
}
?>
