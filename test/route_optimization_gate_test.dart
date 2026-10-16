import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/route_assignment_service.dart';
import 'package:garbage_tracking_app/utils/route_optimization_card.dart';
import 'package:garbage_tracking_app/utils/route_optimization_gate.dart';

/// Minimal model of the dashboard flow: auto triggers + manual taps feeding one gate, with an
/// injectable optimizer. Counts how often the optimizer really runs.
class Harness {
  Harness(this.optimizer);
  final Future<bool> Function() optimizer;
  final RouteOptimizationGate gate = RouteOptimizationGate();
  int runs = 0;
  String? issue;
  bool hasRoute = false;
  final List<RouteCardKind> shown = <RouteCardKind>[];

  RouteCardKind card() =>
      RouteCardState.resolve(hasRoute: hasRoute, isOptimizing: gate.isRunning, issue: issue).kind;

  Future<void> run({String? autoKey}) async {
    final int? token = gate.begin(autoKey: autoKey);
    if (token == null) return;
    runs++;
    shown.add(card());
    final bool ok = await optimizer();
    final bool current = gate.finish(token);
    if (!current) return; // stale result ignored
    if (ok) {
      hasRoute = true;
      issue = null;
    } else {
      issue = 'Route optimization failed.';
    }
    shown.add(card());
  }

  /// An automatic trigger (areas loaded, first fix, progress change...).
  Future<void> auto(String key) async {
    if (!gate.shouldAutoRun(key)) return;
    await run(autoKey: key);
  }
}

void main() {
  group('route optimization gate', () {
    test('a failed automatic run is NOT retried by later rebuilds or GPS updates', () async {
      final Harness h = Harness(() async => false);
      await h.auto('trip1|hash|a,b');
      expect(h.runs, 1);
      expect(h.card(), RouteCardKind.issue);
      // 200 rebuilds / GPS fixes with unchanged inputs: nothing restarts.
      for (int i = 0; i < 200; i++) {
        await h.auto('trip1|hash|a,b');
      }
      expect(h.runs, 1);
      expect(h.card(), RouteCardKind.issue, reason: 'stays on the failure message, no flicker');
      expect(h.shown, <RouteCardKind>[RouteCardKind.loading, RouteCardKind.issue]);
    });

    test('manual retry runs exactly once per tap', () async {
      final Harness h = Harness(() async => false);
      await h.auto('k');
      await h.run(); // tap
      await h.run(); // tap
      expect(h.runs, 3);
    });

    test('concurrent requests: taps and triggers during a run are ignored', () async {
      final Completer<bool> slow = Completer<bool>();
      final Harness h = Harness(() => slow.future);
      final Future<void> first = h.run();
      expect(h.gate.isRunning, isTrue);
      await h.run(); // tap while running
      await h.auto('k'); // trigger while running
      expect(h.runs, 1);
      slow.complete(true);
      await first;
      expect(h.card(), RouteCardKind.ready);
    });

    test('a stale result from a previous trip never overwrites newer state', () async {
      final Completer<bool> slow = Completer<bool>();
      final Harness h = Harness(() => slow.future);
      final Future<void> old = h.run(autoKey: 'trip1');
      h.gate.reset(); // new trip
      expect(h.gate.isRunning, isFalse);
      slow.complete(false); // old trip's failure arrives late
      await old;
      expect(h.issue, isNull, reason: 'old failure ignored');
      expect(h.gate.shouldAutoRun('trip2'), isTrue);
    });

    test('changed inputs (new pending set) allow exactly one new automatic run', () async {
      final Harness h = Harness(() async => false);
      await h.auto('trip1|hash|a,b');
      await h.auto('trip1|hash|b'); // area a completed
      await h.auto('trip1|hash|b');
      expect(h.runs, 2);
    });

    test('success keeps the route; a later failed manual retry does not remove it', () async {
      bool ok = true;
      final Harness h = Harness(() async => ok);
      await h.auto('k');
      expect(h.card(), RouteCardKind.ready);
      ok = false;
      await h.run();
      expect(h.hasRoute, isTrue);
      expect(h.card(), RouteCardKind.ready);
    });
  });

  group('assignment responses from a server without the backend', () {
    test('Hostinger HTML (index.html, 200) means "not set up", not an error', () {
      final AssignmentResult<Map<dynamic, dynamic>> r =
          RouteAssignmentService.interpret(200, '<!DOCTYPE html>\n<html><head></head></html>');
      expect(r.failure, AssignmentFailure.notSetUp);
    });

    test('an HTML 404 page is also "not set up"', () {
      expect(RouteAssignmentService.interpret(404, '<html>Not Found</html>').failure, AssignmentFailure.notSetUp);
    });

    test('JSON sent as text is still parsed; genuine errors are kept', () {
      expect(RouteAssignmentService.interpret(200, '{"success":true,"data":[]}').isOk, isTrue);
      final AssignmentResult<Map<dynamic, dynamic>> notFound =
          RouteAssignmentService.interpret(404, <String, Object?>{'success': false, 'message': 'Assignment not found.'});
      expect(notFound.failure, AssignmentFailure.invalid);
      expect(RouteAssignmentService.interpret(200, 'garbage').failure, AssignmentFailure.network);
      expect(RouteAssignmentService.interpret(401, '<html>').failure, AssignmentFailure.unauthorized,
          reason: 'auth failures are never masked as "not set up"');
      expect(RouteAssignmentService.interpret(503, '<html>').failure, AssignmentFailure.notConfigured);
    });
  });
}
