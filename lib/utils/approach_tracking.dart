// Inputs for the "truck approaching" alerts that stay true to what the truck really did.
//
// A collecting truck stops at every pickup, so its speed while moving overstates how fast
// it actually covers ground, and a straight line understates the road distance. Both made
// every alert early. RecentTravelSpeed measures real progress (stops included) and
// ApproachDetector only reports an area as approached after sustained closing, never on
// the first fix or on GPS wander.

/// Recent travel speed (km/h): distance actually covered over the last [windowMs],
/// stops included. Null until at least [minSpanMs] of history exists.
class RecentTravelSpeed {
  RecentTravelSpeed({this.windowMs = 600000, this.minSpanMs = 180000});

  final int windowMs;
  final int minSpanMs;
  final List<MapEntry<int, double>> _s = <MapEntry<int, double>>[];

  /// [totalKm] is the trip's cumulative recorded distance at [tsMs].
  void add(int tsMs, double totalKm) {
    if (totalKm.isNaN || totalKm < 0) return;
    if (_s.isNotEmpty && tsMs <= _s.last.key) return;
    _s.add(MapEntry<int, double>(tsMs, totalKm));
    // keep one sample older than the window as the window's starting point
    while (_s.length > 2 && tsMs - _s[1].key >= windowMs) {
      _s.removeAt(0);
    }
  }

  double? kmhAt(int nowMs) {
    if (_s.length < 2) return null;
    final MapEntry<int, double> last = _s.last;
    MapEntry<int, double> first = _s.first;
    for (final MapEntry<int, double> e in _s) {
      if (nowMs - e.key <= windowMs) break;
      first = e;
    }
    final int spanMs = nowMs - first.key;
    if (spanMs < minSpanMs) return null;
    final double km = last.value - first.value;
    if (km < 0) return null;
    return km / (spanMs / 3600000.0);
  }

  void clear() => _s.clear();
}

/// Whether the truck is really closing in on an area: over the last [windowMs] its
/// distance to the area fell by at least [minClosingM], measured across at least
/// [minSpanMs], and it is not moving away again.
class ApproachDetector {
  ApproachDetector({this.windowMs = 180000, this.minSpanMs = 60000, this.minClosingM = 150.0, this.reboundM = 30.0});

  final int windowMs;
  final int minSpanMs;
  final double minClosingM;
  final double reboundM;
  final Map<String, List<MapEntry<int, double>>> _byArea = <String, List<MapEntry<int, double>>>{};

  void add(String area, int tsMs, double distM) {
    final List<MapEntry<int, double>> s = _byArea.putIfAbsent(area, () => <MapEntry<int, double>>[]);
    s.add(MapEntry<int, double>(tsMs, distM));
    s.removeWhere((MapEntry<int, double> e) => tsMs - e.key > windowMs);
  }

  bool isApproaching(String area, int nowMs) {
    final List<MapEntry<int, double>> s =
        (_byArea[area] ?? const <MapEntry<int, double>>[]).where((e) => nowMs - e.key <= windowMs).toList();
    if (s.length < 3) return false;
    if (s.last.key - s.first.key < minSpanMs) return false;
    final double closest = s.map((e) => e.value).reduce((a, b) => a < b ? a : b);
    if (s.last.value > closest + reboundM) return false; // moving away again
    return s.first.value - s.last.value >= minClosingM;
  }

  void clear() => _byArea.clear();
}
