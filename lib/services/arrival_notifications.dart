import 'rtdb_port.dart';

/// Arrival-stage notifications, written at most ONCE per truck trip, area and stage.
///
/// The record key is deterministic, so a restart, a resumed trip, a second runtime or
/// repeated GPS fixes can never create a second copy, while a NEW trip gets new keys and
/// its alerts are legitimate. Each record names its truck, trip, area and stage.
class ArrivalNotifications {
  ArrivalNotifications._();

  static String key({required String stage, required String tripId, required String areaKey}) {
    String clean(String v) => v.replaceAll(RegExp(r'[.$#\[\]/\s]'), '_');
    return 'arr_${clean(stage)}_${clean(tripId)}_${clean(areaKey)}';
  }

  /// Creates `notifications/{key}` only if it does not exist. Returns true when THIS call
  /// created it.
  static Future<bool> publishOnce({
    required RtdbPort db,
    required String stage,
    required String tripId,
    required String areaKey,
    required Map<String, Object?> payload,
    required int nowMs,
  }) async {
    final String k = key(stage: stage, tripId: tripId, areaKey: areaKey);
    return db.transaction('notifications/$k', (Object? current) {
      if (current != null) return const TxOutcome.abort();
      return TxOutcome.success(<String, Object?>{
        ...payload,
        'stage': stage,
        'trip_id': tripId,
        'area_key': areaKey,
        'timestamp': nowMs,
        'isRead': false,
      });
    });
  }
}
