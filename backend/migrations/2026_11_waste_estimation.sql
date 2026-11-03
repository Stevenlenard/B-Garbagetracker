-- Objective 2.2 waste estimation: ADDITIVE tables only. Nothing existing is altered. NOT applied automatically.
-- Review, then run once in phpMyAdmin after a database backup. Rollback: migrations/2026_11_waste_estimation_rollback.sql
CREATE TABLE IF NOT EXISTS waste_estimation_settings (
  id TINYINT UNSIGNED NOT NULL PRIMARY KEY,
  kg_per_capita_day DECIMAL(8,4) NULL,
  rate_source VARCHAR(500) NOT NULL DEFAULT '',
  kg_per_hectare_day DECIMAL(10,4) NULL,
  hectare_rate_source VARCHAR(500) NOT NULL DEFAULT '',
  seasonal_value DECIMAL(5,3) NOT NULL DEFAULT 1.000,
  seasonal_source VARCHAR(500) NOT NULL DEFAULT '',
  seasonal_applies_to VARCHAR(200) NOT NULL DEFAULT '',
  seasonal_validated TINYINT(1) NOT NULL DEFAULT 0,
  seasonal_active TINYINT(1) NOT NULL DEFAULT 0,
  updated_by VARCHAR(64) NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS waste_estimation_areas (
  area_key VARCHAR(80) NOT NULL PRIMARY KEY,
  area_name VARCHAR(120) NOT NULL,
  size_m2 DECIMAL(14,2) NULL,
  size_kind ENUM('polygon','manual','none') NOT NULL DEFAULT 'none',
  size_source VARCHAR(500) NOT NULL DEFAULT '',
  size_verified TINYINT(1) NOT NULL DEFAULT 0,
  population INT UNSIGNED NULL,
  population_source VARCHAR(500) NOT NULL DEFAULT '',
  population_year SMALLINT UNSIGNED NULL,
  updated_by VARCHAR(64) NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
