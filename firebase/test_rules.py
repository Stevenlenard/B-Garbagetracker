"""Tests firebase/database.rules.json in the local RTDB emulator, seeded with the real data backup.

Every read/write the app (and the PHP backend) performs must be ALLOWED; whole-database and
whole-collection reads/wipes and unknown nodes must be DENIED. Exit code 1 on any mismatch.
"""
import json, sys, urllib.request, urllib.error, urllib.parse

BASE = 'http://127.0.0.1:9010'
NS = 'garbagesis-78d39-default-rtdb'
RULES = sys.argv[1]
SEED = sys.argv[2]


def req(method, path, body=None, owner=False, query=None):
    q = {'ns': NS}
    q.update(query or {})
    p = path.strip('/')
    url = (f"{BASE}/{p}.json?" if p else f"{BASE}/.json?") + urllib.parse.urlencode(q)
    data = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header('Content-Type', 'application/json')
    if owner:
        r.add_header('Authorization', 'Bearer owner')
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


# --- load rules + seed (as owner, rules bypassed) ---
st, b = req('PUT', '.settings/rules', json.load(open(RULES, encoding='utf-8')), owner=True)
assert st == 200, ('rules', st, b[:300])
seed = json.load(open(SEED, encoding='utf-8'))
st, b = req('PUT', '', seed, owner=True)
assert st == 200, ('seed', st, b[:200])

trip = next(iter(seed['driver_routes']))
purok = next(iter(seed['puroks']))
notif = next(iter(seed['notifications']))
issue = next(iter(seed['truck_issues']))
log = next(iter(seed['system_logs']))
lsec = next(iter(seed['login_security']))
inbox = next(iter(seed['notification_inbox']))
week = next(iter(seed['weekly_collection_progress']))
truck = next(iter(seed['truck_locations']))
truck2 = next(iter(seed['trucks']))
user = next(iter(seed['users']))
resident = next(iter(seed['residents']))
dset = next(iter(seed['driver_settings']))
dsess = next(iter(seed['driver_sessions']))
lh = next(iter(seed.get('load_history') or {'t1': {}}))
TS = {'.sv': 'timestamp'}

ALLOW = [
    # reads the app performs
    ('GET', 'truck_locations', None, None), ('GET', 'trucks', None, None), ('GET', 'puroks', None, None),
    ('GET', 'users', None, None), ('GET', 'notifications', None, None),
    ('GET', 'notifications', None, {'orderBy': '"$key"', 'limitToLast': '1'}),
    ('GET', 'system_logs', None, {'orderBy': '"$key"', 'limitToLast': '10'}),
    ('GET', 'system_logs', None, {'orderBy': '"timestamp"', 'endAt': '1700000000000'}),
    ('GET', 'collection_logs', None, {'orderBy': '"date"', 'startAt': '"2026-10-01"', 'endAt': '"2026-10-16"'}),
    ('GET', 'collection_logs', None, {'orderBy': '"date"', 'equalTo': '"2026-10-13"'}),
    ('GET', 'driver_routes', None, {'orderBy': '"driver_id"', 'equalTo': '"7"'}),
    ('GET', 'driver_routes', None, {'orderBy': '"driver_id"', 'equalTo': '7'}),
    ('GET', 'driver_routes', None, {'orderBy': '"$key"', 'startAt': '"-O"', 'endAt': '"-Z"'}),
    ('GET', f'driver_routes/{trip}', None, None), ('GET', f'driver_routes/{trip}/isFinished', None, None),
    ('GET', 'simulation_routes', None, None), ('GET', 'collection_progress', None, None),
    ('GET', 'complaints', None, None), ('GET', 'truck_issues', None, None), ('GET', 'load_history', None, None),
    ('GET', 'weekly_collection_progress', None, None), ('GET', 'admin_settings', None, None),
    ('GET', 'admin_settings/auto_backup', None, None), ('GET', 'collection_schedule', None, None),
    ('GET', f'residents/{resident}', None, None), ('GET', f'residents/{resident}/settings', None, None),
    ('GET', f'driver_settings/{dset}', None, None), ('GET', f'login_security/{lsec}', None, None),
    ('GET', f'notification_inbox/{inbox}', None, None), ('GET', f'driver_sessions/{dsess}', None, None),
    ('GET', f'trucks/{truck2}/maintenance', None, None), ('GET', f'users/{user}', None, None),
    # writes the app performs
    ('PATCH', f'truck_locations/{truck}', {'latitude': 13.94, 'longitude': 121.16, 'lastUpdated': TS}, None),
    ('PUT', f'truck_locations/{truck}/current_session', {'id': 'x'}, None),
    ('PATCH', f'users/{user}', {'isOnline': True, 'lastSeen': TS}, None),
    ('PATCH', f'users/{user}', {'profile_picture': None}, None),
    ('PATCH', f'users/{user}', {'current_trip_id': None}, None),
    ('POST', 'notifications', {'type': 't', 'title': 'x', 'message': 'y', 'timestamp': TS}, None),
    ('PUT', 'notifications/arrival_test_key', {'type': 'arrival', 'title': 'x'}, None),
    ('DELETE', 'notifications/arrival_test_key', None, None),
    ('DELETE', f'notifications/{notif}', None, None),
    ('POST', 'truck_issues', {'issue': 'flat tire'}, None), ('DELETE', f'truck_issues/{issue}', None, None),
    ('PATCH', f'truck_issues/{next(iter(list(seed["truck_issues"])[1:]), issue)}', {'status': 'resolved'}, None),
    ('POST', 'system_logs', {'action': 'LOGIN', 'timestamp': TS}, None), ('DELETE', f'system_logs/{log}', None, None),
    ('POST', 'collection_logs', {'date': '2026-10-16', 'purok': 'x'}, None),
    ('PATCH', f'puroks/{purok}', {'lastCollected': TS}, None),
    ('PUT', 'puroks/test_new_area', {'name': 'Test', 'lat': 1, 'lng': 2}, None),
    ('DELETE', 'puroks/test_new_area', None, None),
    ('PUT', 'puroks', seed['puroks'], None),  # "Reset Balintawak Defaults"
    ('PUT', 'collection_schedule/central_purok_1', {'area': 'Central (Purok 1)', 'days': [1, 4]}, None),
    ('DELETE', 'collection_schedule/central_purok_1', None, None),
    ('PATCH', 'admin_settings', {'two_factor': False}, None), ('PUT', 'admin_settings/auto_backup', True, None),
    ('PUT', 'residents/99999', {'name': 'New Resident', 'purok': 'Central'}, None),
    ('PATCH', f'residents/{resident}/settings', {'notifications': True}, None),
    ('PATCH', f'residents/{resident}', {'profile_picture': None}, None),
    ('PATCH', f'driver_settings/{dset}', {'gps_mode': 'high'}, None),
    ('PUT', 'login_security/test_acct', {'attempts': 1}, None), ('DELETE', 'login_security/test_acct', None, None),
    ('PATCH', f'notification_inbox/{inbox}', {'dismissed/abc': True, 'read/abc': True}, None),
    ('PATCH', f'notification_inbox/{inbox}', {'dismissed/abc': None}, None),
    ('PATCH', 'notification_inbox/resident_99999', {'cleared_before_ms': 1}, None),
    ('PUT', f'driver_sessions/{dsess}', {'owner_token': 't', 'epoch': 2}, None),
    ('DELETE', 'driver_sessions/99999', None, None),
    ('POST', 'driver_routes', {'driver_id': '7', 'truck_id': 'GT-007', 'startTime': TS}, None),
    ('PATCH', f'driver_routes/{trip}', {'status': 'COMPLETED', 'endTime': TS}, None),
    ('POST', f'driver_routes/{trip}/route', {'lat': 13.9, 'lng': 121.1, 't': TS}, None),
    ('POST', f'driver_routes/{trip}/events', {'type': 'FULL'}, None),
    ('PUT', f'driver_routes/{trip}/optimized_route', {'stops': []}, None),
    ('PUT', f'driver_routes/{trip}/isFinished', True, None),
    ('POST', 'simulation_routes', {'driver_id': '7'}, None),
    ('PATCH', f'load_history/{lh}', {'weight_kg': 100}, None),
    ('PATCH', f'weekly_collection_progress/{week}/7/areas/central', {'visited': True}, None),
    ('PATCH', f'trucks/{truck2}/maintenance/oil', {'status': 'NORMAL', 'remainingKm': 5000}, None),
    ('PATCH', f'trucks/{truck2}', {'plateNumber': seed['trucks'][truck2].get('plateNumber', 'X')}, None),
    ('DELETE', f'driver_routes/{trip}', None, None),  # driver/admin deletes a trip trace
]

DENY = [
    ('GET', '', None, None), ('GET', '', None, {'shallow': 'true'}),
    ('PUT', '', {'x': 1}, None), ('DELETE', '', None, None), ('PATCH', '', {'junk/x': 1}, None),
    ('DELETE', 'notifications', None, None), ('PUT', 'notifications', {}, None),
    ('DELETE', 'users', None, None), ('DELETE', f'users/{user}', None, None),
    ('DELETE', 'truck_locations', None, None), ('DELETE', f'truck_locations/{truck}', None, None),
    ('DELETE', 'trucks', None, None), ('DELETE', f'trucks/{truck2}', None, None),
    ('DELETE', 'driver_routes', None, None), ('DELETE', 'system_logs', None, None),
    ('DELETE', 'puroks', None, None), ('PUT', 'puroks', 'x', None),
    ('DELETE', 'load_history', None, None), ('DELETE', f'load_history/{lh}', None, None),
    ('DELETE', f'collection_logs/{next(iter(seed["collection_logs"]))}', None, None),
    ('DELETE', 'weekly_collection_progress', None, None), ('DELETE', f'weekly_collection_progress/{week}', None, None),
    ('DELETE', 'admin_settings', None, None), ('DELETE', 'admin_settings/auto_backup', None, None),
    ('PUT', 'collection_progress/x', {'a': 1}, None),
    ('GET', 'residents', None, None), ('DELETE', f'residents/{resident}', None, None),
    ('GET', 'login_security', None, None), ('GET', 'driver_sessions', None, None),
    ('GET', 'notification_inbox', None, None), ('GET', 'driver_settings', None, None),
    ('PUT', 'evil_node/x', {'a': 1}, None), ('GET', 'evil_node', None, None),
] + [(m, n, b, None) for n in ['alerts', 'demo_simulations', 'manual_alerts', 'resident_locations', 'trip_history', 'user_evaluations', 'user_ratings']
     for (m, b) in [('GET', None), ('PUT', {'x': 1})]]

fail = 0
for expect, cases in (('ALLOW', ALLOW), ('DENY', DENY)):
    for m, p, b, q in cases:
        st, body = req(m, p, b, query=q)
        ok = (st == 200) if expect == 'ALLOW' else (st in (401, 403))
        if not ok:
            fail += 1
            print(f'MISMATCH expected {expect}: {m} /{p} {q or ""} -> {st} {body[:160]!r}')
print(f'{len(ALLOW)} allowed-cases, {len(DENY)} denied-cases, {fail} mismatches')
sys.exit(1 if fail else 0)
