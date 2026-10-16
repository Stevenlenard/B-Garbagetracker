# Capstone System Investigation Report: B-Garbagetracker

> Read-only investigation. No project files were modified, nothing was sent to Hostinger, MySQL or Firebase.
> Note: while reading `backend/email_config.php` the SMTP password was visible because the redaction filter missed that file's format. It is not repeated in this report. Treat it as exposed anyway, since the file is committed to git (see S3).

---

## A. Executive Summary

The system is a **single Flutter codebase**. It builds an Android app and a Flutter Web app from the same code, backed by **two data stores that don't share data**:

- **Firebase Realtime Database (RTDB)** holds all real-time state: live truck positions, trips and route points, notifications, weekly area progress, truck metadata and login lockout.
- **PHP on Hostinger with MySQL** holds accounts, complaints, settings, backups and a partial copy of trip history used by Load History and analytics.

**What works, as far as the source shows:** the core loop is built end to end. The driver's GPS goes into Firebase `truck_locations/{truck}`, and the admin, resident and public web maps listen to that node. START/PAUSE/FULL/DONE, area detection by geofence, auto-notifications, complaint filing and resolution, route history replay, and PDF/Excel export all exist as real code.

**What's seriously wrong, ranked:**

1. **Security (P0).** None of the PHP endpoints check who is calling. Anyone on the internet can delete users, approve accounts, change permissions, read every complaint and trigger database dumps. Anyone can also register as an **admin**. Two-factor login is never enforced. Live credentials are committed to git and shipped inside the compiled web app: database password, Gmail SMTP app password, Gemini key, Mapbox token. Full database dumps sit in a folder the web server can likely serve, and copies are committed to git.
2. **Data integrity (P0/P1).**
   - `save_trip_history.php` **permanently deletes** finished trips once a month passes 200 trips across all drivers.
   - The FULL event's timestamp, weight and visited areas are **never saved**. The PHP ignores those fields.
   - Load History counts **every trip as 5 tons**, including trips that were never marked FULL.
3. **GPS delay (P1).** I found several causes in the code itself, independent of the network:
   - The shared map widget **drops** position updates that arrive while it's still drawing.
   - A 35 ms pulse animation floods the map with calls.
   - Admin and analytics screens re-download the entire, ever-growing `driver_routes` tree on every route point.
   - The resident map **overwrites** fresh Firebase positions every 8 s with stale MySQL data. That MySQL data is written only once, at login.
   - Driver location tracking has no Android foreground service, so it slows to a crawl when the app is in the background.
   - Each dashboard uses a different rule for "is this truck online" (30 s, 2 min, 3 min, 15 min).
4. **Analytics integrity (P1).** Several displayed numbers are made up, and the PDF repeats them:
   - "ETA Performance" fills in synthetic visits and jitters arrival differences.
   - "Prediction Confidence" is a formula with no real comparison behind it. It shows 100% when there's no data.
   - The PDF bar chart falls back to hard-coded fake counts, including areas that don't exist ("San Isidro").
   - **The Load History bar graph isn't built.** The backend sends yearly data and the app stores it, but nothing displays it.
5. **Broken flows (P1).** Forgot-password can never succeed. The driver approval workflow doesn't work at any step.

**Readiness:** good enough to demo live tracking in a controlled setting. Not ready for production or real users. The P0 security items and the analytics integrity items should come before any further feature or design work.

---

## B. Repository Structure and Architecture

### Active production code
| Path | Purpose | Status |
|---|---|---|
| `lib/` (~60k lines Dart) | Flutter app for all three roles, Android and Web | **Active** |
| `backend/*.php` (~70 files) | REST-like PHP endpoints using PDO on MySQL | **Active**, deployed at `https://indigo-bear-885857.hostingersite.com/backend/` |
| `web/` | Flutter web shell (`index.html`, SPA `.htaccess`) | Active |
| `public_html/` | **Compiled** Flutter web build (`main.dart.js`), committed | Deployment artifact |
| `android/` | Flutter Android host (manifest, gradle) | Active |

### Legacy, unused or noise
| Path | Finding |
|---|---|
| `Asia-repo1-main/` | Older **Kotlin** Android project, with its own `backend/db_config.php` and `google-services.json`. Not referenced by the Flutter build. |
| `app/` | Kotlin resources plus one `Verify2FAActivity.kt`. Not built by Flutter. |
| `integration_spec.md` | Describes a "Kotlin driver app" contract that no longer matches the Flutter writes (field names, status casing). Outdated. |
| `lib/screens/analytics_screen.dart.bak` (+ `.artifact.md`) | Backup copy. |
| `public_html/app.js`, `firebase-config.js` | Standalone JS map, not loaded by `index.html`. |
| `backend/backups/` (33 SQL dumps), `uploads/`, `exports/`, `reports/` | Runtime data committed to git (46 tracked files). |
| `lib/screens/data_management_screen.dart`, `lib/services/geofence_service.dart` | Nothing imports them. |
| `test/widget_test.dart` | Default "Counter increments" template. It would fail against this app. |

### Architecture map

```
                         ┌────────────────────────── Firebase RTDB (no Firebase Auth) ───────────────────────────┐
                         │ truck_locations/{TRUCK}   driver_routes/{trip}/{route,events,optimized_route}          │
                         │ weekly_collection_progress/{week}/{driver}/areas   notifications   users/{id}  trucks  │
                         │ puroks   load_history   login_security   system_logs   admin_settings   complaints(*)  │
                         └───────▲───────────────▲────────────────────▲───────────────────▲───────────────────────┘
          writes ~1/s per fix    │      onValue (full-node)     onValue (full-node)   REST POST notifications.json
                                 │               │                    │                   │ (register / notify_admin_issue)
  ┌──────────────────────┐       │   ┌───────────┴─────────┐  ┌───────┴──────────────┐    │
  │ DriverDashboard      │───────┘   │ AdminDashboard      │  │ Resident dashboard / │    │
  │ Geolocator stream →  │           │ + MapboxView        │  │ ResidentTrackTruck / │    │
  │ _processNewPosition  │           │ Analytics, TrackTrks│  │ StandaloneGisWeb     │    │
  └─────────┬────────────┘           └───────────┬─────────┘  └───────┬──────────────┘    │
            │ Dio (FormData/JSON), no auth token │                    │ poll get_locations│
            ▼                                    ▼                    ▼ every 3–8 s       │
  ┌───────────────────────────── PHP (Hostinger) — every endpoint unauthenticated, CORS * ───────────────┐
  │ login/register/approve/archive/delete_user · complaints · update_location (login only)              │
  │ save_trip_history (FULL & DONE) · get_load_history · get_ai_load_summary (Gemini) · get_eta_perf    │
  │ backups (full SQL dump to web dir) · export_report (HTML from GET params)                           │
  └───────────────────────────────────────────────┬─────────────────────────────────────────────────────┘
                                                  ▼
                                               MySQL
```
(*) There is a `complaints` node in Firebase, but complaints themselves live in MySQL. See A6.

**Entry point:** `lib/main.dart`. It calls `AppLocalizations.init`, then `NotificationService.init` and `startPersistentListening` (before Firebase is initialized; see X1), then sets the Mapbox token, then `Firebase.initializeApp` with options written into the code, then `runApp`.

**Routing:** on the web, the default route is `/tracking` (the public map, `StandaloneGisWebScreen`). On mobile it's `/splash`. Named routes include `/admin_dashboard`, `/driver_dashboard`, `/resident_dashboard`, `/analytics`, `/route_history` and others.

**Authorization in the app:** the client chooses the role at login (`login_screen.dart:314-319`) and stores it in SharedPreferences. **Routes have no guard.** On the web, opening `#/admin_dashboard` loads the admin screen for anyone. The data comes from public Firebase and PHP anyway.

---

## C. File and Module Inventory (key responsibilities)

| Module | Lines | Role | Main dependencies |
|---|---|---|---|
| `api/api_client.dart`, `api/api_service.dart` | 20 / 401 | Dio singleton, about 45 endpoint wrappers, no auth header | Hostinger base URL |
| `utils/session_manager.dart` | 204 | Session and "saved profiles" in SharedPreferences (stores the full user map) | — |
| `utils/login_security_manager.dart` | 94 | 5-attempt / 1-minute lockout stored in Firebase `login_security` (client-side only) | RTDB |
| `screens/driver_dashboard.dart` | 6,498 | GPS acquisition, trip lifecycle, Firebase writes, geofencing, notifications, maintenance, simulation | Geolocator, RTDB, ApiService, RouteOptimizationService |
| `screens/admin_dashboard.dart` | 3,967 | Fleet stats, presence, complaints counts, notifications, embedded `MapboxView` | RTDB (6 listeners), PHP |
| `screens/analytics_screen.dart` | 9,267 | Analytics, Waste Collection Summary, Load History modal, ETA performance modal, Gemini, PDF | RTDB, PHP, `google_generative_ai`, `pdf`/`printing` |
| `widgets/mapbox_view.dart` | 447 | Shared live map for admin and resident dashboards | RTDB `truck_locations` |
| `screens/resident_track_truck_screen.dart`, `track_trucks_screen.dart`, `standalone_gis_web_screen.dart`, `driver_track_truck_screen.dart` | 2.2–2.8k each | Separate live-map implementations (four copies of marker logic) | RTDB plus PHP polling |
| `screens/route_history_screen.dart` + `services/driver_route_history_service.dart` | 2,710 / 586 | Trip history, replay, stop detection, moving/stopped time | RTDB `driver_routes`, PHP route history |
| `services/service_area_service.dart` | 509 | Collection areas (seeded list of 10 areas) in Firebase `puroks` | RTDB |
| `services/truck_assignment_service.dart` | 191 | Works out which truck a driver has (session → Firebase users → truck_locations scan) | RTDB |
| `services/route_optimization_service.dart` | 507 | Mapbox Matrix/Directions plus a PHP proxy `route_optimization.php` (**that file isn't in the repo**) | Mapbox |
| `services/notification_service.dart` | 225 | Local notifications from Firebase `notifications` `onChildAdded` | flutter_local_notifications |
| `utils/prediction_engine.dart` | 117 | Waste-volume heuristic, ETA = distance ÷ speed, MAE helpers | `holiday_tracker` |
| `models/driver_trip.dart` | 487 | Trip model (default `weightKg = 5000`) | — |

**Dependencies (`pubspec.yaml`):** `mapbox_maps_flutter: ^3.0.0-alpha.1` is a pre-release (fragile). `google_generative_ai: ^0.4.0` targets Gemini 1.5 models. `firebase_core ^2.32` and `firebase_database ^10.5` are older majors. There's no state-management package; everything uses `setState` in very large StatefulWidgets.

---

## D. Admin Dashboard Investigation

| Feature | Data source and logic | Finding |
|---|---|---|
| Fleet stats and active fleet | `admin_dashboard.dart:424-555`, `onValue('truck_locations')`. A truck counts as online only if `isOnline`, the status isn't OFFLINE/COMPLETED/FINISHED, the 12 h session hasn't expired, it was seen within 3 min, **and** the driver is in the users-presence set (`:333-420`, 2–5 min). | Works in source. Freshness differs from the embedded map (15 min), so the list and map can disagree (G7). |
| Live map | `MapboxView` (shared widget) | Drops updates and runs a heavy animation timer (G1). Leaks a listener (G11). |
| "Routes today" and coverage % | `:557-577` listens to **all** of `driver_routes`, counts every trip ever, coverage = completed ÷ total | Mislabelled and expensive (A5, G2). |
| Complaints | Firebase `complaints` listener (`:579`) **and** MySQL `getComplaints` (`:639`) write the same counters | Two sources fight over the numbers (A6). |
| Notifications | Full `notifications` node; filtered with `_isNotificationForMe` | Full-node download (G2). |
| User management (approve/reject/archive) | `user_management_screen.dart` → `approve_user`/`reject_user`/`archive_user.php` | Approval doesn't work (S6). |
| Trucks and drivers | Firebase `trucks`, `users`; `truck_assignment_service` | Truck identity mixes truck ID and plate number (route points use the plate, `driver_dashboard.dart:1694`). |
| Analytics, Load History, ETA, PDF | See J and K | Several mock or fabricated values. |
| Settings, permissions, 2FA toggle | `admin_settings_screen.dart` → `update_permissions`, `toggle_2fa`, `get_access_logs` | Stored but **not enforced on the server**. I didn't check whether `can_view_analytics`/`can_manage_db` are enforced in the UI. The 2FA toggle compares `two_factor_enabled == 1`, but PDO returns strings, so the toggle may always show "off" (needs a runtime check). |
| Backups and data management | `trigger_backup.php`, `auto_backup_checker.php` (also runs on **every login**, `login.php:26`) | P0 exposure (S4). |

---

## E. Driver Dashboard Investigation

**Login and assignment** (`_loadUser`, `driver_dashboard.dart:459-620`):
1. Reads the session.
2. Resolves the truck (`TruckAssignmentService`).
3. Writes `users/{id}` and `truck_locations/{TRUCK}` as online.
4. Calls `update_location.php` (**this is the only MySQL location write in the whole app**).
5. Starts the GPS stream and a 30 s heartbeat.
6. Restores the trip, or **creates a new ACTIVE trip automatically** (`:839-841`, G9).

**GPS** (`_startTracking :1331`, `_processNewPosition :1356-1544`): `bestForNavigation` with `distanceFilter: 0` (the comment says "for tests"). Positions are rejected for accuracy above 200 m, implied speed above 120 km/h over more than 100 m, or jumps above 500 m in under 30 s. Distance only accumulates when speed exceeds 1 km/h. On the web, `speed` is often 0, so distance may never grow there (needs a runtime check). Each accepted fix produces:
- an update to `truck_locations/{TRUCK}` (position, speed, status, `lastSeen` server time)
- an update to `driver_routes/{trip}` (distance, last position)
- a push of a route point every 5 s or 3 m
- several `setState` calls

**Buttons** (`:3356-3364`):
| Button | Action | Persistence |
|---|---|---|
| START | Creates a trip if none exists, otherwise sets ACTIVE | Firebase only |
| PAUSE | `_updateTripStatus("IDLE")` | Firebase only. IDLE is reused for "GPS lost" too, so a pause can't be told apart from signal loss. |
| FULL | `_showFullConfirmation :4595`. Despite the name, it shows **no confirmation**. Writes status FULL, logs a Firebase event, calls `saveTripHistory` with `route_status FULL`, `full_time`, `weight_kg 5000`, `areas_visited` | The PHP **ignores** `full_time`, `weight_kg`, `weight_type` and `areas_visited` (L1). The request isn't awaited and errors are swallowed. |
| DONE | `_finishTrip :1812`. Marks the Firebase trip COMPLETED, calls `saveTripHistory` with `route_status COMPLETED`, `route_name 'Collection Route'` | Overwrites FULL→COMPLETED and the area list in MySQL. Doesn't send start time, moving/stopped time, stops, points or events (L6). |

**Manual alert** (`:2135`): pushes a `manual_alert` notification and marks the area completed **by area ID**, while GPS detection marks it **by area name** (G10).

**Moving and stopped time:** never computed by the driver app or saved to MySQL. It's calculated later from Firebase route points in `driver_route_history_service.dart:427-559`. When the result is zero, it's replaced with **made-up values of 960 s moving and 480 s stopped** (L7).

**Truck capacity:** fixed at 5,000 kg (`PredictionEngine.truckCapacityKg`, `DriverTrip` default, the PHP defaults, the schema default). Nothing reads per-truck capacity except the analytics fleet-capacity sum, which also defaults to 5,000.

**Sync to admin and residents:** everything goes through `truck_locations` in Firebase. Status changes and positions arrive through the consumers' `onValue` listeners (see H).

---

## F. Resident Dashboard Investigation

- **Registration** (`register.php`): residents are auto-approved. Consent is checked on the server.
- **Guest access:** on the web, the default route is the public GIS map (`StandaloneGisWebScreen`). It reads Firebase and polls `get_locations.php` every 8 s.
- **Live tracking:**
  - `resident_dashboard.dart:269` listens to `truck_locations` (15-minute freshness) and computes the ETA.
  - `resident_track_truck_screen.dart` uses Firebase plus a PHP poll every 8 s that **overwrites** the Firebase data (G3). It also runs a 35 ms pulse timer and drops marker updates.
- **ETA** (`resident_dashboard.dart:361`, `resident_track_truck_screen.dart:1607`): straight-line distance ÷ speed, falling back to 15 km/h, defaulting to 2.5 km when distance is 0. No road routing.
- **Notifications:** full-node `notifications` listener plus `NotificationService` `onChildAdded` on the whole node. Filtered by purok or role in the app.
- **Complaints:**
  - Filing: `file_complaint.php`. It inserts into `purok` and `location` columns, which are **missing from every schema copy in the repo** (B1, needs live verification). It then pushes a Firebase notification.
  - Status list: downloads **every resident's complaints** and filters them in the app (S8).
  - Deletion: also scans the whole Firebase `complaints` and `notifications` nodes.
- **Profile:** `update_user_profile.php`. Any caller can change any resident's name, email or username (S1).

---

## G. Cross-Platform Android/Web Integration

- **Shared:** every screen is shared Dart code. The web and Android builds call the same PHP base URL and the same Firebase database. Both use the **Android** Firebase app ID (`main.dart:41`); no web app is registered.
- **Platform-specific behaviour:**
  - `kIsWeb` changes routing (the web defaults to the public map) and skips the GPS accuracy filter (`:1371`).
  - The route export uses conditional imports (`route_export_web/stub`).
  - The Android manifest declares background location and foreground-service permissions, but **no foreground service is configured** (G5). An `https` intent filter **with no host** offers the app as a handler for every https link (X2).
  - Release builds are signed with the **debug** key (`build.gradle.kts:33`). The application ID is `com.example.garbage_tracking_app`.
- **Same data, different results:**
  - The "online" rule differs between screens (G7).
  - Trip and waste counts differ between Analytics views (L4).
  - Complaint counts differ between Firebase and MySQL (A6).
  - Truck identity is sometimes the truck ID and sometimes the plate number.
- **Visual-only or mock features:** ETA Performance fallback, Prediction Confidence, PDF fallback chart, analytics ETA fallback, `_measuredTodayVolume = 4200` / `_measuredMonthlyVolume = 38600` (declared, never used), ETA card defaults (3.5 min / 100% / 2 visits, shown until a fetch succeeds).

---

## H. Firebase, GPS, and Real-Time Synchronization (delay analysis)

The full path is: GPS fix → `_processNewPosition` → Firebase `truck_locations/{TRUCK}` → each dashboard's `onValue` → filter → marker update. Every delay source below is in the code itself, not the network:

| # | Cause | Evidence |
|---|---|---|
| G1 | **The map throws away updates.** If a Firebase event arrives while the previous marker update is still running, it's discarded rather than queued. A **35 ms timer** also calls `setState` and makes up to 9 async style calls per tick (about 250 platform/JS calls per second), which competes with marker updates and widens the window in which updates get dropped. | `mapbox_view.dart:359` `if (... _isUpdatingMarkers) return;` and `:51-107`. Same guard at `resident_track_truck_screen.dart:757`, `track_trucks_screen.dart:866`, `standalone_gis_web_screen.dart:455`; another pulse timer at `resident_track_truck_screen.dart:209`. |
| G2 | **Full-node listeners on nodes that only grow.** Admin and Analytics listen to all of `driver_routes`, which holds every trip and every route point. Each driver pushes a point every ≤5 s, so every push re-sends the whole tree to every admin client. Every screen listens to the full `notifications` node. The per-trip route listeners re-download the whole route on every point (cost grows with trip length). | `admin_dashboard.dart:557`, `analytics_screen.dart:1607`, `driver_dashboard.dart:1069`, `resident_track_truck_screen.dart:528`, `track_trucks_screen.dart:993`, `view_daily_routes_screen.dart`, `driver_route_history_service.dart:37` (`get()` of the whole node) |
| G3 | **Stale MySQL positions overwrite fresh Firebase ones.** MySQL is written only once, at driver login. The resident track screen polls it every 8 s and runs `_liveLocations.addAll(phpMap)` with the same upper-case truck key, stamping `lastSeen: now`. Markers jump back to the login position, or vanish when PHP reports `is_online=false`. | `driver_dashboard.dart:591` (only `updateLocation` call); `resident_track_truck_screen.dart:78,101-134` |
| G4 | **Late GPS start and duplicate streams.** `_startTracking` waits on `getCurrentPosition(bestForNavigation)` with **no time limit** before subscribing to the stream. It's called from both `_loadUser` and `_startTripSession`, so both calls can pass the cancel step and then both subscribe. One subscription is lost track of: positions get processed twice and written twice. | `driver_dashboard.dart:1331-1353`, `:524`, `:1324`, `:1228` |
| G5 | **No foreground service.** The location settings have no Android foreground-notification config, so updates stop or slow sharply when the driver app is in the background or the screen is off. | `:1349-1352`. The manifest has the permissions, but no service is configured. |
| G6 | **Fake positions get published.** If there's no fix within 2 s at login, a default point is written to Firebase and MySQL. Real fixes outside a bounding box are **replaced** with that same default. | `:538-545`, `:577-603` |
| G7 | **Different "online" windows per screen:** web 30 s, driver map 2 min, admin and track-trucks 3 min, resident and MapboxView 15 min. | `standalone_gis_web_screen.dart:335`, `admin_dashboard.dart:490`, `mapbox_view.dart:345`, `resident_dashboard.dart:326` |
| G8 | **Presence contradicts itself.** After DONE, the heartbeat keeps writing `isOnline: true, status: COMPLETED` every 30 s. `onDisconnect` is only registered for **new** trips, not restored ones. A killed app stays "online" until each screen's freshness window runs out. | `:1771-1778`, `:1272` |
| G10 | **Area key mismatch and an invalid key.** Weekly progress is set up and manually marked **by area ID** (`central_purok_1`), but GPS detection writes **by area name** (`Central (Purok 1)`). The name "T.M. Kalaw Street" contains `.`, which isn't allowed in a Firebase path, so the write likely throws inside `_processNewPosition` **before** the `truck_locations` write. If so, live updates stop while the truck is inside that area. | `:1185`, `:2163`, `:1580`, `:1607`; `service_area_service.dart:302` |
| G11 | **Listeners never cancelled:** `_loadMaintenanceData` (up to 3 times on restore, with copy-pasted lines `:816-826`), `.info/connected` (`:1040`), the MapboxView truck listener (`:326`), and 5 admin listeners (`:202,424,557,579,616`). | Memory and CPU grow over the session; duplicate handlers run. |
| G12 | **Whole-screen rebuilds:** 500 ms clock timers call `setState` on the driver, admin and resident dashboards (3–6.5k-line widget trees). | `driver_dashboard.dart:251`, `admin_dashboard.dart:175`, `resident_dashboard.dart:137` |

**ETA** comes in three versions: the driver's approach notification (fixed 15 km/h), the resident/track-trucks ETA (distance ÷ speed, defaults 15 km/h and 2.5 km), and the analytics ETA (fallback distance `(index+1) × 0.8 km`, A4). None uses road routing or real history.

---

## I. Backend, Database, Authentication, and Security

- **Authentication model:** no tokens or sessions. Every endpoint trusts `user_id` and `role` sent by the client, and CORS is `*` (`db_config.php:8-10`).
- **SQL safety:** queries are prepared statements throughout, and dynamic table and column names come from fixed lists. **I found no classic SQL injection.** The risk is missing authorization, not injection.
- **Error handling:** most endpoints echo `$e->getMessage()`, which leaks schema details. Errors are swallowed in about 61 places (`catch (_) {}` and similar).
- **Schema copies vs. the code:** the newest dump (`auto_backup_2026-08-21.sql`) has 3 users and 8 residents, so it looks like a **development** database. It has **no** `truck_locations`, `driver_trip_history`, `approval_status`, `account_status`, `archived_at` or `profile_picture`. As you asked, I treat every mismatch as **needing live schema verification**, not as proof of a production failure.

---

## J. Load History, Waste Collection, and Analytics

**What's documented:** 5 tons (5,000 kg) per FULL trip, unless an admin enters a measured weight.

**What the code actually does:**
- The FULL timestamp, weight and areas are never saved to MySQL (L1).
- `get_load_history.php` counts FULL, COMPLETED, FINISHED **and ACTIVE** trips, plus legacy `driver_routes` rows, each defaulting to 5,000 kg.
- The client then merges in **every Firebase trip with ≥15 m of movement** (any status, including trips auto-created at login) and the `load_history` node. Each of those also defaults to 5,000 kg (`analytics_screen.dart:1351-1391`, `driver_trip.dart:249,428`).
- Result: **"waste collected" is really "number of trips × 5 t"**, not "FULL events × 5 t". One trip can record only one FULL, and DONE overwrites it.

**Where the numbers diverge (L4):**
| View | Source | Includes ACTIVE? | Includes Firebase-only trips? |
|---|---|---|---|
| Waste Collection Summary card | MySQL period list + Firebase route history + `load_history` | yes | yes |
| Yearly data from the backend | MySQL `driver_trip_history` only | no | no |
| AI load summary | MySQL `driver_trip_history` only | no | no |
| Load History modal (`_LoadHistoryDialogModal`) | `DriverRouteHistoryService` only, single day | depends on filter | yes |

**Load History bar graph: NOT IMPLEMENTED.**
- `get_load_history.php:183-224` returns `yearly_chart.months`.
- `analytics_screen.dart:1347` stores it in `_loadYearlyMonths`.
- Nothing reads `_loadYearlyMonths` afterwards.
- The Load History modal (`:7174-8222`) has no chart; it's a date picker, a summary card and a trip table.
- The only `BarChart` in the file is the area-coverage chart (`:5480`). So the bar graph isn't wrongly placed in Waste Collection Summary — it just doesn't exist anywhere.

**Other analytics problems:**
- **Waste forecast:** area (hard-coded square metres) × 0.0217 kg/m² × holiday multiplier (`prediction_engine.dart:26-45`). The "historical average" reads `weight`/`volume` fields under `collection_progress`, which nothing writes, so it always falls back. "Purok 4 / El Pueblo" doesn't match the key "El Pueblo". The code comment calls it "Simple Linear Regression", but it isn't one.
- **MAE and accuracy:** `_maeValue = avgTime × 0.08 × 60`, or 1.2 when there's no data. Accuracy is 100% when the average is 0 (`analytics_screen.dart:1268-1269`, `prediction_engine.dart:113`). **Fabricated.**
- **ETA Performance** (`get_eta_performance.php`):
  - The "GPS entry" time is start + 40% of trip duration, not a real geofence entry.
  - A difference of 0 is replaced with `(index % 7) − 3`.
  - With no trips, it **generates synthetic visits for all 10 areas**.
  - It queries `notifications.created_at`, a column absent from every schema copy (needs live verification).

---

## K. PDF Reports and Forecasting

`_exportToNativePdf` (`analytics_screen.dart:909-1067`):
- **Charts:**
  - The truck and complaint donut charts use the real state. The order of `_truckStatusData` (Active, Full, Idle) matches the legend.
  - **The area bar chart falls back to hard-coded data** when there's no frequency data: `"Central": 12, "Purok 3": 6`, plus areas that don't exist, "Brixton Area" and "San Isidro". The y-axis is fixed at 0–40, so higher counts get clipped (`:1116-1124`).
- **Text:**
  - The Fleet, Complaint and Coverage insight boxes keep their placeholders ("Analyzing fleet performance patterns...") unless Gemini succeeds. The catch block doesn't reset them (`:736-743`).
  - When Gemini fails, the "Final Executive Conclusion" prints "Unable to generate real-time AI insights...". The model in use is `gemini-1.5-flash-latest` (and `gemini-1.5-flash` in PHP). I believe Google has retired the 1.5 models, so these calls likely fail every time (needs a runtime check).
- **Forecast table:**
  - "Prediction Confidence" = the fabricated accuracy.
  - "Avg Stop Duration (hours)" actually shows average collection time (mislabelled).
  - Volumes come from the heuristic, not from data.
- **Missing:** no Load History or Waste Collection Summary figures appear in the PDF. The footer brand reads "GarbageBiz", which doesn't match the app.
- **Excel/HTML export** (`export_report.php`): every value comes from client-supplied GET parameters and is echoed **without escaping** (`htmlspecialchars` appears 0 times), so anyone can inject content into a "report". `total_drivers` defaults to `'2'`.

---

## L. Confirmed Defects and High-Confidence Risks (detailed)

Each entry gives: **Where · What the code does · Why it's wrong and its impact · Classification · Evidence still needed · Suggested fix (not implemented).**

**S1. No server-side authentication or authorization on any endpoint** (P0)
- **Where:** all of `backend/*.php`, e.g. `delete_user.php`, `approve_user.php`, `update_permissions.php`, `toggle_2fa.php`, `delete_trip.php`, `update_trip_weight.php`, `bulk_delete_complaints.php`, `trigger_backup.php`, `get_users.php`.
- **What it does:** acts on `user_id`/`role` taken from the request body.
- **Why/impact:** anyone can delete or approve accounts, disable 2FA, falsify weights, wipe complaints or trips, and dump the database.
- **Classification:** CONFIRMED SOURCE-CODE DEFECT.
- **Evidence needed:** none for the code. A one-request check against a test account would confirm production behaviour.
- **Fix:** issue a signed session token at login, check it in a shared `auth.php` included by every endpoint, and enforce role checks for each endpoint.

**S2. Anyone can register as an admin** (P0)
- **Where:** `register.php:81-96`.
- **What it does:** `role === 'admin'` is accepted, with `approval_status='approved'`.
- **Classification:** CONFIRMED.
- **Fix:** refuse `admin` at public registration; only an existing admin can create admins.

**S3. Secrets committed to git and shipped in the client** (P0)
- **Where:** `backend/db_config.php` (DB password), `backend/email_config.php` (Gmail app password), `get_ai_load_summary.php:10` and `get_operational_insights.php:12` and `analytics_screen.dart:554` (Gemini key, also inside `public_html/main.dart.js`), `main.dart:35` (Mapbox token), `Asia-repo1-main/backend/db_config.php`.
- **Classification:** CONFIRMED.
- **Fix:** **rotate every one of these credentials**, move them to server environment variables or a config file outside git, remove the Gemini key from the client, restrict the Mapbox token by URL, and scrub git history.

**S4. Full database dumps are web-reachable and committed** (P0)
- **Where:** `trigger_backup.php`, `auto_backup_checker.php` (runs on every login), `get_backup_history.php` (unauthenticated listing with URLs), `backend/backups/*.sql` (33 committed).
- **Impact:** password hashes, emails and phone numbers are exposed.
- **Classification:** CONFIRMED in code. Whether the folder is actually reachable on Hostinger needs verification; there's no `.htaccess` in `backend/`.
- **Fix:** store dumps outside the web root, require admin auth to download, and remove them from git.

**S5. Two-factor login is never enforced** (P0)
- **Where:** `login.php:60-124` returns `success:true, message:"2FA_REQUIRED", user:{...}`. `login_screen.dart:288-319` treats any `success` as logged in. No code navigates to `/verify_2fa`.
- **Classification:** CONFIRMED.
- **Fix:** have the server return `success:false` plus a challenge ID for 2FA accounts and only issue the session after `verify_otp`; route the client to `/verify_2fa`.

**S6. Driver approval workflow doesn't work** (P0/P1)
- **Where:**
  - `register.php:83-84` sets `approval_status='pending'` but `is_archived=0`.
  - `login.php:45,51` checks only `is_archived` (and doesn't select `approval_status`).
  - `get_users.php:22` doesn't return `approval_status`, so `user_management_screen.dart:42` never finds a pending user.
  - `approve_user.php:20` only sets `is_archived=0`.
  - Rejection isn't enforced at login.
- **Impact:** pending and rejected drivers can log in; admins never see anything to approve.
- **Classification:** CONFIRMED (whether the columns exist needs live verification).
- **Fix:** one lifecycle field, checked at login, returned by `get_users`, and set by approve/reject.

**S7. Firebase database has no authentication** (P0)
- **Where:** no Firebase Auth anywhere. PHP posts to `notifications.json` without credentials (`register.php:15`, `notify_admin_issue.php:17`). The login lockout lives in Firebase `login_security` (`login_security_manager.dart`).
- **Impact:** if the rules are open (which those REST writes suggest), anyone can rewrite truck positions or notifications or clear lockouts. The lockout is also client-side only; calling `login.php` directly skips it.
- **Classification:** HIGH-CONFIDENCE RISK.
- **Evidence needed:** the Firebase console security rules (not in the repo).
- **Fix:** add Firebase Auth (custom tokens issued by PHP) and per-node rules; enforce the lockout in `login.php`.

**S8. Any caller can read every resident's complaints** (P0/P1, privacy)
- **Where:** `get_complaints.php` returns all complaints with resident names; `resident_complaints_screen.dart:198-204` filters in the app.
- **Classification:** CONFIRMED.
- **Fix:** filter on the server by the authenticated resident.

**D1. Trip history is permanently deleted past 200 trips per month** (P0, data integrity)
- **Where:** `save_trip_history.php:111-144`.
- **What it does:** keeps the newest 200 finished trips per calendar month across **all** drivers and deletes the rest, with their GPS points and events.
- **Impact:** Load History, monthly and annual statistics and route history silently lose data.
- **Classification:** CONFIRMED.
- **Fix:** remove the purge or archive instead; decide retention explicitly.

**D2. Forgot-password can never succeed** (P1)
- **Where:** `verify_otp.php:24` deletes the token; `reset_password_final.php:20-28` then requires that same token, so the client flow (`forgot_password_screen.dart:790-830`) always gets "Security verification failed". Separately, `notify_password_change.php:5-7` requires `PHPMailer/src/...`, which doesn't exist, and line 78 has a PHP syntax error (`error_log(\"...`). Both would be fatal if that code were reached.
- **Classification:** CONFIRMED.
- **Fix:** don't consume the token in the verify step (or issue a one-time reset token instead); fix the include path and syntax.

**G1–G12:** see the table in section H. Classifications: G1, G2, G3, G6, G7, G8, G11 CONFIRMED (code); G4, G5, G10 (the throw behaviour) HIGH-CONFIDENCE; G12 CONFIRMED (P2). Suggested fixes:
- G1: queue the latest payload instead of discarding it; remove or slow the 35 ms pulse (use a style transition or a ≥500 ms interval).
- G2: listen to `driver_routes` with `orderByChild('date').equalTo(today)` or a small summary node; use `onChildAdded` for route points; use `limitToLast` for notifications.
- G3: stop merging PHP into Firebase data, or only use PHP when Firebase is unavailable and prefer the newer timestamp.
- G4: add a `timeLimit` and make tracking start exactly once.
- G5: `AndroidSettings(foregroundNotificationConfig: ...)`.
- G6: never publish default coordinates; leave out lat/lng until a real fix exists.
- G7: one shared freshness constant and helper.
- G8: stop the heartbeat after DONE; register `onDisconnect` on restore too.
- G10: always key by area ID.
- G11: store and cancel every subscription.
- G12: move the clock into its own small widget.

**G9. A trip starts automatically at every login** (P1)
- **Where:** `driver_dashboard.dart:839-841`.
- **Impact:** trips aren't tied to START; Firebase-derived trip counts and Load History grow.
- **Classification:** CONFIRMED.
- **Fix:** only create a trip on START.

**L1. The FULL event isn't saved** (P1)
- **Where:** `save_trip_history.php:42-65`. Its insert and update lists leave out `full_time`, `weight_kg`, `weight_type` and `areas_visited`, which the client sends at `driver_dashboard.dart:4622-4636`. DONE later overwrites `route_status` and `route_name`. One trip ID means only one FULL per trip.
- **Classification:** CONFIRMED.
- **Fix:** save those columns; record each FULL as its own load record (e.g. a `trip_loads` table, or a per-FULL ID); don't let DONE overwrite them.

**L2. Load and waste totals count every trip, not FULL events** (P1)
- **Where:** `get_load_history.php:35,64`; `analytics_screen.dart:1351-1391`; `driver_trip.dart:249`.
- **Classification:** CONFIRMED.
- **Fix:** count only real FULL events (or measured weights); remove the client-side merge of Firebase trips into the totals.

**L5. `get_load_history.php` may fail outright** (P1 if true)
- **Where:** `:75` selects `dr.driver_name` from `driver_routes`, a column absent from every schema copy. If `driver_routes` exists without it, the whole endpoint returns `success:false`.
- **Classification:** HIGH-CONFIDENCE RISK (needs live schema verification).

**A1. ETA Performance data is synthetic** (P1, integrity)
- **Where:** `get_eta_performance.php:105-121,141-204,227`.
- **Classification:** INCOMPLETE OR MOCK IMPLEMENTATION.
- **Fix:** record real geofence entry times (the driver already detects them) next to the ETA that was announced; show "insufficient data" instead of generating values.

**A2. Prediction confidence and MAE are fabricated** (P1)
- **Where:** `analytics_screen.dart:1268-1269`; PDF row at `:1015`.
- **Classification:** CONFIRMED / MOCK.
- **Fix:** compute MAE from saved predictions vs. actuals, or hide the metric.

**K1/K2. PDF uses hard-coded fallback data and placeholder text** (P1)
- **Where:** `analytics_screen.dart:1117-1119`, `:160-162`, `:736-743`; outdated Gemini model.
- **Classification:** CONFIRMED.
- **Fix:** render "No data for this period"; leave out AI sections when generation fails; update the model name.

**X1. Notifications may start before Firebase is ready** (P2)
- **Where:** `main.dart:31-46`. `startPersistentListening()` isn't awaited and touches `FirebaseDatabase.instance` after async SharedPreferences reads, possibly before `Firebase.initializeApp` finishes.
- **Classification:** HIGH-CONFIDENCE RISK (an intermittent cold-start error or missing notifications).
- **Fix:** initialize Firebase first.

---

## M. Incomplete Features, Mock Data, and Unverified Assumptions

- **Mock or fabricated:**
  - ETA Performance synthetic records and jitter (A1)
  - Prediction confidence and MAE (A2)
  - PDF fallback bar data (K1)
  - Analytics ETA fallback distances (A4)
  - Moving/stopped time fallbacks of 960 s / 480 s (L7)
  - ETA card defaults of 3.5 min / 100% / 2 visits
  - `_tomorrowWaste = 5000`, `_weeklyWaste = 15000` until computed
  - `_selectedTruckSummary = "GT-007"`
  - Unused `_measuredTodayVolume` / `_measuredMonthlyVolume`
- **Not implemented:**
  - Load History bar graph (L3)
  - FULL-event persistence (L1)
  - Trip start/moving/stopped/points/events saved to MySQL (L6)
  - Route optimization PHP proxy (`route_optimization.php` isn't in the repo)
  - Server-side permissions enforcement
  - Web-side driver GPS reliability (web `speed` values)
- **Simulation leaks into production data (G13, P2):** simulation positions go to the real `truck_locations`, real notifications and real weekly progress. FULL/DONE saves never send `is_simulation`, so the PHP filter at `save_trip_history.php:13` never triggers.
- **Unused code:**
  - `ApiService` methods with no callers: `getOperationalInsights`, `getTripDetails`, `notifyAdminIssue`, `updateResidentData`, `checkAvailability` (its endpoint doesn't exist), `triggerSchemaDebug`, `exportComplaintsReport`
  - Unused screen and service: `DataManagementScreen`, `GeofenceService`
  - The legacy Kotlin directories

---

## N. Prioritized P0–P3 Issue Register

| ID | P | Title | Classification |
|---|---|---|---|
| S1 | P0 | No auth or authorization on PHP endpoints | CONFIRMED |
| S2 | P0 | Public admin self-registration | CONFIRMED |
| S3 | P0 | Secrets committed and shipped in the web bundle | CONFIRMED |
| S4 | P0 | Full SQL dumps in web dir and git; unauthenticated listing | CONFIRMED (host config to verify) |
| S5 | P0 | 2FA bypass | CONFIRMED |
| S7 | P0 | Firebase has no auth; lockout is client-only | HIGH-CONFIDENCE |
| S8 | P0 | All complaints readable by any caller | CONFIRMED |
| D1 | P0 | Monthly 200-trip purge deletes history | CONFIRMED |
| S6 | P1 | Driver approval workflow non-functional | CONFIRMED (schema to verify) |
| D2 | P1 | Forgot-password always fails | CONFIRMED |
| G1 | P1 | Map drops updates plus 35 ms pulse flood | CONFIRMED |
| G2 | P1 | Full-node listeners on growing nodes | CONFIRMED |
| G3 | P1 | Stale MySQL positions overwrite Firebase (resident map) | CONFIRMED |
| G4 | P1 | Late or duplicate GPS subscriptions | HIGH-CONFIDENCE |
| G5 | P1 | No foreground location service | HIGH-CONFIDENCE |
| G6 | P1 | Default or replaced coordinates published as live | CONFIRMED |
| G9 | P1 | Trip auto-created on every login | CONFIRMED |
| G10 | P1 | Area key mismatch; '.' in key may stop live writes | CONFIRMED / HIGH-CONFIDENCE |
| L1 | P1 | FULL time, weight and areas not saved; DONE overwrites | CONFIRMED |
| L2 | P1 | Waste = trips × 5 t, not FULL events | CONFIRMED |
| L5 | P1 | `get_load_history` may fail on `dr.driver_name` | Needs live schema check |
| A1 | P1 | ETA Performance synthetic data | MOCK |
| A2 | P1 | Fabricated prediction confidence and MAE | CONFIRMED |
| K1 | P1 | PDF fake fallback chart data | CONFIRMED |
| K2 | P1 | PDF placeholder or failed-AI text; outdated Gemini model | CONFIRMED / HIGH-CONFIDENCE |
| B1 | P1 | Columns absent from every schema copy: `users.id`, `users.plate_number`, `truck_locations.driver_id`, `complaints.purok/location`, `notifications.created_at`, `driver_routes.driver_name`, `profile_picture`, lifecycle columns. Could break `update_location`, `get_locations`, `file_complaint`, `get_eta_performance` | Needs live schema check |
| G7 | P2 | Inconsistent online windows (30 s – 15 min) | CONFIRMED |
| G8 | P2 | Heartbeat re-marks online after DONE; no onDisconnect on restore | CONFIRMED |
| G11 | P2 | Leaked listeners | CONFIRMED |
| G13 | P2 | Simulation writes to production data | CONFIRMED |
| L3 | P2 | Load History bar graph not rendered | CONFIRMED |
| L4 | P2 | Different totals across analytics views | CONFIRMED |
| L6 | P2 | Trip start and durations not sent; "h:mm a" or "--:--" start time sent to PHP | CONFIRMED |
| L7 | P2 | 960 s / 480 s fallback durations | CONFIRMED |
| A3 | P2 | Forecast is assumption-only; key mismatches | CONFIRMED |
| A4 | P2 | Synthetic analytics ETA; hard-coded area coordinates | CONFIRMED |
| A5 | P2 | "Routes today"/coverage counts all trips ever | CONFIRMED |
| A6 | P2 | Complaint counts from Firebase and MySQL overwrite each other | HIGH-CONFIDENCE |
| K4 | P2 | `export_report.php` unescaped GET-param report | CONFIRMED |
| B4 | P2 | Web-callable schema-altering scripts (`debug_schema.php`, `apply_db_changes.php`, `update_load_history_schema.php`; `archive_complaint.php` runs ALTER on each call; `get_users.php` hard-deletes on each read) | CONFIRMED |
| B6 | P2 | OTP: `mt_rand`, no attempt limit, shared table for reset and 2FA, email enumeration, "3 min" text vs 5 min expiry | CONFIRMED |
| B7 | P2 | Profile upload: extension-only check, 0777 dir, any user ID | CONFIRMED |
| X1 | P2 | Notification listener may start before Firebase init | HIGH-CONFIDENCE |
| G12 | P2 | 500 ms whole-screen clock rebuilds | CONFIRMED |
| B2 | P2 | `update_location` ON DUPLICATE KEY likely never matches (no unique key in `setup_logs.sql`) | Needs live schema check |
| K3 | P3 | PDF mislabels ("Avg Stop Duration"), no Load History section, "GarbageBiz" brand | CONFIRMED |
| K5 | P3 | `get_operational_insights.php` `COUNT(c.id)`; unused | CONFIRMED |
| B3 | P3 | Unescaped HTML in admin emails | CONFIRMED |
| B5 | P3 | DB exception text returned to clients | CONFIRMED |
| B8 | P3 | Hard deletes without cleaning up dependent rows | CONFIRMED |
| X2 | P3 | Hostless https intent filter; debug signing; `com.example` ID | CONFIRMED |
| X3 | P3 | Web uses the Android Firebase app ID | CONFIRMED |
| X4 | P3 | Legacy dirs, `.bak`, unused services and API methods, failing template test, outdated `integration_spec.md`, truck ID vs plate inconsistency in route points | CONFIRMED |

---

## O. Recommended Investigation and Repair Sequence

1. **Contain exposure (no feature risk):** rotate the database, SMTP, Gemini and Mapbox credentials; restrict Mapbox by URL; take `backups/` off the web root; delete the debug and migration endpoints from the server; remove dumps and secrets from git (S3, S4, B4).
2. **Verify the live schema** (read-only, through phpMyAdmin): run `SHOW CREATE TABLE` for `users`, `residents`, `complaints`, `notifications`, `driver_routes`, `driver_trip_history`, `truck_locations`. This settles B1, L5, B2 and S6 before any code changes.
3. **Stop data loss:** remove the 200-trip purge (D1).
4. **Authentication layer:** server session token plus role checks; block admin self-registration; real 2FA; working approval lifecycle; resident-scoped complaints; Firebase Auth and rules (S1, S2, S5, S6, S7, S8). This is the biggest piece of work. Do it endpoint by endpoint so the working app keeps running.
5. **GPS delay fixes,** low risk and high value, in this order: G3 (stop the PHP overwrite), G1 (queue, slow the pulse), G2 (scope the listeners), G4/G5 (tracking start and foreground service), G6, G10, G8, G7, G11.
6. **Load and waste correctness:** save FULL events properly, one record per FULL (L1); count only FULL or measured loads (L2); single source of truth (L4); send real start and duration fields (L6); remove fabricated fallbacks (L7); stop auto-creating trips (G9); isolate simulation (G13).
7. **Analytics integrity:** remove or replace the synthetic ETA, MAE and confidence values and the PDF fallback data; show "insufficient data" states (A1, A2, K1, K2, A3–A5).
8. **Build the Load History bar graph** from `_loadYearlyMonths` once L1/L2 make the data meaningful (L3).
9. **Fix forgot-password** (D2). It can go earlier if it's needed for your defense or demo.
10. **P3 clean-up** last.

---

## P. Areas Requiring Runtime Testing or Production Schema Verification

- **Live MySQL schema** (step 2 above), especially whether `update_location.php` and `get_locations.php` succeed at all, given `users.id`, `u.plate_number` and `tl.driver_id`.
- **Firebase security rules** and the current size of `driver_routes` and `notifications`. Payload size directly drives G2 delays.
- **Hostinger:** is `backend/backups/*.sql` downloadable? Is `display_errors` on?
- **Runtime GPS checks:**
  - Whether the driver's 'T.M. Kalaw Street' geofence write throws (G10).
  - Whether duplicate position subscriptions happen (G4); look for double `[FIREBASE LIVE LOCATION WRITE]` log lines.
  - How updates behave with the screen off on Android 12+ (G5).
  - How long from fix to marker on the admin map with and without the pulse timer (G1).
- **Gemini model availability** for `gemini-1.5-flash(-latest)`.
- **Web driver** `speed` values (does distance accumulate?).
- **2FA toggle** display (string vs. integer comparison).
- **Whether `route_optimization.php`** exists on the server.

---

## Q. Overall System Readiness Assessment

| Area | Assessment |
|---|---|
| Live GPS tracking | Built end to end; delays come from specific code patterns (H). Demo-capable. |
| Driver operations | START/PAUSE/DONE work against Firebase. FULL isn't reliably saved. Trips auto-start at login. |
| Resident features | Tracking, notifications and complaint filing exist. Complaint filing depends on columns that need verifying. Privacy leak. |
| Admin management | The UI exists. Approval is broken, and none of it is protected on the server. |
| Analytics and reports | Several metrics are fabricated or rest only on assumptions; the PDF can contain fake data; the Load History bar graph is missing. **Not defensible as-is.** |
| Security | **Not acceptable for any public deployment** (P0 × 8). |
| Code health | Very large single-file screens, four copies of the map and marker logic, about 61 swallowed errors, leaked listeners, no meaningful tests. |

**Overall:** works as a prototype or demo. Not production-ready. The core idea and data flows are sound and worth keeping; the fixes are targeted, not a rewrite.

---

### Coverage statement (what was and wasn't inspected)

- **Read in full:**
  - `main.dart`, `api/*`, `session_manager.dart`, `models/user.dart`, `login_security_manager.dart`, `prediction_engine.dart`, `widgets/mapbox_view.dart`
  - All PHP endpoints in `backend/` except the PHPMailer library; `export_report.php` (grep only) and `export_complaints_report.php` (not read)
  - All SQL and migration scripts; the structure (not data) of two backup dumps
  - `AndroidManifest.xml`, `pubspec.yaml`, `web/index.html`
- **Read in part (targeted sections):**
  - `driver_dashboard.dart`: lines 1–2180 and 3340–3372, 4590–4665 (the lifecycle, GPS, trip and status logic)
  - `admin_dashboard.dart`: 100–660
  - `analytics_screen.dart`: 519–1180, 1209–1610, 1671–1710, plus a grep outline of the rest
  - The PHP-sync and merge sections of `resident_track_truck_screen.dart`, `track_trucks_screen.dart` and `standalone_gis_web_screen.dart`
  - Parts of `driver_route_history_service.dart`, `service_area_service.dart`, `truck_assignment_service.dart`, `notification_service.dart`, `login_screen.dart`, `forgot_password_screen.dart` and `resident_complaints_screen.dart`
- **Grep-scanned only, or not reviewed:**
  - The three settings screens, the register screens, `complaints_screen.dart`, `route_history_screen.dart`, `user_management_screen.dart` (beyond the approval logic), `resident_dashboard.dart` UI, `driver_track_truck_screen.dart`, `route_optimization_service.dart` internals, `data_management_modal.dart`, localization and legal text
  - The legacy Kotlin directories, the compiled `public_html/main.dart.js` (only checked for embedded keys), and the iOS/Linux/Windows platform folders
- **Not run:** no builds, tests or network calls. Every behaviour above is inferred from source and has **not** been verified at runtime.
