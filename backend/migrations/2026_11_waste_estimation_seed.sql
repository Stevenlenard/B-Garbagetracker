-- Objective 2.2: sourced starting values. Run AFTER 2026_11_waste_estimation.sql. Rollback: the rollback script drops the tables.
-- Nothing here is invented: each value carries its source. Admins can change them in Analytics > Estimation parameters.
--
-- Rate: 0.50 kg/person/day, the national per-capita figure of the NSWMC (2015) as cited in Villanueva, Magsino, Hernandez &
--   Hernandez (2021), JPAIR Multidisciplinary Research Journal 43(1). A SECONDARY citation: it is a national average, not a
--   measured Balintawak figure.
-- Population: Barangay Balintawak, 19,278 (PSA 2020 Census of Population and Housing). Whole barangay only; no purok figure exists.
-- Seasonal multiplier: neutral (1.0, not applied).
INSERT INTO waste_estimation_settings
  (id, kg_per_capita_day, rate_source, kg_per_hectare_day, hectare_rate_source, seasonal_value, seasonal_source, seasonal_applies_to, seasonal_validated, seasonal_active, updated_by)
VALUES
  (1, 0.5000,
   'NSWMC 2015 national average per-capita waste generation (0.50 kg/person/day), as cited in Villanueva et al. (2021), JPAIR Multidisciplinary Research Journal 43(1). Secondary citation; national average, not measured in Balintawak.',
   NULL, '', 1.000, '', '', 0, 0, 'seed')
ON DUPLICATE KEY UPDATE id = id;

INSERT INTO waste_estimation_areas
  (area_key, area_name, size_m2, size_kind, size_source, size_verified, population, population_source, population_year, updated_by)
VALUES
  ('barangay_total', 'Barangay Balintawak (whole barangay)', NULL, 'none', '', 0, 19278,
   'PSA 2020 Census of Population and Housing, Barangay Balintawak, Lipa City', 2020, 'seed')
ON DUPLICATE KEY UPDATE area_key = area_key;
