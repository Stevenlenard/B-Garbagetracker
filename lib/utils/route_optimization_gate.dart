/// Single-flight control for the driver's route optimization.
///
/// * one optimization at a time ([begin] refuses while one is running);
/// * an AUTOMATIC run happens at most once per input key (trip + area configuration + pending
///   areas). After it finished - success or failure - automatic triggers with the same key are
///   ignored, so a failure is never retried in a loop. Widget rebuilds and ordinary GPS
///   updates must not call it at all; a new key (new trip, areas or progress changed) allows
///   one new automatic run;
/// * a MANUAL run is allowed whenever nothing is running (one run per tap);
/// * [reset] (new trip) invalidates every pending run: results of older runs are rejected by
///   [isCurrent], so a stale response can never overwrite newer state;
/// * [manualCooldown]: minimum time between two MANUAL runs (repeated taps cannot turn into a
///   burst of billable requests). Zero by default.
class RouteOptimizationGate {
  RouteOptimizationGate({this.manualCooldown = Duration.zero, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Duration manualCooldown;
  final DateTime Function() _clock;
  DateTime? _lastManualStart;

  /// Time left before another manual run is accepted (zero when allowed now).
  Duration get manualWait {
    if (_lastManualStart == null || manualCooldown == Duration.zero) return Duration.zero;
    final Duration left = manualCooldown - _clock().difference(_lastManualStart!);
    return left.isNegative ? Duration.zero : left;
  }

  int _generation = 0;
  int? _running;
  final Set<String> _autoKeysTried = <String>{};

  bool get isRunning => _running != null;

  /// Whether an automatic trigger for [key] may start a run now.
  bool shouldAutoRun(String key) => !isRunning && !_autoKeysTried.contains(key);

  /// Starts a run and returns its token, or null when one is already running.
  /// [autoKey] marks the key as tried (automatic runs only).
  int? begin({String? autoKey}) {
    if (isRunning) return null;
    if (autoKey != null) {
      if (_autoKeysTried.contains(autoKey)) return null;
      _autoKeysTried.add(autoKey);
    } else {
      if (manualWait > Duration.zero) return null;
      _lastManualStart = _clock();
    }
    _generation++;
    _running = _generation;
    return _generation;
  }

  /// True when [token] is still the latest run (its result may be applied).
  bool isCurrent(int token) => token == _generation;

  /// Ends the run [token]. Returns whether its result may be applied.
  bool finish(int token) {
    if (_running == token) _running = null;
    return isCurrent(token);
  }

  /// New trip: forget tried keys and reject results of runs started before.
  void reset() {
    _generation++;
    _running = null;
    _autoKeysTried.clear();
  }
}
