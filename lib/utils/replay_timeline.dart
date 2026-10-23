import 'dart:math' as math;

import 'gps_smoothing.dart';

/// Where the truck is at one moment of a replay.
class ReplayPose {
  const ReplayPose({required this.position, required this.trail, required this.time});

  /// [lng, lat] of the marker.
  final List<double> position;

  /// The line already driven, ending at [position].
  final List<List<double>> trail;

  /// Real clock time of this moment of the trip.
  final DateTime time;
}

/// Turns a trip into a smooth, time-based replay.
///
/// * The slider follows the trip's real clock, so the time label and the marker always agree.
/// * Between two GPS fixes the marker moves along the drawn line (the road-matched line when
///   available), proportionally to the time between the fixes, instead of jumping to the next fix.
///   Positions between fixes are therefore estimated; the fixes themselves are recorded data.
/// * A pause or signal gap longer than [maxPlayedGapMs] is played as if it lasted that long, so
///   the replay does not sit still for minutes.
class ReplayTimeline {
  ReplayTimeline({required this.timesMs, required this.line, required this.vertexOfPoint})
      : assert(timesMs.length == vertexOfPoint.length) {
    _cum.add(0);
    for (int i = 1; i < line.length; i++) {
      _cum.add(_cum.last + GpsSmoothing.distanceM(line[i - 1][1], line[i - 1][0], line[i][1], line[i][0]));
    }
    _play.add(0);
    for (int i = 1; i < timesMs.length; i++) {
      _play.add(_play.last + math.min(math.max(0, timesMs[i] - timesMs[i - 1]), maxPlayedGapMs));
    }
  }

  static const int maxPlayedGapMs = 120000;

  final List<int> timesMs;
  final List<List<double>> line;
  final List<int> vertexOfPoint;
  final List<double> _cum = <double>[];
  final List<int> _play = <int>[];

  /// Pose at [progress] (0..1 of the replay).
  ReplayPose at(double progress) {
    final int n = timesMs.length;
    if (n == 0 || line.isEmpty) {
      return ReplayPose(position: const <double>[0, 0], trail: const <List<double>>[], time: DateTime.now());
    }
    final List<double> first = line[vertexOfPoint[0].clamp(0, line.length - 1)];
    if (n == 1 || _play.last == 0) {
      return ReplayPose(position: first, trail: <List<double>>[first], time: DateTime.fromMillisecondsSinceEpoch(timesMs[0]));
    }
    final double target = progress.clamp(0.0, 1.0) * _play.last;
    int i = 0;
    while (i < n - 2 && _play[i + 1] < target) {
      i++;
    }
    final int span = _play[i + 1] - _play[i];
    final double f = span <= 0 ? 1.0 : ((target - _play[i]) / span).clamp(0.0, 1.0);
    final DateTime time = DateTime.fromMillisecondsSinceEpoch((timesMs[i] + f * (timesMs[i + 1] - timesMs[i])).round());

    final int a = vertexOfPoint[i].clamp(0, line.length - 1);
    final int b = math.max(a, vertexOfPoint[i + 1].clamp(0, line.length - 1));
    final double d = _cum[a] + f * (_cum[b] - _cum[a]);
    int k = a;
    while (k < b && _cum[k + 1] < d) {
      k++;
    }
    List<double> pos;
    if (k >= b) {
      pos = line[b];
    } else {
      final double seg = _cum[k + 1] - _cum[k];
      final double g = seg <= 0 ? 0 : (d - _cum[k]) / seg;
      pos = <double>[line[k][0] + g * (line[k + 1][0] - line[k][0]), line[k][1] + g * (line[k + 1][1] - line[k][1])];
    }
    return ReplayPose(position: pos, trail: <List<double>>[...line.sublist(0, k + 1), pos], time: time);
  }
}
