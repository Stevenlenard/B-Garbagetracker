# Objective 2.2: Waste Estimation by Collection Area

Status 2026-11-04: deployed with the approval of the project owner (see section 8). Starting values, each with its source (migration `2026_11_waste_estimation_seed.sql`):

- Rate: **0.50 kg/person/day**, NSWMC 2015 national figure as cited in Villanueva et al. (2021), JPAIR 43(1). A secondary citation and a national average, not a Balintawak measurement.
- Population: **19,278**, Barangay Balintawak, PSA 2020 CPH. Whole barangay only.
- Result: **19,278 x 0.50 x 1.0 = 9,639 kg/day** for the whole barangay (an estimate of waste generated, not collected weight). Per-purok estimates stay "Not configured": there is no purok population and only OpenStreetMap-derived sizes (unverified), and the per-hectare rate has no source.
- The whole-barangay figure is shown on its own and is never added to the per-area figures or to the capacity-equivalent total.

## 1. Area data (10 collection areas)

Sizes below are computed geodesically from the geometry **stored in Firebase `puroks`** (snapshot `puroks_now.json`, 2026-11-04). The stored `verificationStatus = VERIFIED` and `coordinateSource` labels are admin-entered text; they are not evidence that a polygon is a surveyed boundary, so the module does not trust them. An area is only treated as verified when an admin ticks "verified" while entering the size and its source.

| Area | Boundary source (as stored) | Size from stored geometry | Matches real collection area? | Module treatment / confidence |
|---|---|---|---|---|
| Central (Purok 1) | "Barangay Balintawak Official GIS" (label only; no file or URL on record) | 271,502 m² = 27.15 ha (5 vertices) | Unknown. Could not obtain the source layer to confirm. | Usable, **unverified**, Low confidence |
| Purok 4 / El Pueblo | "Admin Verified (Updated Exact Points)" | 28,118 m² = 2.81 ha (4 vertices) | Unknown | Usable, **unverified**, Low |
| Brixton Homes | "Admin Verified (Accurate Location)" | 431,979 m² (43.2 ha): placeholder-like box, not used. OSM candidate: relation/18115151 "Brixton Heights" = **37,956 m² (3.80 ha)** | Possible: name differs (Heights/Homes), OSM centre ~190 m from the stored point | OSM candidate shown, **unverified**, Low |
| Purok 2 | "Admin Verified (Updated)" | 431,967 m² | No: placeholder-like box | **Not used** |
| Purok 3 | "Admin Verified (Updated)" | 431,969 m² | No: placeholder-like box | **Not used** |
| Purok Paraiso (OSM has only a neighbourhood point node, no polygon) | "Admin Verified (Updated)" | 431,995 m² | No: placeholder-like box | **Not used** |
| Riverside | "Admin Verified (Approximate Map Center)" | 431,995 m²: placeholder-like box, not used. OSM: way/407890456 "Riverside Subdivision" = **62,150 m² (6.22 ha)** | Likely: same name, OSM centre (13.94654, 121.16365) equals the stored point | OSM size shown, **unverified**, Low |
| Ayala Highway | "Admin Verified (Updated Exact Road Endpoints)" | No polygon. Stored entrance to end: ~1,135 m. OSM way/77592019: 1,477 m long, tag width 10.5 m (road carriageway, not a service area). | A road: no documented service-area width | No size; "Size unavailable" |
| T.M. Kalaw Street | "Admin Verified (Updated T.M. Kalaw Start)" | No polygon. Stored endpoints: ~550 m. OSM way/82061812: 645 m, tag width 6 m (carriageway, not a service area). | Same | No size |
| San Nicolas | "Barangay Balintawak Official GIS" (label) | No polygon (point only) | Unknown | No size |

The five boxes differ by under 0.01% in area (431,967 to 431,995 m²). Real puroks do not have equal areas, so `WasteEstimation.placeholderAreas` flags any group of three or more areas within 0.5% of each other and refuses to use them.

**OpenStreetMap retrieval (Overpass, 2026-11-04):** polygons exist only for Riverside Subdivision and Brixton Heights among our areas; Paraiso is a point; there is no polygon for Central, the other puroks, or Balintawak itself. Other Balintawak polygons found but not among our 10 areas: Bel-Air Villas 12.45 ha (way/574855654), Barangay Homes 2.69 ha (way/1135371416). OSM is volunteer-mapped and not an official source, so every OSM size is shown as unverified (lib/utils/osm_area_references.dart).

**Roads (Ayala Highway, T.M. Kalaw Street, and Tanco Road if added):** no documented service-area width was found in any source reached. No buffer is invented. A road can be given an area only if an admin enters a size with its source (for example barangay-defined frontage depth), or by giving it a population/household count instead.

**External boundary sources tried:** OpenStreetMap has only a point node for Balintawak and road ways (T.M. Kalaw 82061812, Ayala Highway 77592019, San Nicolas Street 81238775); no purok or subdivision polygons were found. Overpass API mirrors returned 502/504 during the session, so a named-polygon query was not completed (retry later). PSA RSSO4A returned HTTP 403. NAMRIA/PSA barangay shapefiles were not publicly retrievable. Lipa government page `lipa.gov.ph/?p=1099` returned 404.

## 2. Waste-generation parameters found

| Parameter | Value | Source | Use in module |
|---|---|---|---|
| Population, Barangay Balintawak | 19,278 (2020) | PSA 2020 Census of Population and Housing. OSM node 2820722333 carries population=19063 dated 2024-07-01 (volunteer tag, likely the 2024 POPCEN; not verified). | Barangay total only. **No purok-level population found.** Not loaded as a default. |
| Lipa City land area | 209.40 km² | Lipa City / PSA profile pages | Context only. **Balintawak land area not found.** |
| Lipa City waste generated | ~167 thousand kg/day (2018) | CENRO-Lipa, as quoted in Villanueva et al. (2021), JPAIR Multidisciplinary Research Journal 43(1). The abstract prints "167kilos"; the full text is behind a login, so the unit and scale must be verified against the paper or CENRO. | Context only |
| National per-capita generation | 0.50 kg/person/day | NSWMC 2015, quoted in a JPAIR paper (secondary citation) | **Not loaded.** Admin may enter it with the citation if the panel accepts a national rate. |
| Holiday increase | +10 to +20% | CENRO Iloilo City, January 2025 | Different city; **not applicable to Lipa**; not loaded. |

None of these is shipped as a default. Entering a rate without a source is rejected by both the module and the PHP validation.

## 3. Seasonal multiplier

Default is 1.0 and inactive. It applies only when an admin enters a value, supplies a source/date, and switches it on. "Validated" is a separate switch meaning evidence is on file; the card says "not validated" otherwise. No Lipa-specific evidence for any multiplier was found. The legacy 1.2 is not reused.

## 4. Calculation

Preference order per area: measured weight for that one area (not multiplied) → population × kg/person/day × multiplier → hectares × kg/ha/day × multiplier. Otherwise "Not configured" with the reason. Result is "estimated kg/day of waste generated", never added to the capacity-equivalent total (5,000 kg per FULL event) or to measured weights; the summary keeps `estimatedKgPerDay` and `measuredKg` as separate fields.

Example (test fixture, not real data): 10 ha × 30 kg/ha/day × 1.0 = 300 kg/day.

## 5. What is missing (needed before this can be called complete)

1. **A boundary or size for each area** from an authority: Barangay Balintawak (sketch map / purok boundary resolution), Lipa CPDO or City Assessor GIS, or PSA enumeration-area maps. Verification procedure: obtain the layer or description, load it, compare against the truck's actual stops, and have the Barangay Captain or secretary sign off the size.
2. **Purok population or household count** (barangay records or PSA 2020 EA data) with its year.
3. **A waste-generation rate** for Lipa/Balintawak from CENRO-Lipa or the barangay ESWM plan (waste characterization or per-capita figure) with its citation.
4. Optional: documented seasonal/holiday evidence for Lipa.
5. The migration has to be approved and applied before the page can save anything.

## 6. Legacy holiday adjustment in PDF/Excel exports (corrected 2026-11-04 with approval)

`HolidayTracker.getMultiplier` (`lib/utils/holiday_tracker.dart`) returns 1.2 for every Saturday and Sunday and for 13 hard-coded dates. `PredictionEngine.predictWasteVolume/predictWeeklyVolume` use it, and `analytics_screen.dart` (~725-770 and ~1036-1052) feeds those forecasts to the exported reports. No source supports a 20% weekend increase for Lipa. The Moving Average forecast and its error metrics do not use it and are untouched.

**Correction made:** the Analytics forecast (on-screen and in the PDF/Excel exports) now passes a neutral multiplier of 1.0 (`PredictionEngine.predictWasteVolume/predictWeeklyVolume(multiplier: 1.0)`), and the exports say "No holiday or weekend adjustment is applied". `HolidayTracker` and the legacy default are unchanged and pinned by `test/forecast_holiday_test.dart`. Effect: the next-day figure no longer rises 20% on weekends and the 7-day total no longer depends on the weekday of export. The Moving Average, its metrics, and historical results are unaffected. Not changed: the unsourced +10% for routes of more than 10 stops in the same function.

## 7. Files

New: `lib/utils/osm_area_references.dart`, `lib/utils/waste_estimation.dart`, `lib/widgets/waste_estimation_card.dart`, `test/waste_estimation_test.dart`, `test/waste_estimation_card_test.dart`, `backend/waste_estimation_lib.php`, `backend/get_waste_estimation.php`, `backend/save_waste_estimation.php`, `backend/migrations/2026_11_waste_estimation.sql`, `backend/migrations/2026_11_waste_estimation_rollback.sql`.
Edited: `lib/api/api_service.dart` (two methods), `lib/screens/analytics_screen.dart` (one import and one card line in the insights section).

## 8. Deployment

Run the migration after a database backup (rollback script provided), upload the two PHP endpoints plus `waste_estimation_lib.php`, build and upload web and APK. Both endpoints use `gt_guard(['admin'])` and prepared statements; save is POST-only and writes only the two new tables.

## 9. Barangay-drawn boundaries and the area share (2026-11-04)

**Boundaries.** The barangay's own outlines of nine collection areas (drawn on a Google Maps satellite image and confirmed by the barangay, as stated by the project owner) replace the placeholder boxes and the OpenStreetMap references as the source of area sizes. The screenshot has no coordinates, so it was positioned by fitting the OpenStreetMap main roads to its yellow roads (an automatic search over scale and offset; the OSM roads then lie on the screenshot's roads), and the white outlines were traced by eye. Expect 30-60 m of position error and about +/-10-15 % on each size. Checks: the Riverside outline is centred 40 m from the OpenStreetMap "Riverside Subdivision"; Central is 55 m from its stored point. The vertices are in `docs/data/balintawak_purok_boundaries_2026-11-04.geojson`; the sizes are applied with `backend/migrations/2026_11_waste_estimation_area_sizes.sql`.

| Area | Size (m²) | Size (ha) |
|---|---|---|
| Purok 4 / El Pueblo | 467,498 | 46.75 |
| Purok 2 | 391,556 | 39.16 |
| Purok 3 | 391,788 | 39.18 |
| Brixton Homes | 213,231 | 21.32 |
| Central (Purok 1) | 268,076 | 26.81 |
| T.M. Kalaw Street | 270,461 | 27.05 |
| Riverside | 152,688 | 15.27 |
| San Nicolas | 272,186 | 27.22 |
| Purok Paraiso | 195,400 | 19.54 |
| Ayala Highway | none | the sketch draws no boundary for the road |
| **Total of the nine** | **2,622,884** | **262.3** |

**Area share.** Without a population per area and without a per-hectare rate, an area with a size takes its proportion of the whole-barangay estimate: share = barangay estimate × (area size ÷ sum of the sized areas). With 19,278 people × 0.50 kg = 9,639 kg/day over 262.3 ha, that is about 36.7 kg per hectare per day, so Purok 4 / El Pueblo is about 1,718 kg/day and Riverside about 561 kg/day. The seasonal multiplier is already in the barangay figure. The shares add up to the barangay figure. This is an estimate with two stated assumptions: the same waste per hectare in every area, and that the collection areas cover the barangay. Confidence is Low. A sourced per-hectare rate or a population for an area takes priority over the share. It is shown as an estimate of waste generated and is never added to the recorded loads (capacity-equivalent 5,000 kg per FULL event) or to measured weights.

**Seasonal and holiday multiplier.** It stays neutral (1.0) because no document gives a Lipa value, and the recorded loads cannot reveal one: they are mostly capacity-equivalent events (5,000 kg per FULL), not weights, and the number of FULL loads depends on assignments, not on how much waste people produced. It is applied automatically as soon as a value with its source is entered and switched on.
