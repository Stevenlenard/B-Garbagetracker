-- MINIMAL SCHEMA MIGRATION FOR DURABLE CONSENT RECORDING
-- Note: Prepare for review. Do NOT execute directly against Hostinger/production database.

DELIMITER //

CREATE PROCEDURE IF NOT EXISTS AddTermsConsentColumns()
BEGIN
    -- Add consent columns to 'residents' table
    IF NOT EXISTS (
        SELECT * FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'residents'
        AND COLUMN_NAME = 'terms_accepted'
    ) THEN
        ALTER TABLE residents
            ADD COLUMN terms_accepted TINYINT(1) NOT NULL DEFAULT 0,
            ADD COLUMN terms_accepted_at TIMESTAMP NULL DEFAULT NULL,
            ADD COLUMN terms_version VARCHAR(20) DEFAULT NULL;
    END IF;

    -- Add consent columns to 'users' table
    IF NOT EXISTS (
        SELECT * FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'users'
        AND COLUMN_NAME = 'terms_accepted'
    ) THEN
        ALTER TABLE users
            ADD COLUMN terms_accepted TINYINT(1) NOT NULL DEFAULT 0,
            ADD COLUMN terms_accepted_at TIMESTAMP NULL DEFAULT NULL,
            ADD COLUMN terms_version VARCHAR(20) DEFAULT NULL;
    END IF;
END //

DELIMITER ;

-- Call procedure
CALL AddTermsConsentColumns();

-- Clean up
DROP PROCEDURE AddTermsConsentColumns;
