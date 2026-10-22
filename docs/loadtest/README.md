# Load test (Apache JMeter 5.6.3)

Date: 2026-10-22, 11:01–11:05 (Asia/Manila), against the live site https://indigo-bear-885857.hostingersite.com (Hostinger shared hosting), run from one Windows PC on the team's home internet connection.

## What was tested

`gt_load_test.jmx` simulates visitors of the public website. Each virtual user:

1. opens the website once: `index.html`, `flutter_bootstrap.js` and the app itself, `main.dart.js` (1.8 MB compressed), as a browser does before caching them;
2. then keeps reloading `index.html` and asking the backend for the public fleet counts (`backend/get_public_stats.php`, a MySQL query), waiting 1–3 s between requests (think time).

The test only reads: nobody signs in, nothing is saved, no personal data is requested. The load was raised step by step (10, 25, then 50 concurrent users, 60 s each, ramp-up 10/15/20 s), checking the error rate after each step; a 100-user step (ramp-up 30 s) was run afterwards.

Not covered: the live GPS updates and maps, which go directly from the app to Firebase Realtime Database (Google-hosted) and not through the Hostinger server.

## Results

| Concurrent users | Requests | Throughput (req/s) | Avg response (ms) | 90th pct (ms) | 95th pct (ms) | Max (ms) | Errors |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 | 251 | 4.3 | 140 | 138 | 323 | 906 | 0 % |
| 25 | 611 | 10.4 | 133 | 150 | 220 | 762 | 0 % |
| 50 | 1,145 | 19.5 | 137 | 164 | 266 | 1,210 | 0 % |
| 100 (run at 11:12) | 2,038 | 35.2 | 164 | 209 | 429 | 4,329 | 5.4 % |

Per request at 50 concurrent users:

| Request | Samples | Avg (ms) | 95th pct (ms) | Errors |
|---|---:|---:|---:|---:|
| Open website (index.html) | 50 | 239 | 459 | 0 % |
| Load flutter_bootstrap.js | 50 | 108 | 115 | 0 % |
| Download app (main.dart.js, 1.8 MB) | 50 | 463 | 616 | 0 % |
| Public fleet counts (get_public_stats.php) | 510 | 124 | 134 | 0 % |
| Reload website (index.html) | 485 | 110 | 121 | 0 % |

## 100 concurrent users

All website files were still served without errors (index.html, flutter_bootstrap.js, main.dart.js: 0 %). The errors (110 of 2,038 requests, 5.4 %) were all on the database endpoint `get_public_stats.php` (12 % of its 897 calls). They started once all 100 users were active (from about 20 s into the step): the replies were the backend's database connection error, consistent with the shared-hosting limit on simultaneous MySQL connections per account, since every PHP request opens its own connection. The average response time stayed low (0.16 s); the first app download slowed to 0.74 s on average (1.7 s at the 95th percentile). The site answered normally right after the step.

So, on the current shared hosting plan, the backend works without errors up to at least 50 concurrent users; at 100 concurrent users, about 1 in 8 database requests is refused because of the connection limit.

## Reading the results

- No request failed in the 10, 25 and 50-user steps (0 % errors in 2,007 requests).
- Throughput grew with the number of users (4.3 → 10.4 → 19.5 requests per second) while the average response time stayed at about 0.13–0.14 s, so the server was not saturated at 50 concurrent users.
- The database endpoint answered in about 0.12 s on average at every step.
- The first download of the whole app took about 0.46 s on average; later visits reuse the browser cache.
- The site answered normally right after each step.

Limits: one client machine and one internet connection; the results include that connection's speed. 50 concurrent users is above the number of people expected to open the public page at the same moment in Barangay Balintawak.

## Files

- `gt_load_test.jmx` – the JMeter test plan (open with JMeter, or run without the GUI:
  `jmeter -n -t gt_load_test.jmx -Jusers=50 -Jramp=20 -Jduration=60 -l results_50.jtl -e -o report_50`)
- `reports/users_10`, `reports/users_25`, `reports/users_50`, `reports/users_100` – JMeter HTML dashboards (open `index.html`)
- `reports/results_*.jtl` – raw results (CSV)
