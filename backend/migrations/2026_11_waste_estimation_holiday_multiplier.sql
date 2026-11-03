-- Objective 2.2: the holiday multiplier, from documented increases in other Philippine cities. Run AFTER 2026_11_waste_estimation.sql.
-- The multiplier is applied BY DATE, only on Christmas and New Year (Dec 24 to Jan 1); every other day is 1.0.
-- Value 1.15 is the middle of the documented 10-20 % range. It is NOT measured in Lipa, so "validated" stays off.
--   Iloilo City CENRO: holiday waste up 10-20 % (425 t on Dec 18-25 against 370 t before; New Year 440 t against 400 t),
--     Panay News, January 2025 (https://panaynews.net/holiday-waste-in-iloilo-city-surges-by-20).
--   Cagayan de Oro: 480 t/day against 400 t, Dec 24 to Jan 1 (PNA-based report).
-- Nothing is applied for Undas or the Lipa celebrations (Jan 20 Coffee Festival / St. Sebastian, Jun 20 Foundation Day): no
-- waste figures were found for them. Rollback: the last statement of this file.
UPDATE waste_estimation_settings
SET seasonal_value = 1.150,
    seasonal_source = 'Iloilo City CENRO: holiday waste up 10-20 % (425 t on Dec 18-25 against 370 t before; New Year 440 t against 400 t), Panay News, Jan 2025; Cagayan de Oro: 480 t/day against 400 t, Dec 24 to Jan 1 (PNA-based report). 1.15 is the middle of the 10-20 % range; other Philippine cities, not measured in Lipa.',
    seasonal_applies_to = 'Christmas and New Year (Dec 24 to Jan 1)',
    seasonal_validated = 0,
    seasonal_active = 1,
    updated_by = 'seed'
WHERE id = 1;

-- Rollback:
--   UPDATE waste_estimation_settings SET seasonal_value = 1.000, seasonal_source = '', seasonal_applies_to = '', seasonal_validated = 0, seasonal_active = 0, updated_by = 'rollback' WHERE id = 1;
