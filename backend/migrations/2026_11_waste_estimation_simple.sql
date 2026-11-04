-- Objective 2.2, simple version: estimate of an area = area size (ha) x waste rate (kg/ha/day) x holiday multiplier of the day.
-- Population is no longer used. Run AFTER 2026_11_waste_estimation.sql and 2026_11_waste_estimation_holiday_multiplier.sql, once,
-- in phpMyAdmin after a database backup. Nothing else is altered.
--
-- 36.75 kg/ha/day = 9,639 kg/day (0.5 kg per person per day, NSWMC, x 19,278 people, PSA 2020) / 262.29 ha (the nine
-- barangay-confirmed collection areas). It is a derived, editable assumption; replace it with a current or measured figure.
UPDATE waste_estimation_settings
SET kg_per_hectare_day = 36.7500,
    hectare_rate_source = 'Derived rate: 9,639 kg/day (NSWMC 0.5 kg per person per day x PSA 2020 population of Brgy. Balintawak, 19,278) spread over the 262.29 ha of the nine barangay-confirmed collection areas = 36.75 kg/ha/day. The same rate applies to every area. Replace it with a current or measured figure when one is available.',
    kg_per_capita_day = NULL,
    rate_source = '',
    updated_by = 'seed'
WHERE id = 1;

UPDATE waste_estimation_areas
SET population = NULL, population_source = '', population_year = NULL
WHERE area_key = 'barangay_total';

-- Rollback:
--   UPDATE waste_estimation_settings SET kg_per_capita_day = 0.5000, rate_source = 'NSWMC 2015 via Villanueva et al. 2021', kg_per_hectare_day = NULL, hectare_rate_source = '', updated_by = 'rollback' WHERE id = 1;
--   UPDATE waste_estimation_areas SET population = 19278, population_source = 'PSA 2020 CPH', population_year = 2020 WHERE area_key = 'barangay_total';
