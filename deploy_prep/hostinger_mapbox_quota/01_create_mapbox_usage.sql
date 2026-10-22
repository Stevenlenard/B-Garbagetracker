-- Monthly Mapbox request counter shared by every device (backend/mapbox_quota.php).
-- One row per service and UTC month. Creates one new table; touches nothing else.
CREATE TABLE IF NOT EXISTS mapbox_usage (
  service VARCHAR(40) NOT NULL,
  month CHAR(7) NOT NULL,            -- 'YYYY-MM' (UTC)
  requests INT UNSIGNED NOT NULL DEFAULT 0,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (service, month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
