-- Objective 2.2: confirmed area sizes of the collection areas. Run AFTER 2026_11_waste_estimation.sql (and its seed).
-- Only the size columns are written; a population already saved for an area is left as it is. Rollback: see the end of this file.
--
-- Source: the boundaries Barangay Balintawak drew for each purok on a Google Maps satellite image (confirmed by the barangay,
-- as stated by the project owner on 2026-11-04). The screenshot carries no coordinates, so it was positioned by fitting the
-- OpenStreetMap main roads to its yellow roads, and the drawn outlines were traced by eye. Position error is about 30-60 m and
-- the sizes are about +/-10-15 %. The vertices are in docs/data/balintawak_purok_boundaries_2026-11-04.geojson.
-- Ayala Highway has no boundary in the sketch (it is a road), so it gets no size.
INSERT INTO waste_estimation_areas (area_key, area_name, size_m2, size_kind, size_source, size_verified, updated_by) VALUES
  ('purok_4',              'Purok 4 / El Pueblo', 467498.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed'),
  ('purok_2',              'Purok 2',             391556.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed'),
  ('purok_3',              'Purok 3',             391788.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed'),
  ('brixton_homes',        'Brixton Homes',       213231.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed'),
  ('central_purok_1',      'Central (Purok 1)',   268076.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed'),
  ('tm_kalaw_st',          'T.M. Kalaw Street',   270461.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed'),
  ('riverside',            'Riverside',           152688.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed'),
  ('san_nicolas_sweeping', 'San Nicolas',         272186.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed'),
  ('purok_paraiso',        'Purok Paraiso',       195400.00, 'polygon', 'Barangay Balintawak boundary sketch (Google Maps satellite), confirmed by the barangay; traced and georeferenced 2026-11-04 from a screenshot via OpenStreetMap roads, about +/-10-15 % (vertices: docs/data/balintawak_purok_boundaries_2026-11-04.geojson)', 1, 'seed')
ON DUPLICATE KEY UPDATE area_name = VALUES(area_name), size_m2 = VALUES(size_m2), size_kind = VALUES(size_kind),
  size_source = VALUES(size_source), size_verified = VALUES(size_verified), updated_by = VALUES(updated_by);

-- Rollback (removes only what this file added; rows with a population keep it):
--   UPDATE waste_estimation_areas SET size_m2 = NULL, size_kind = 'none', size_source = '', size_verified = 0, updated_by = 'rollback'
--   WHERE updated_by = 'seed' AND area_key <> 'barangay_total';
--   DELETE FROM waste_estimation_areas WHERE updated_by = 'rollback' AND population IS NULL AND area_key <> 'barangay_total';
