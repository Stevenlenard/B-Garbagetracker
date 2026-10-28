import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../utils/eta_policy.dart';
import '../utils/predictive_models.dart';

/// Shares the arrival-time model between Analytics (which fits it on all recorded trips) and the apps that
/// estimate arrival times (driver alerts, resident dashboard), through `admin_settings/eta_model`.
class EtaModelSync {
  EtaModelSync._();

  static const String path = 'admin_settings/eta_model';
  static StreamSubscription<DatabaseEvent>? _sub;

  /// Keeps EtaPolicy.model up to date with the stored fit (once per app run; the defaults stay without one).
  static void start() {
    if (_sub != null) return;
    try {
      _sub = FirebaseDatabase.instance.ref(path).onValue.listen((DatabaseEvent e) {
        final EtaModel? m = EtaModel.fromJson(e.snapshot.value);
        if (m != null) EtaPolicy.model = m;
      }, onError: (_) {});
    } catch (_) {}
  }

  /// Stores the fit of [report] when it rests on enough samples and differs from the stored one.
  static Future<void> publish(ArrivalRegressionReport report) async {
    final LinearFit? fit = report.fit;
    if (fit == null || report.samples < 10) return;
    final EtaModel? m = EtaModel.fromJson(<String, Object?>{'intercept': fit.intercept, 'slope': fit.slope, 'samples': report.samples});
    if (m == null) return;
    final EtaModel cur = EtaPolicy.model;
    if ((cur.intercept - m.intercept).abs() < 0.01 && (cur.slope - m.slope).abs() < 0.01 && cur.samples == m.samples) return;
    try {
      await FirebaseDatabase.instance.ref(path).set(<String, Object?>{
        'intercept': double.parse(m.intercept.toStringAsFixed(3)),
        'slope': double.parse(m.slope.toStringAsFixed(3)),
        'samples': report.samples,
        'trips': report.trips,
        'fitted_at': ServerValue.timestamp,
      });
      EtaPolicy.model = m;
    } catch (_) {}
  }
}
