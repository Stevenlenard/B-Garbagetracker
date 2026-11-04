# Objective 2.2: Waste Estimation by Collection Area

**Estimate of an area (kg/day) = area size (ha) x waste rate (kg/ha/day) x holiday multiplier of the day.**

That is the whole method. No population is used.

| Part | What it is | Where it comes from |
|---|---|---|
| Area size | Hectares of the collection area | The boundaries confirmed by the barangay (stored with the areas) |
| Waste rate | kg of waste per hectare per day, one rate for every area | Entered by an admin with its source. The starting value is 36.75 kg/ha/day, derived from 9,639 kg/day (NSWMC 0.5 kg per person per day x PSA 2020 population of 19,278) over the 262.29 ha of the nine areas. It is an assumption to be replaced by a current or measured figure |
| Holiday multiplier | x1.15 from Dec 24 to Jan 1, x1.0 on every other day | Iloilo City CENRO (holiday waste up 10-20 %, Panay News, Jan 2025) and Cagayan de Oro (480 t/day against 400 t); not measured in Lipa, so it is shown as not validated. Undas and the Lipa celebrations have no multiplier because no waste figures were found |

Example: Central (Purok 1) is 39.16 ha, so 39.16 x 36.75 x 1.0 = 1,439 kg/day on a regular day and 1,655 kg/day from Dec 24 to Jan 1.

## Where it shows

Admin > Analytics > **Waste Estimation by Area**: the card shows the total of the areas; opening it shows the formula, the
three figures (rate, holiday multiplier today, total), every area with its calculation (tap an area), and a dropdown with the
sources. The sliders icon edits the waste rate and the holiday multiplier (each needs its source). Area sizes are not edited
there.

## What it is not

An estimate of waste **generated**, not a measured weight. It is never added to the recorded loads (the 5,000 kg
capacity-equivalent per FULL trip) or to any measured weight.

## Files

- `lib/utils/waste_estimation.dart`: the calculation and the holiday calendar.
- `lib/services/waste_estimation_service.dart`: reads the data and builds the estimates.
- `lib/widgets/waste_estimation_card.dart`, `waste_estimation_details.dart`, `waste_estimation_edit_dialog.dart`: the screens.
- `backend/get_waste_estimation.php`, `save_waste_estimation.php`: the data (admin only).
- `backend/migrations/2026_11_waste_estimation_simple.sql`: sets the waste rate and clears the population (run once).
