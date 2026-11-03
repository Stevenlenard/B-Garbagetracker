-- Rollback for 2026_11_waste_estimation.sql. Only drops the two new tables; no existing data is touched.
DROP TABLE IF EXISTS waste_estimation_areas;
DROP TABLE IF EXISTS waste_estimation_settings;
