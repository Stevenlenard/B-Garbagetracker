import 'dart:math' as math;

/// How two consecutive recorded GPS fixes of a trip are connected on every map (live Driver / Admin / Resident maps,
/// saved Route History and trip replay): ONE rule set, so the same trip always draws the same line.
///
/// A route line is a record of where the truck was, so it is never invented and never thrown away:
///  * [solid]     the movement between the two fixes is physically possible and was observed closely enough (normal
///                tracking, also with a slow network, weak signal or a rejected fix in between): drawn as one line;
///  * [uncertain] the fixes are plausible but minutes apart (the phone recorded nothing in between): the earlier route
///                stays, the connection is drawn as a faint dashed link and no intermediate coordinate is made up;
///  * [broken]    the move is impossible (a bad fix, or the truck was moved without tracking) or the gap is far too long
///                to bridge: the earlier route stays and a new stretch starts at the later fix, with no connection.
enum RouteLink { solid, uncertain, broken }

/// One fix reduced to what the link rules need.
class RouteFix {
  const RouteFix(this.lat, this.lng, this.tsMs, this.accuracyM);

  final double lat;
  final double lng;

  /// When the fix was recorded (epoch ms); 0 or less when unknown.
  final int tsMs;
  final double accuracyM;
}

/// A kept fix and how it connects to the kept fix before it.
class LinkedFix {
  const LinkedFix(this.index, this.link);

  /// Index into the list given to [RouteLinkPolicy.link].
  final int index;
  final RouteLink link;
}

class RouteLinkPolicy {
  RouteLinkPolicy._();

  /// Fastest movement believed (m/s, 144 km/h). Faster than this between two fixes is a bad fix, not driving: a garbage
  /// truck never does it, so nothing slower is ever treated as a jump (the old rule cut at every weak-signal moment).
  static const double maxPlausibleMps = 40.0;

  /// Up to this gap (s) the tracking is normal: a plausible move is always one solid line.
  static const int normalGapSec = 180;

  /// Up to this gap (s) an unrecorded stretch is bridged as [RouteLink.uncertain]; longer is unrecoverable.
  static const int bridgeMaxSec = 1800;

  /// Position error that is always allowed between two fixes (m); more when the fixes report poorer accuracy.
  static const double minAllowanceM = 60.0;
  static const double maxAllowanceM = 200.0;

  /// A fix that cannot be reached from the last one is held back; once this many consecutive fixes agree with each
  /// other the truck really is somewhere else now (it was moved untracked), and a new stretch starts there.
  static const int relocationFixes = 3;

  /// Fixes closer than this (m) to the previous kept fix add nothing to a line.
  static const double duplicateM = 0.5;

  static double allowanceM(double accuracyA, double accuracyB) =>
      math.min(maxAllowanceM, math.max(minAllowanceM, accuracyA + accuracyB));

  static RouteLink classify({required int dtSec, required double distM, double accuracyA = 0, double accuracyB = 0}) {
    final double allow = allowanceM(accuracyA, accuracyB);
    // Not (meaningfully) away from where it was: nothing to bridge, whatever the time between (a stop, a heartbeat).
    if (distM <= allow) return RouteLink.solid;
    if (dtSec <= 0) return RouteLink.broken;
    if ((distM - allow) / dtSec > maxPlausibleMps) return RouteLink.broken;
    if (dtSec <= normalGapSec) return RouteLink.solid;
    return dtSec <= bridgeMaxSec ? RouteLink.uncertain : RouteLink.broken;
  }

  static double distanceM(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180.0;
    final double dLng = (lng2 - lng1) * math.pi / 180.0;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static RouteLink _between(RouteFix a, RouteFix b) {
    final double d = distanceM(a.lat, a.lng, b.lat, b.lng);
    if (a.tsMs <= 0 || b.tsMs <= 0) {
      // no times: only an absurd distance is refused
      return d <= allowanceM(a.accuracyM, b.accuracyM) || d <= maxPlausibleMps * normalGapSec ? RouteLink.solid : RouteLink.broken;
    }
    return classify(dtSec: ((b.tsMs - a.tsMs) / 1000).round(), distM: d, accuracyA: a.accuracyM, accuracyB: b.accuracyM);
  }

  /// Walks time-sorted, individually valid [fixes] and returns the fixes to draw with how each connects to the one
  /// before it. Nothing is invented and nothing but unreachable bad fixes is dropped:
  ///  * an unreachable fix is held back; if the next fixes do not agree with it, it was noise and is dropped, and the
  ///    line simply continues from the last good fix (no break);
  ///  * [relocationFixes] unreachable fixes that agree with each other are a real relocation: the earlier route
  ///    stays and a new stretch starts at the first of them ([RouteLink.broken]);
  ///  * [exempt] fixes (the live position, already filtered by the driver app) are always accepted and joined solid.
  static List<LinkedFix> link(List<RouteFix> fixes, {bool Function(int i)? exempt}) {
    final List<LinkedFix> out = <LinkedFix>[];
    final List<int> held = <int>[];
    // When the truck was last seen where the last kept fix is: fixes at the same place are skipped as duplicates (a stop,
    // the stored stay positions), but they prove the truck was recording there; the time to the next fix is measured from
    // the latest of them, not from the first, or the first move after a long stop would look like a recording gap.
    int lastSeenMs = 0;
    for (int i = 0; i < fixes.length; i++) {
      final RouteFix f = fixes[i];
      if (out.isEmpty) {
        out.add(LinkedFix(i, RouteLink.solid));
        lastSeenMs = f.tsMs;
        continue;
      }
      final RouteFix kept = fixes[out.last.index];
      final RouteFix prev = RouteFix(kept.lat, kept.lng, math.max(kept.tsMs, lastSeenMs), kept.accuracyM);
      if (distanceM(prev.lat, prev.lng, f.lat, f.lng) < duplicateM) {
        if (f.tsMs > lastSeenMs) lastSeenMs = f.tsMs;
        continue;
      }
      if (exempt != null && exempt(i)) {
        held.clear();
        out.add(LinkedFix(i, RouteLink.solid));
        lastSeenMs = f.tsMs;
        continue;
      }
      final RouteLink k = _between(prev, f);
      if (k == RouteLink.broken) {
        held.add(i);
        if (held.length >= relocationFixes && _agree(fixes, held)) {
          out.add(LinkedFix(held.first, RouteLink.broken));
          for (final int j in held.skip(1)) {
            out.add(LinkedFix(j, RouteLink.solid));
          }
          lastSeenMs = fixes[held.last].tsMs;
          held.clear();
        }
        continue;
      }
      held.clear();
      out.add(LinkedFix(i, k));
      lastSeenMs = f.tsMs;
    }
    return out;
  }

  static bool _agree(List<RouteFix> fixes, List<int> idx) {
    for (int k = 1; k < idx.length; k++) {
      if (_between(fixes[idx[k - 1]], fixes[idx[k]]) == RouteLink.broken) return false;
    }
    return true;
  }
}
