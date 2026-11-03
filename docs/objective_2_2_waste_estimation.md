# Objective 2.2: Waste Estimation by Collection Area

Status 2026-11-04: implemented **locally only**. Not deployed, no migration run. The module computes nothing until an admin enters sourced parameters (see "What is missing").

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

## 6. Separate finding: legacy holiday adjustment in PDF/Excel exports (not changed)

`HolidayTracker.getMultiplier` (`lib/utils/holiday_tracker.dart`) returns 1.2 for every Saturday and Sunday and for 13 hard-coded dates. `PredictionEngine.predictWasteVolume/predictWeeklyVolume` use it, and `analytics_screen.dart` (~725-770 and ~1036-1052) feeds those forecasts to the exported reports. No source supports a 20% weekend increase for Lipa. The Moving Average forecast and its error metrics do not use it and are untouched.

**Proposed safe correction (needs your approval):** make the export forecast use the neutral multiplier 1.0 unless a sourced multiplier is configured in this module, and label the export "Holiday/seasonal adjustment: none applied" otherwise. Cover with a test that pins the current output first, then the change. Until then, exports continue to behave as before.

## 7. Files

New: `lib/utils/osm_area_references.dart`, `lib/utils/waste_estimation.dart`, `lib/widgets/waste_estimation_card.dart`, `test/waste_estimation_test.dart`, `test/waste_estimation_card_test.dart`, `backend/waste_estimation_lib.php`, `backend/get_waste_estimation.php`, `backend/save_waste_estimation.php`, `backend/migrations/2026_11_waste_estimation.sql`, `backend/migrations/2026_11_waste_estimation_rollback.sql`.
Edited: `lib/api/api_service.dart` (two methods), `lib/screens/analytics_screen.dart` (one import and one card line in the insights section).

## 8. Deployment requirements (not done)

Run the migration after a database backup (rollback script provided), upload the two PHP endpoints plus `waste_estimation_lib.php`, build and upload web and APK. Both endpoints use `gt_guard(['admin'])` and prepared statements; save is POST-only and writes only the two new tables.
