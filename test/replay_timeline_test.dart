import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/replay_timeline.dart';

void main() {
  // Two fixes 1 km apart on a straight road drawn with 11 vertices.
  final List<List<double>> line = <List<double>>[for (int i = 0; i <= 10; i++) <double>[121.16, 13.95 + i * 0.0009]];
  final ReplayTimeline t = ReplayTimeline(timesMs: <int>[0, 100000], line: line, vertexOfPoint: <int>[0, 10]);

  test('between two fixes the marker moves along the road instead of jumping', () {
    final ReplayPose mid = t.at(0.5);
    expect(mid.position[1], closeTo(13.95 + 0.0045, 0.0002));
    expect(mid.trail.length, greaterThan(2));
    expect(t.at(0.25).position[1], lessThan(mid.position[1]));
  });

  test('the clock follows the trip time, so label and marker agree', () {
    expect(t.at(0.5).time.millisecondsSinceEpoch, 50000);
    expect(t.at(1).position, line.last);
  });

  test('a long signal gap is played short but keeps its real clock times', () {
    final ReplayTimeline g = ReplayTimeline(timesMs: <int>[0, 60000, 60000 + 3600000], line: line, vertexOfPoint: <int>[0, 5, 10]);
    // 60 s played + gap capped at 120 s: the first fix-to-fix stretch takes a third of the replay.
    expect(g.at(1 / 3).position, line[5]);
    expect(g.at(1).time.millisecondsSinceEpoch, 3660000);
  });
}
