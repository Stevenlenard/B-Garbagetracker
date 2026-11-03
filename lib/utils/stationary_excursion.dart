import 'dart:math' as math;

/// One recorded fix, reduced to what stay detection needs.
class StayFix {
  const StayFix(this.lat, this.lng, this.tsMs);

  final double lat;
  final double lng;
  final int tsMs;
}

/// A place where the truck stayed.
class StayAnchor {
  const StayAnchor(this.lat, this.lng);

  final double lat;
  final double lng;
}

/// Finds GPS wander around a long stay in an ALREADY RECORDED route (display and statistics only: the raw fixes are never
/// changed or deleted).
///
/// Why it exists. A phone that stays in one place for hours (indoors, in a building, under a roof) does not only drift by
/// a few metres: now and then the receiver reports bursts of fixes 50-250 m away, with a good-looking accuracy and a
/// receiver speed of 10-25 km/h, and the positions come back to the same place afterwards. The recorder cannot tell such a
/// burst from a departure while it happens (it looks exactly like driving away), so it records them, and a few hours of
/// parking become a web of lines and several kilometres of distance (trip of 3 Nov 2026: 7.4 km recorded, of which 5.8 km
/// was wander around a place the phone never left). What gives it away is what follows: the truck is back at the same
/// place, after a scribble that covers far more ground than the distance it reached.
///
/// Rules (all must hold; genuine travel breaks every one of them):
///  1. A STAY is 10 minutes or more within [stayRadiusM] of one place ([minStayMs]).
///  2. An EXCURSION is the run of fixes between a stay and the next stay at the same place (within [sameStayM]), or, while
///     the trip is still being recorded, the run after the last stay, within [maxExcursionMs] and at most
///     [maxExtentM] from the stay. A truck that left for good is farther than that within a minute or two.
///  3. It is wander, not travel, when its path is at least [minScribbleRatio] times the farthest distance it reached from
///     the stay: a trip out and back (ratio about 2), a loop (about 3) or a dead end is kept; a scribble is not.
///
/// Wander and the fixes of a stay take the position of the stay; they keep their times, so durations stay.
class StationaryExcursions {
  StationaryExcursions._();

  static const double stayRadiusM = 35;
  static const int minStayMs = 10 * 60 * 1000;
  static const int minStayFixes = 3;

  /// Stays this close are the same place.
  static const double sameStayM = 60;
  static const double maxExtentM = 300;
  static const int maxExcursionMs = 30 * 60 * 1000;
  static const int minExcursionFixes = 3;
  static const double minScribbleRatio = 4;

  /// A trailing excursion (trip still running) needs more evidence than one that is closed by a second stay.
  static const int minTrailingFixes = 8;

  static double distanceM(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180.0;
    final double dLng = (lng2 - lng1) * math.pi / 180.0;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double _median(List<double> v) {
    final List<double> s = List<double>.of(v)..sort();
    return s[s.length >> 1];
  }

  /// The stays of [fixes] (time-sorted): index range and place.
  static List<({int from, int to, StayAnchor at})> stays(List<StayFix> fixes) {
    final List<({int from, int to, StayAnchor at})> out = <({int from, int to, StayAnchor at})>[];
    final int n = fixes.length;
    int i = 0;
    while (i < n) {
      double sLat = fixes[i].lat, sLng = fixes[i].lng;
      int count = 1, last = i, outliers = 0;
      for (int k = i + 1; k < n; k++) {
        final double d = distanceM(sLat / count, sLng / count, fixes[k].lat, fixes[k].lng);
        // `sLat/count` is the running mean of the accepted fixes
        if (d <= stayRadiusM) {
          sLat += fixes[k].lat;
          sLng += fixes[k].lng;
          count++;
          last = k;
          outliers = 0;
        } else if (++outliers > 2) {
          break;
        }
      }
      if (count >= minStayFixes && fixes[last].tsMs - fixes[i].tsMs >= minStayMs) {
        final List<double> la = <double>[], lo = <double>[];
        for (int k = i; k <= last; k++) {
          if (distanceM(sLat / count, sLng / count, fixes[k].lat, fixes[k].lng) <= stayRadiusM) {
            la.add(fixes[k].lat);
            lo.add(fixes[k].lng);
          }
        }
        final StayAnchor at = StayAnchor(_median(la), _median(lo));
        if (out.isNotEmpty && i - out.last.to <= 3 && distanceM(out.last.at.lat, out.last.at.lng, at.lat, at.lng) <= sameStayM) {
          final ({int from, int to, StayAnchor at}) prev = out.removeLast();
          out.add((from: prev.from, to: last, at: prev.at));
        } else {
          out.add((from: i, to: last, at: at));
        }
        i = last + 1;
      } else {
        i++;
      }
    }
    return out;
  }

  static double _path(List<StayFix> f, int from, int to) {
    double p = 0;
    for (int i = from + 1; i <= to; i++) {
      p += distanceM(f[i - 1].lat, f[i - 1].lng, f[i].lat, f[i].lng);
    }
    return p;
  }

  /// For every fix: the place it must be drawn at (it is wander, or part of a stay), or null to keep it as recorded.
  static List<StayAnchor?> anchors(List<StayFix> fixes) {
    final List<StayAnchor?> out = List<StayAnchor?>.filled(fixes.length, null);
    if (fixes.length < minStayFixes) return out;
    final List<({int from, int to, StayAnchor at})> st = stays(fixes);
    for (final ({int from, int to, StayAnchor at}) s in st) {
      for (int i = s.from; i <= s.to; i++) {
        out[i] = s.at;
      }
    }

    bool scribble(({int from, int to, StayAnchor at}) a, int x0, int x1, int pathTo) {
      final double extent = <double>[for (int i = x0; i <= x1; i++) distanceM(a.at.lat, a.at.lng, fixes[i].lat, fixes[i].lng)]
          .reduce(math.max);
      if (extent > maxExtentM) return false;
      if (fixes[x1].tsMs - fixes[x0].tsMs > maxExcursionMs) return false;
      final double path = _path(fixes, math.max(0, x0 - 1), pathTo);
      return path >= minScribbleRatio * extent;
    }

    for (int k = 0; k < st.length; k++) {
      final ({int from, int to, StayAnchor at}) a = st[k];
      if (k + 1 < st.length) {
        final ({int from, int to, StayAnchor at}) b = st[k + 1];
        final int x0 = a.to + 1, x1 = b.from - 1;
        if (x1 - x0 + 1 < minExcursionFixes) continue;
        if (distanceM(a.at.lat, a.at.lng, b.at.lat, b.at.lng) > sameStayM) continue; // moved on: real travel
        if (scribble(a, x0, x1, math.min(fixes.length - 1, x1 + 1))) {
          for (int i = x0; i <= x1; i++) {
            out[i] = a.at;
          }
        }
      } else {
        // after the last stay, trip still being recorded
        final int x0 = a.to + 1, x1 = fixes.length - 1;
        if (x1 - x0 + 1 < minTrailingFixes) continue;
        if (scribble(a, x0, x1, x1)) {
          for (int i = x0; i <= x1; i++) {
            out[i] = a.at;
          }
        }
      }
    }
    return out;
  }

  /// Length (m) of the path through [fixes], for before / after comparisons.
  static double pathLengthM(List<StayFix> fixes) => fixes.length < 2 ? 0 : _path(fixes, 0, fixes.length - 1);
}

/// Online companion of [StationaryExcursions] for the driver app: tells, fix by fix, whether the truck is "held" at a
/// long stay, so that GPS wander around a phone that has stayed put for 10+ minutes cannot send "on the way" / arrival
/// alerts, mark areas as collected or publish an ETA (3 Nov 2026: a phone on a table for 3 hours "approached" Central and
/// Ayala Highway and "arrived" at Ayala).
///
/// A stay is 10+ minutes within [StationaryExcursions.stayRadiusM] of one place. While it lasts, and afterwards as long
/// as the truck stays within [holdRadiusM] of it, fixes are held. Two fixes in a row farther than [holdRadiusM] mean the
/// truck really left: the hold is released at once (a real departure is 300 m away within a minute or two).
///
/// Known limit: an area less than [holdRadiusM] from a place where the truck stayed 10+ minutes is not alerted until the
/// truck has left that radius (a truck does not normally park for 10 minutes next to an area and then collect it).
class StayHold {
  static const double holdRadiusM = 300;
  static const int releaseAfterFarFixes = 2;

  double _sLat = 0, _sLng = 0;
  int _n = 0, _startMs = 0, _lastMs = 0, _outliers = 0, _far = 0;
  StayAnchor? _anchor;

  /// The place of the current stay, or null.
  StayAnchor? get anchor => _anchor;

  /// Feed every accepted fix in time order; true when the fix must be held (see above).
  bool offer(double lat, double lng, int tsMs) {
    if (_n == 0) {
      _start(lat, lng, tsMs);
    } else if (StationaryExcursions.distanceM(_sLat / _n, _sLng / _n, lat, lng) <= StationaryExcursions.stayRadiusM) {
      _sLat += lat;
      _sLng += lng;
      _n++;
      _lastMs = tsMs;
      _outliers = 0;
    } else if (++_outliers > 2) {
      _start(lat, lng, tsMs);
    }
    if (_n >= StationaryExcursions.minStayFixes && _lastMs - _startMs >= StationaryExcursions.minStayMs) {
      _anchor = StayAnchor(_sLat / _n, _sLng / _n);
    }
    final StayAnchor? a = _anchor;
    if (a == null) return false;
    final double d = StationaryExcursions.distanceM(a.lat, a.lng, lat, lng);
    if (d > holdRadiusM) {
      if (++_far >= releaseAfterFarFixes) {
        _anchor = null;
        _far = 0;
        return false;
      }
      return false;
    }
    _far = 0;
    return true;
  }

  void _start(double lat, double lng, int tsMs) {
    _sLat = lat;
    _sLng = lng;
    _n = 1;
    _startMs = tsMs;
    _lastMs = tsMs;
    _outliers = 0;
  }

  void reset() {
    _n = 0;
    _anchor = null;
    _far = 0;
    _outliers = 0;
  }
}
