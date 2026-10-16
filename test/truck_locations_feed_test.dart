import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/truck_locations_feed.dart';

void main() {
  late StreamController<ChildEvent> source;
  late TruckLocationsFeed feed;

  setUp(() {
    source = StreamController<ChildEvent>.broadcast();
    feed = TruckLocationsFeed(() => source.stream, emptyGrace: const Duration(milliseconds: 60));
  });

  tearDown(() async => source.close());

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

  test('assembles added / changed / removed children', () async {
    final events = <Map<String, dynamic>>[];
    final sub = feed.events.listen((e) => events.add(Map<String, dynamic>.from(e.snapshot.value! as Map)));
    await tick();
    source.add(const ChildEvent(ChildEventType.added, 'GT-1', {'status': 'ACTIVE', 'lat': 1}));
    await tick();
    source.add(const ChildEvent(ChildEventType.added, 'GT-2', {'status': 'IDLE'}));
    await tick();
    source.add(const ChildEvent(ChildEventType.changed, 'GT-1', {'status': 'FULL', 'lat': 2}));
    await tick();
    expect(events.last.keys.toSet(), {'GT-1', 'GT-2'});
    expect((events.last['GT-1'] as Map)['status'], 'FULL');
    source.add(const ChildEvent(ChildEventType.removed, 'GT-2'));
    await tick();
    expect(events.last.keys.toSet(), {'GT-1'});
    await sub.cancel();
  });

  test('the legacy bulk field is dropped and never reaches consumers', () async {
    Map? last;
    final sub = feed.events.listen((e) => last = e.snapshot.value as Map?);
    await tick();
    source.add(ChildEvent(ChildEventType.added, 'GT-001', {
      'status': 'OFFLINE',
      'route_history': {for (var i = 0; i < 1000; i++) 'k$i': {'lat': i}},
    }));
    await tick();
    expect((last!['GT-001'] as Map).containsKey('route_history'), isFalse);
    expect((last!['GT-001'] as Map)['status'], 'OFFLINE');
    await sub.cancel();
  });

  test('same-tick events are coalesced into one emission (no added delay)', () async {
    int emissions = 0;
    final sub = feed.events.listen((_) => emissions++);
    await tick();
    for (int i = 0; i < 5; i++) {
      source.add(ChildEvent(ChildEventType.added, 'T$i', {'status': 'ACTIVE'}));
    }
    await tick();
    expect(emissions, 1);
    await sub.cancel();
  });

  test('an update to one truck delivers that truck, not a rebuilt payload of the others\' bulk data', () async {
    Map? last;
    final sub = feed.events.listen((e) => last = e.snapshot.value as Map?);
    await tick();
    source.add(ChildEvent(ChildEventType.added, 'BIG', {'route_history': {'a': 1}, 'status': 'OFFLINE'}));
    await tick();
    source.add(const ChildEvent(ChildEventType.changed, 'GT-7', {'status': 'ACTIVE', 'lat': 1.5}));
    await tick();
    expect((last!['GT-7'] as Map)['lat'], 1.5);
    expect((last!['BIG'] as Map).containsKey('route_history'), isFalse);
    await sub.cancel();
  });

  test('a late subscriber is given the current state immediately', () async {
    final first = feed.events.listen((_) {});
    await tick();
    source.add(const ChildEvent(ChildEventType.added, 'GT-1', {'status': 'ACTIVE'}));
    await tick();
    Map? seen;
    final late = feed.events.listen((e) => seen = e.snapshot.value as Map?);
    await tick();
    expect(seen?.keys, contains('GT-1'));
    await late.cancel();
    await first.cancel();
  });

  test('an empty node produces an empty (non-existent) snapshot after the grace period', () async {
    bool? exists;
    final sub = feed.events.listen((e) => exists = e.snapshot.exists);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(exists, isFalse);
    await sub.cancel();
  });

  test('the source is released when the last listener cancels', () async {
    final sub = feed.events.listen((_) {});
    await tick();
    expect(source.hasListener, isTrue);
    await sub.cancel();
    await tick();
    expect(source.hasListener, isFalse);
  });
}
