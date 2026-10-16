import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/route_optimization_card.dart';

void main() {
  test('route available -> ready (never a spinner)', () {
    final s = RouteCardState.resolve(hasRoute: true, isOptimizing: true, issue: 'x');
    expect(s.kind, RouteCardKind.ready);
    expect(s.isLoading, isFalse);
  });

  test('calculation running -> loading', () {
    final s = RouteCardState.resolve(hasRoute: false, isOptimizing: true);
    expect(s.isLoading, isTrue);
  });

  test('missing route data / timeout / error -> message with retry, no spinner', () {
    for (final String issue in <String>[
      'No remaining areas with usable coordinates.',
      'Route optimization request timed out. Please check your network and retry.',
      'Route optimization is temporarily unavailable.',
      'Waiting for your current GPS location.',
    ]) {
      final s = RouteCardState.resolve(hasRoute: false, isOptimizing: false, issue: issue);
      expect(s.kind, RouteCardKind.issue);
      expect(s.isLoading, isFalse);
      expect(s.canRetry, isTrue);
      expect(s.message, contains(issue));
      expect(s.message, contains('retry'));
    }
  });

  test('nothing attempted and nothing wrong -> idle prompt, tappable, not loading', () {
    final s = RouteCardState.resolve(hasRoute: false, isOptimizing: false);
    expect(s.kind, RouteCardKind.idle);
    expect(s.isLoading, isFalse);
    expect(s.canRetry, isTrue);
  });
}
