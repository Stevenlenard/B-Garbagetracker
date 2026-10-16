import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

/// Estimate of the Firebase server clock: device time + `.info/serverTimeOffset`.
///
/// Lets a guarded transaction carry a server-accurate `lastSeen` itself instead of
/// needing a second `update` with `ServerValue.timestamp` (one round trip less per
/// GPS fix). Until the offset is known [ready] is false and callers fall back to
/// server timestamps.
class ServerClock {
  ServerClock({int Function()? deviceNowMs})
      : _deviceNowMs = deviceNowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Process-wide clock, started once by the driver runtime.
  static final ServerClock instance = ServerClock();

  final int Function() _deviceNowMs;
  int? _offsetMs;
  StreamSubscription<DatabaseEvent>? _sub;

  bool get ready => _offsetMs != null;
  int? get offsetMs => _offsetMs;

  /// Server-time estimate in epoch milliseconds (device time until [ready]).
  int nowMs() => _deviceNowMs() + (_offsetMs ?? 0);

  void setOffset(int? offsetMs) => _offsetMs = offsetMs;

  void start([FirebaseDatabase? database]) {
    if (_sub != null) return;
    final FirebaseDatabase db = database ?? FirebaseDatabase.instance;
    _sub = db.ref('.info/serverTimeOffset').onValue.listen((DatabaseEvent e) {
      final Object? v = e.snapshot.value;
      if (v is num) _offsetMs = v.toInt();
    }, onError: (Object _) {});
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }
}
