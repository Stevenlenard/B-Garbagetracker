import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/utils/gps_quality.dart';
import 'package:garbage_tracking_app/utils/route_geometry.dart';
import 'package:garbage_tracking_app/utils/stationary_excursion.dart';

/// The 3 Nov 2026 trip: a phone carried from BSU to an apartment (about 430 m) and then left in it for hours, recorded by
/// the driver app. The recorder saved 791 fixes and 7.2 km although the phone never left the apartment after 10:33; the
/// Route History showed a web of lines. These tests run on those REAL fixes (metres from the first fix; the real location
/// is not stored), not on a synthetic simulation: the earlier simulation gave the stationary fixes a receiver speed of 0,
/// which a real indoor receiver does not (it reports 10-25 km/h during the bursts), so it never produced the failure.
void main() {
  const double lat0 = 13.95, lng0 = 121.16;
  final double kLng = math.cos(lat0 * math.pi / 180);
  final int base = DateTime(2026, 11, 3, 10, 3, 11).millisecondsSinceEpoch;

  final Map<String, dynamic> fixture = jsonDecode(File('test/fixtures/nov3_stationary_trip.json').readAsStringSync()) as Map<String, dynamic>;
  final List<List<num>> fx = <List<num>>[for (final dynamic r in fixture['fixes'] as List) (r as List).cast<num>()];

  GpsPoint point(List<num> r) => GpsPoint(
        latitude: lat0 + r[2] / 111320,
        longitude: lng0 + r[1] / (111320 * kLng),
        accuracyM: r[3].toDouble(),
        speedKmh: r[4].toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(base + r[0].toInt()),
      );

  final List<GpsPoint> raw = <GpsPoint>[for (final List<num> r in fx) point(r)];

  double length(Iterable<GpsPoint> pts) {
    double m = 0;
    GpsPoint? prev;
    for (final GpsPoint p in pts) {
      if (prev != null) m += gpsDistanceM(prev.latitude, prev.longitude, p.latitude, p.longitude);
      prev = p;
    }
    return m;
  }

  int bigSteps(List<GpsPoint> pts) {
    int n = 0;
    for (int i = 1; i < pts.length; i++) {
      if (gpsDistanceM(pts[i - 1].latitude, pts[i - 1].longitude, pts[i].latitude, pts[i].longitude) > 40) n++;
    }
    return n;
  }

  group('3 Nov 2026 trip (real fixes)', () {
    final List<GpsPoint> fixed = RouteJitter.collapse(raw);

    test('the data is what was recorded: 791 good-accuracy fixes and about 7.4 km of line', () {
      expect(raw.length, 791);
      expect(raw.every((p) => p.accuracyM <= 50), isTrue, reason: 'it was not poor reception: the reported accuracy is good');
      expect(length(raw), inInclusiveRange(7300, 7500));
      expect(bigSteps(raw), greaterThan(20));
    });

    test('the false movement is removed: well under a quarter of the recorded distance is left, and no jumps', () {
      final double before = length(raw), after = length(fixed);
      // ignore: avoid_print
      print('Nov 3: raw ${before.round()} m -> corrected ${after.round()} m (removed ${(before - after).round()} m), steps>40 m ${bigSteps(raw)} -> ${bigSteps(fixed)}');
      expect(before - after, greaterThan(5000));
      expect(after, lessThan(before * 0.25));
      // the steps over 40 m that remain are the walk to the apartment (10:06-10:22, fixes 10-30 s apart) and two small
      // drifts at 11:05-11:07: none of the web around the apartment
      expect(bigSteps(fixed), lessThanOrEqualTo(8));
      expect(bigSteps(fixed), lessThan(bigSteps(raw) ~/ 2));
      final int afterWalk = fixed.indexWhere((p) => p.timestamp.millisecondsSinceEpoch - base > 66 * 60000);
      expect(bigSteps(fixed.sublist(afterWalk)), 0, reason: 'nothing after 11:05 is left but the stay');
    });

    test('the real travel from the start to the apartment is untouched', () {
      final int cut = raw.indexWhere((p) => p.timestamp.millisecondsSinceEpoch - base > 30 * 60000);
      final double travelFixed = length(fixed.take(cut));
      // the line still covers at least the straight distance walked; what goes is the drift inside the 10 minute
      // stay at 10:09-10:19, which is not travel
      expect(travelFixed, greaterThan(500));
      expect(travelFixed, lessThan(length(raw.take(cut))));
      // where the phone ended up after the walk is where the corrected route puts it
      final int settled = raw.indexWhere((p) => p.timestamp.millisecondsSinceEpoch - base > 45 * 60000);
      expect(gpsDistanceM(raw[settled].latitude, raw[settled].longitude, fixed[settled].latitude, fixed[settled].longitude), lessThan(60), reason: 'at most the drift inside the 35 m stay radius');
      // and it really went about 430 m from the start
      expect(gpsDistanceM(fixed.first.latitude, fixed.first.longitude, fixed[cut].latitude, fixed[cut].longitude), inInclusiveRange(380, 480));
    });

    test('the long stay is one place, and the times of the stay are kept', () {
      final List<GpsPoint> stay = fixed.where((p) {
        final int t = p.timestamp.millisecondsSinceEpoch - base;
        return t > 100 * 60000 && t < 138 * 60000; // 11:45 - 12:21, before the first burst
      }).toList();
      final double spread = stay.map((p) => gpsDistanceM(stay.first.latitude, stay.first.longitude, p.latitude, p.longitude)).reduce(math.max);
      expect(spread, lessThan(1.0));
      expect(fixed.length, raw.length, reason: 'no fix is deleted');
      for (int i = 0; i < raw.length; i++) {
        expect(fixed[i].timestamp, raw[i].timestamp);
      }
    });

    test('the raw fixes are not modified (diagnostics keep them)', () {
      final List<GpsPoint> again = <GpsPoint>[for (final List<num> r in fx) point(r)];
      RouteJitter.collapse(raw);
      for (int i = 0; i < raw.length; i++) {
        expect(raw[i].latitude, again[i].latitude);
        expect(raw[i].longitude, again[i].longitude);
      }
    });

    test('the live maps, which use raw Firebase maps, get the same corrected route', () {
      final List<Map> maps = <Map>[
        for (final GpsPoint p in raw)
          <String, Object?>{
            'lat': p.latitude,
            'lng': p.longitude,
            'timestamp': p.timestamp.millisecondsSinceEpoch,
            'accuracy': p.accuracyM,
            'speed': p.speedKmh,
            'color': 'GREEN',
          },
      ];
      final List<Map> corrected = RouteJitter.collapseMaps(maps);
      double mapLength = 0;
      for (int i = 1; i < corrected.length; i++) {
        mapLength += gpsDistanceM(corrected[i - 1]['lat'] as double, corrected[i - 1]['lng'] as double, corrected[i]['lat'] as double, corrected[i]['lng'] as double);
      }
      expect((mapLength - length(fixed)).abs(), lessThan(length(fixed) * 0.02));
      // drawn by every map: one continuous line from the start to the apartment, no web
      final List<Map<String, dynamic>> lines = RouteGeometry.lineFeatures(corrected);
      expect(lines.where((f) => (f['properties'] as Map)[RouteGeometry.linkKey] == null), hasLength(1));
      expect(lines.where((f) => (f['properties'] as Map)[RouteGeometry.linkKey] != null), isEmpty,
          reason: 'a long stop is not a recording gap: no dashed link after it');
      final List coords = ((lines.first['geometry'] as Map)['coordinates'] as List);
      expect(coords.length, lessThan(raw.length ~/ 3));
    });
  });

  group('genuine movement is never taken for wander', () {
    final int t0 = DateTime(2026, 11, 3, 8).millisecondsSinceEpoch;
    GpsPoint gp(int sec, double eastM, double northM, {double kmh = 0}) => GpsPoint(
        latitude: lat0 + northM / 111320,
        longitude: lng0 + eastM / (111320 * kLng),
        accuracyM: 8,
        speedKmh: kmh,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t0 + sec * 1000));

    /// A 12 minute stay at the origin (a fix every 30 s).
    List<GpsPoint> stay() => <GpsPoint>[for (int s = 0; s <= 720; s += 30) gp(s, (s % 3) * 2.0, (s % 5) * 1.5)];

    double extent(List<GpsPoint> a, List<GpsPoint> b) {
      double worst = 0;
      for (int i = 0; i < a.length; i++) {
        worst = math.max(worst, gpsDistanceM(a[i].latitude, a[i].longitude, b[i].latitude, b[i].longitude));
      }
      return worst;
    }

    test('a stay and then driving off 800 m: the departure is kept exactly', () {
      final List<GpsPoint> pts = <GpsPoint>[...stay(), for (int s = 750; s <= 900; s += 5) gp(s, 0, (s - 720) * 4.0, kmh: 14)];
      final List<GpsPoint> out = RouteJitter.collapse(pts);
      expect(extent(pts.sublist(stay().length), out.sublist(stay().length)), lessThan(0.5));
      expect(length(out), greaterThan(length(pts.sublist(stay().length)) * 0.97));
    });

    test('a short reversing manoeuvre after a normal stop (12 m back and forth) is kept', () {
      // (inside a stay of 10+ minutes, movement within its 35 m radius is not told apart from GPS drift)
      final List<GpsPoint> pts = <GpsPoint>[
        for (int s = 0; s <= 240; s += 20) gp(s, (s % 3) * 2.0, (s % 5) * 1.5),
        for (int s = 260; s <= 285; s += 5) gp(s, 0, -(s - 255) * 0.5, kmh: 5), // 12 m backwards
        for (int s = 290; s <= 315; s += 5) gp(s, 0, -12 + (s - 285) * 0.5, kmh: 5), // forwards again
      ];
      final List<GpsPoint> out = RouteJitter.collapse(pts);
      const int from = 13;
      expect(extent(pts.sublist(from), out.sublist(from)), lessThan(16), reason: 'at worst the 12 m of the manoeuvre (plus the 8 m noise rule)');
      expect(out.sublist(from).map((p) => p.latitude).reduce(math.min), lessThan(lat0 - 8 / 111320));
    });

    test('a loop of 400 m that returns to the stay (path / reach about 3) is kept', () {
      final List<GpsPoint> pts = <GpsPoint>[...stay()];
      for (int i = 0; i < 40; i++) {
        final double a = i / 40 * 2 * math.pi;
        pts.add(gp(750 + i * 10, 60 * math.sin(a), 60 * (1 - math.cos(a)), kmh: 8));
      }
      for (int s = 1200; s <= 1920; s += 30) {
        pts.add(gp(s, 0, 0));
      }
      final List<GpsPoint> out = RouteJitter.collapse(pts);
      final List<GpsPoint> loopIn = pts.sublist(stay().length, stay().length + 40), loopOut = out.sublist(stay().length, stay().length + 40);
      expect(length(loopOut), greaterThan(length(loopIn) * 0.8));
    });

    test('a dead-end street (out 200 m and back to the stay) is kept', () {
      final List<GpsPoint> pts = <GpsPoint>[
        ...stay(),
        for (int s = 750; s <= 850; s += 5) gp(s, 0, (s - 745) * 2.0, kmh: 7),
        for (int s = 855; s <= 955; s += 5) gp(s, 0, 200 - (s - 850) * 2.0, kmh: 7),
        for (int s = 1000; s <= 1720; s += 30) gp(s, 0, 0),
      ];
      final List<GpsPoint> out = RouteJitter.collapse(pts);
      final int from = stay().length;
      expect(out.sublist(from).map((p) => p.latitude).reduce(math.max), greaterThan(lat0 + 150 / 111320));
    });

    test('leaving for good is never hidden while the trip is still being recorded (no second stay yet)', () {
      final List<GpsPoint> pts = <GpsPoint>[...stay(), for (int s = 750; s <= 1100; s += 5) gp(s, (s % 7) * 3.0, (s - 745) * 1.2, kmh: 4)];
      final List<GpsPoint> out = RouteJitter.collapse(pts);
      // the truck is where it was recorded, 400+ m away from the stay, and the line to it is all there
      expect(out.last.latitude, greaterThan(lat0 + 400 / 111320));
      expect(length(out.sublist(stay().length)), greaterThan(380));
    });

    test('a scribble around a stay that is still going on is held back, and released the moment the truck really leaves', () {
      final math.Random rnd = math.Random(3);
      final List<GpsPoint> pts = <GpsPoint>[...stay()];
      for (int i = 0; i < 30; i++) {
        pts.add(gp(750 + i * 8, (rnd.nextDouble() - 0.5) * 160, (rnd.nextDouble() - 0.5) * 160, kmh: 15));
      }
      final List<GpsPoint> held = RouteJitter.collapse(pts);
      expect(length(held), lessThan(length(pts) * 0.2));
      // the truck now really drives away 600 m
      for (int s = 1000; s <= 1100; s += 5) {
        pts.add(gp(s, 0, (s - 995) * 6.0, kmh: 22));
      }
      final List<GpsPoint> released = RouteJitter.collapse(pts);
      expect(released.last.latitude, greaterThan(lat0 + 500 / 111320));
    });

    test('a stay (under 10 minutes) is not treated as one: a quick collection stop keeps its fixes as before', () {
      final List<GpsPoint> pts = <GpsPoint>[for (int s = 0; s <= 300; s += 15) gp(s, 0, s * 0.3, kmh: 1)];
      final List<StayAnchor?> a = StationaryExcursions.anchors(<StayFix>[
        for (final GpsPoint p in pts) StayFix(p.latitude, p.longitude, p.timestamp.millisecondsSinceEpoch),
      ]);
      expect(a.every((x) => x == null), isTrue);
    });
  });
}
