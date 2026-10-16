/// What the driver's Route Optimization card shows.
///
/// The spinner is shown ONLY while a calculation is really running. "No route yet" is never a
/// loading state by itself: it is either an explained issue (with Retry) or an idle prompt.
/// [RouteCardKind.disabled]: route optimization is switched off (Matrix API off) - a fixed
/// notice without Retry, so nothing invites repeated attempts.
enum RouteCardKind { ready, loading, issue, idle, disabled }

class RouteCardState {
  const RouteCardState(this.kind, this.message);
  final RouteCardKind kind;
  final String message;

  static const String disabledMessage =
      'Live road routing is off in this version. Tap to view collection status and recorded-path comparison.';

  bool get isLoading => kind == RouteCardKind.loading;
  bool get canRetry => kind == RouteCardKind.issue || kind == RouteCardKind.idle;

  static RouteCardState resolve({
    required bool hasRoute,
    required bool isOptimizing,
    String? issue,
    bool disabled = false,
  }) {
    if (hasRoute) return const RouteCardState(RouteCardKind.ready, '');
    if (disabled) return const RouteCardState(RouteCardKind.disabled, disabledMessage);
    if (isOptimizing) {
      return const RouteCardState(RouteCardKind.loading, 'Optimizing road-network collection path...');
    }
    if (issue != null && issue.trim().isNotEmpty) {
      return RouteCardState(RouteCardKind.issue, '$issue Tap to retry.');
    }
    return const RouteCardState(RouteCardKind.idle, 'Tap to calculate the optimized collection path.');
  }
}
