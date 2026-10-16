import 'dart:async';

import 'driver_session_guard.dart';
import 'rtdb_port.dart';
import 'server_clock.dart';

/// Builds the transaction that merges live driver state into a node (the truck
/// node or the driver presence node) on behalf of ONE runtime.
///
/// The decision to write is made against the server's current value inside a
/// transaction, so a replaced runtime cannot overwrite a newer owner's data even
/// if its own local state is stale:
///
///  * the node carries `owner_epoch`; a runtime whose epoch is lower than the
///    node's aborts (it was replaced);
///  * a runtime with an equal or higher epoch commits and stamps its own
///    `owner_token`/`owner_epoch`, which is how a legitimate new owner takes the
///    node over.
class LiveStatePublisher {
  LiveStatePublisher._();

  static const String ownerTokenKey = 'owner_token';
  static const String ownerEpochKey = 'owner_epoch';
  static const String sequenceKey = 'wseq';

  static TxOutcome buildOutcome(
    Object? current,
    Map<String, Object?> fields, {
    required String token,
    required int epoch,
  }) {
    Map<String, Object?> base = <String, Object?>{};
    if (current is Map) {
      final Object? e = current[ownerEpochKey];
      final int nodeEpoch = e is num ? e.toInt() : 0;
      if (nodeEpoch > epoch) return const TxOutcome.abort();
      base = current.map((k, v) => MapEntry(k.toString(), v));
    }
    final Map<String, Object?> next = Map<String, Object?>.from(base);
    fields.forEach((k, v) {
      if (v == null) {
        next.remove(k);
      } else {
        next[k] = v;
      }
    });
    next[ownerTokenKey] = token;
    next[ownerEpochKey] = epoch;
    final Object? seq = base[sequenceKey];
    next[sequenceKey] = (seq is num ? seq.toInt() : 0) + 1;
    return TxOutcome.success(next);
  }
}

enum PublishResult { committed, notOwner, replaced, failed }

/// Serialised, latest-wins publisher for one node.
///
/// All runtime writes to a node go through here: Firebase cancels a pending
/// transaction when a plain `update()` hits the same location, so mixing them
/// would silently lose writes. Rapid calls are merged (newest value per key) and
/// sent as one transaction; nothing is delayed or polled.
class OwnedNodePublisher {
  OwnedNodePublisher({required this.db, required this.path, required this.guard, this.clock});

  final RtdbPort db;
  final String path;
  final DriverSessionGuard guard;

  /// When ready, server timestamps are carried INSIDE the guarded transaction as a
  /// server-clock estimate, which removes the follow-up `update` round trip.
  final ServerClock? clock;

  Map<String, Object?>? _pending;
  final List<Completer<PublishResult>> _waiters = <Completer<PublishResult>>[];
  bool _running = false;

  Future<PublishResult> publish(Map<String, Object?> fields) {
    if (!guard.canWrite) return Future<PublishResult>.value(PublishResult.notOwner);
    _pending = <String, Object?>{...?_pending, ...fields};
    final Completer<PublishResult> c = Completer<PublishResult>();
    _waiters.add(c);
    if (!_running) _drain();
    return c.future;
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_pending != null) {
        final Map<String, Object?> batch = _pending!;
        _pending = null;
        final List<Completer<PublishResult>> waiters = List<Completer<PublishResult>>.from(_waiters);
        _waiters.clear();
        PublishResult result;
        try {
          result = await _commit(batch);
        } catch (_) {
          result = PublishResult.failed;
        }
        for (final Completer<PublishResult> w in waiters) {
          if (!w.isCompleted) w.complete(result);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<PublishResult> _commit(Map<String, Object?> batch) async {
    if (!guard.canWrite) return PublishResult.notOwner;
    final int gen = guard.generation;
    final int epoch = guard.epoch;
    final Map<String, Object?> plain = <String, Object?>{};
    final List<String> stamped = <String>[];
    final bool inline = clock != null && clock!.ready;
    batch.forEach((k, v) {
      if (isServerTimestamp(v)) {
        if (inline) {
          plain[k] = clock!.nowMs();
        } else {
          stamped.add(k);
        }
      } else {
        plain[k] = v;
      }
    });

    bool replaced = false;
    final bool committed = await db.transaction(path, (cur) {
      final TxOutcome o = LiveStatePublisher.buildOutcome(cur, plain, token: guard.token, epoch: epoch);
      replaced = o.isAbort;
      return o;
    });

    if (committed) {
      // Server timestamps are applied right after the guarded commit; this is
      // not ownership-sensitive and avoids relying on server values inside a
      // transaction result.
      if (stamped.isNotEmpty && guard.isCurrent(gen)) {
        try {
          await db.update(path, <String, Object?>{for (final String k in stamped) k: kServerTimestamp});
        } catch (_) {}
      }
      return PublishResult.committed;
    }
    if (replaced) {
      // The node proves a newer owner exists: stop immediately.
      await guard.validate();
      return PublishResult.replaced;
    }
    return PublishResult.failed;
  }
}

enum WriteDenial { notOwner, noTrip, tripMismatch, tripFinished, finishing }

class WriteDecision {
  final bool allowed;
  final WriteDenial? denial;
  const WriteDecision.allow()
      : allowed = true,
        denial = null;
  const WriteDecision.deny(this.denial) : allowed = false;
}

/// Local pre-check applied before ANY GPS/route write. It never replaces the
/// server-side checks in [TripRouteWriter]; it just fails fast and cheaply.
class TripWriteGate {
  TripWriteGate._();

  static WriteDecision decide({
    required OwnershipState ownership,
    required String? localTripId,
    required String? boundTripId,
    required bool tripFinished,
    required bool finishing,
  }) {
    if (ownership != OwnershipState.owner) return const WriteDecision.deny(WriteDenial.notOwner);
    if (localTripId == null || localTripId.isEmpty) return const WriteDecision.deny(WriteDenial.noTrip);
    if (boundTripId != localTripId) return const WriteDecision.deny(WriteDenial.tripMismatch);
    if (tripFinished) return const WriteDecision.deny(WriteDenial.tripFinished);
    if (finishing) return const WriteDecision.deny(WriteDenial.finishing);
    return const WriteDecision.allow();
  }
}

class TripWriteResult {
  final bool written;
  final WriteDenial? denial;
  final bool failed;
  const TripWriteResult.written()
      : written = true,
        denial = null,
        failed = false;
  const TripWriteResult.denied(this.denial)
      : written = false,
        failed = false;
  const TripWriteResult.failed()
      : written = false,
        denial = null,
        failed = true;
}

/// Writes route points / trip metadata, guaranteeing the trip is not finished
/// at the moment of the write. `isFinished` is confirmed with a server-side
/// transaction before each write, so a completed trip stops growing even if this
/// runtime's local state is out of date.
class TripRouteWriter {
  TripRouteWriter({
    required this.db,
    required this.guard,
    this.root = 'driver_routes',
    this.verifyTtlMs = 5000,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final RtdbPort db;
  final DriverSessionGuard guard;
  final String root;

  /// The server-side `isFinished` transaction is repeated at most this often per
  /// trip for ordinary points (the trip-finished watcher covers the gap and the
  /// final point is always verified). 0 verifies before every write.
  final int verifyTtlMs;
  final int Function() _nowMs;
  String? _verifiedTrip;
  int _verifiedAt = 0;

  Future<TripWriteResult> write({
    required String tripId,
    required bool tripFinished,
    required bool finishing,
    Map<String, Object?>? point,
    Map<String, Object?>? meta,
  }) async {
    final WriteDecision d = TripWriteGate.decide(
      ownership: guard.state,
      localTripId: tripId,
      boundTripId: guard.tripId,
      tripFinished: tripFinished,
      finishing: finishing,
    );
    if (!d.allowed) return TripWriteResult.denied(d.denial);
    final int gen = guard.generation;

    final int now = _nowMs();
    final bool cached = !finishing &&
        verifyTtlMs > 0 &&
        _verifiedTrip == tripId &&
        now - _verifiedAt >= 0 &&
        now - _verifiedAt < verifyTtlMs;
    if (!cached) {
      bool finishedOnServer = false;
      final bool ok = await db.transaction('$root/$tripId/isFinished', (cur) {
        if (cur == true) {
          finishedOnServer = true;
          return const TxOutcome.abort();
        }
        return TxOutcome.success(cur);
      });
      if (!ok) {
        _verifiedTrip = null;
        return finishedOnServer ? const TripWriteResult.denied(WriteDenial.tripFinished) : const TripWriteResult.failed();
      }
      _verifiedTrip = tripId;
      _verifiedAt = now;
    }
    if (!guard.isCurrent(gen)) return const TripWriteResult.denied(WriteDenial.notOwner);

    if (point != null) await db.push('$root/$tripId/route', point);
    if (meta != null) await db.update('$root/$tripId', meta);
    return const TripWriteResult.written();
  }
}

enum FinishResult { finished, alreadyFinished, notOwner, failed }

class TripFinalizer {
  TripFinalizer._();

  /// Atomically marks the trip finished (exactly once), writes the completion
  /// fields, then unbinds the trip from this runtime so it holds no write
  /// authority for it any more.
  static Future<FinishResult> finish({
    required RtdbPort db,
    required DriverSessionGuard guard,
    required String tripId,
    required Map<String, Object?> fields,
    String root = 'driver_routes',
  }) async {
    if (!guard.canWrite) return FinishResult.notOwner;
    bool already = false;
    final bool ok = await db.transaction('$root/$tripId/isFinished', (cur) {
      if (cur == true) {
        already = true;
        return const TxOutcome.abort();
      }
      return const TxOutcome.success(true);
    });
    if (!ok) return already ? FinishResult.alreadyFinished : FinishResult.failed;
    await db.update('$root/$tripId', <String, Object?>{
      ...fields,
      'isFinished': true,
      'finished_by': guard.token,
    });
    await guard.bindTrip(null);
    return FinishResult.finished;
  }
}

enum ReconnectAction { ignore, assertPresence }

class ReconnectDecision {
  final ReconnectAction action;
  final String? statusToPublish;
  const ReconnectDecision.ignore()
      : action = ReconnectAction.ignore,
        statusToPublish = null;
  const ReconnectDecision.assertPresence(this.statusToPublish) : action = ReconnectAction.assertPresence;
}

class ReconnectPolicy {
  ReconnectPolicy._();

  /// Reconnecting restores connectivity only. It never reclaims ownership, never
  /// reopens a finished trip and never changes the collection status (FULL stays
  /// FULL, IDLE stays IDLE).
  static ReconnectDecision onReconnect({
    required OwnershipState ownership,
    required String status,
    required bool hasTrip,
  }) {
    if (ownership != OwnershipState.owner) return const ReconnectDecision.ignore();
    final String s = status.toUpperCase();
    if (s == 'COMPLETED' || s == 'FINISHED') return const ReconnectDecision.ignore();
    if (s == 'OFFLINE') return ReconnectDecision.assertPresence(hasTrip ? 'ACTIVE' : 'IDLE');
    return ReconnectDecision.assertPresence(s);
  }
}

enum RecoveredTrip { none, collecting, awaitingUnload }

class TripResumePolicy {
  TripResumePolicy._();

  /// A trip may be resumed only if it is this driver's, still ACTIVE, not
  /// finished and not a simulation. Finished/completed trips are never reopened.
  static bool isResumable(Object? trip, {required String driverId, int? nowMs}) =>
      classify(trip, driverId: driverId, nowMs: nowMs) == RecoveredTrip.collecting;

  /// What an unfinished trip of this driver is, for recovery after a restart or
  /// reconnect. A trip whose collection was finalized (FULL) is never reopened
  /// for collecting; it is restored as FULL, waiting for the unloading confirmation.
  static RecoveredTrip classify(
    Object? trip, {
    required String driverId,
    int? nowMs,
    int maxAgeMs = 43200000,
  }) {
    if (trip is! Map) return RecoveredTrip.none;
    // A trip older than the 12 h session limit belongs to an earlier working day: it
    // is left untouched (never silently adopted) and a new trip is created instead.
    final Object? startRaw = trip['server_start_time'] ?? trip['timestamp'];
    final int startMs = startRaw is num ? startRaw.toInt() : 0;
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (startMs > 0 && now - startMs > maxAgeMs) return RecoveredTrip.none;
    if (trip['isFinished'] == true || trip['finishTime'] != null || trip['end_time'] != null) {
      return RecoveredTrip.none;
    }
    if (trip['is_simulation'] == true || trip['isSimulation'] == true) return RecoveredTrip.none;
    if (trip['driver_id']?.toString() != driverId) return RecoveredTrip.none;
    final Object? rec = trip['collection'];
    final bool finalized = rec is Map && rec['finalized_at_ms'] != null;
    final String rs = (trip['route_status'] ?? '').toString().toUpperCase();
    if (finalized || trip['collection_finalized'] == true) return RecoveredTrip.awaitingUnload;
    if (rs == 'ACTIVE' || rs == 'IDLE' || rs == 'PAUSED') return RecoveredTrip.collecting;
    return RecoveredTrip.none;
  }

  /// Newest resumable trip among [candidates] (trip id -> trip map), or null.
  static String? pickNewest(Map<String, Object?> candidates, {required String driverId, int? nowMs}) {
    String? best;
    int bestStamp = -1;
    candidates.forEach((id, trip) {
      if (classify(trip, driverId: driverId, nowMs: nowMs) == RecoveredTrip.none) return;
      final Map t = trip as Map;
      final Object? raw = t['server_start_time'] ?? t['timestamp'];
      final int stamp = raw is num ? raw.toInt() : 0;
      if (stamp > bestStamp) {
        bestStamp = stamp;
        best = id;
      }
    });
    return best;
  }
}


enum CollectionFinalResult { finalized, alreadyFinalized, tripFinished, notOwner, failed }

/// The frozen collection record of a trip and the helpers that build it.
///
/// FULL freezes duration, distance, end position and estimated load into
/// `driver_routes/{trip}/collection` in ONE atomic transaction (set only if it does
/// not exist). Later GPS, unloading and landfill travel can never change it.
class CollectionRecord {
  CollectionRecord._();

  static Map<String, Object?> build({
    required int startMs,
    required int nowMs,
    required double distanceKm,
    required double weightKg,
    required String weightType,
    required String via,
    double? endLat,
    double? endLng,
  }) {
    final int durationS = nowMs > startMs ? ((nowMs - startMs) / 1000).round() : 0;
    return <String, Object?>{
      'finalized_at_ms': nowMs,
      'started_at_ms': startMs,
      'duration_s': durationS,
      'distance_km': double.parse(distanceKm.toStringAsFixed(3)),
      'weight_kg': weightKg,
      'weight_type': weightType,
      'finalized_via': via, // FULL | COMPLETED_WITHOUT_FULL
      if (endLat != null) 'end_lat': endLat,
      if (endLng != null) 'end_lng': endLng,
    };
  }

  /// Top-level trip fields kept for the existing consumers (Load History, Route
  /// History, Analytics read them), derived from the frozen record only.
  static Map<String, Object?> legacyFields(Map<dynamic, dynamic> record) {
    final Object? dist = record['distance_km'];
    return <String, Object?>{
      'route_status': 'FULL',
      'collection_finalized': true,
      'full_time_ms': record['finalized_at_ms'],
      'collection_duration_s': record['duration_s'],
      'collection_distance_km': dist,
      'total_distance': dist,
      'final_distance': dist,
      'weight_kg': record['weight_kg'],
      'weight_type': record['weight_type'],
      if (record['end_lat'] != null) 'finish_lat': record['end_lat'],
      if (record['end_lng'] != null) 'finish_lng': record['end_lng'],
    };
  }

  /// Fields written when the driver confirms unloading (COMPLETED). Collection
  /// distance/duration/load are NOT part of it: they stay as frozen at FULL.
  static Map<String, Object?> completionFields({
    required int nowMs,
    required String endTimeLabel,
    double? postFullDistanceKm,
    double? lat,
    double? lng,
  }) =>
      <String, Object?>{
        'route_status': 'COMPLETED',
        'unloading_confirmed_at_ms': nowMs,
        'end_time': endTimeLabel,
        if (postFullDistanceKm != null) 'post_full_distance_km': double.parse(postFullDistanceKm.toStringAsFixed(3)),
        if (lat != null) 'unload_lat': lat,
        if (lng != null) 'unload_lng': lng,
      };
}

class CollectionFinalizer {
  CollectionFinalizer._();

  /// Atomically freezes the collection record of [tripId] (exactly once), then
  /// mirrors it to the legacy top-level fields. Repeating the call (double tap,
  /// retry, duplicate request) never overwrites the record: it re-applies the
  /// stored one, which also repairs a first attempt that died half way.
  static Future<CollectionFinalResult> finalize({
    required RtdbPort db,
    required DriverSessionGuard guard,
    required String tripId,
    required Map<String, Object?> record,
    String root = 'driver_routes',
  }) async {
    if (!guard.canWrite) return CollectionFinalResult.notOwner;
    final Object? trip = await db.get('$root/$tripId');
    if (trip is Map && trip['isFinished'] == true) return CollectionFinalResult.tripFinished;

    Object? stored;
    final bool committed = await db.transaction('$root/$tripId/collection', (cur) {
      if (cur is Map && cur['finalized_at_ms'] != null) {
        stored = cur;
        return const TxOutcome.abort();
      }
      return TxOutcome.success(record);
    });
    if (!committed && stored == null) return CollectionFinalResult.failed;
    if (!guard.canWrite) return CollectionFinalResult.notOwner;

    final Map<dynamic, dynamic> authoritative = committed ? record : stored as Map;
    await db.update('$root/$tripId', <String, Object?>{
      ...CollectionRecord.legacyFields(authoritative),
      'collection_finalized_by': guard.token,
    });
    return committed ? CollectionFinalResult.finalized : CollectionFinalResult.alreadyFinalized;
  }
}


enum AutoStartDecision { wait, skip, start }

class AutoStartPolicy {
  AutoStartPolicy._();

  /// LOGIN opens the collection trip by itself. This decides, for every trigger
  /// (login, first GPS fix, reconnect, retry), whether to try now.
  ///
  ///  * [wait]  - not the session owner yet; try again on the next trigger;
  ///  * [skip]  - nothing to do: a trip is already bound to this runtime, or the
  ///              driver already confirmed COMPLETED in this login session (a new
  ///              collection then needs the explicit NEW TRIP action);
  ///  * [start] - resume the driver's unfinished trip or create exactly one new one.
  static AutoStartDecision decide({
    required bool ownerCanWrite,
    required bool hasLocalTrip,
    required bool completedThisLogin,
    required bool simulation,
  }) {
    if (simulation) return AutoStartDecision.skip;
    if (!ownerCanWrite) return AutoStartDecision.wait;
    if (hasLocalTrip) return AutoStartDecision.skip;
    if (completedThisLogin) return AutoStartDecision.skip;
    return AutoStartDecision.start;
  }
}


enum TripOpenStatus { created, resumed, restoredFull, notOwner, failed }

class TripOpenResult {
  const TripOpenResult(this.status, {this.tripId, this.trip});
  final TripOpenStatus status;
  final String? tripId;

  /// The stored trip when an existing one was resumed/restored.
  final Map<dynamic, dynamic>? trip;

  bool get ok =>
      status == TripOpenStatus.created || status == TripOpenStatus.resumed || status == TripOpenStatus.restoredFull;
}

/// Opens the driver's collection trip at LOGIN (idempotent).
///
///  * the driver's unfinished COLLECTING trip is resumed (same id, same start);
///  * a trip whose collection is already FULL is restored as FULL and never
///    reopened for collecting;
///  * a finished/COMPLETED, foreign, simulated or older-than-12 h trip is never
///    adopted: exactly one new trip is created under [newTripId];
///  * only the owner of the driver session can bind a trip, so two runtimes can
///    never hold two authoritative trips for one driver.
class TripOpener {
  TripOpener._();

  static Future<TripOpenResult> open({
    required RtdbPort db,
    required DriverSessionGuard guard,
    required String driverId,
    required String truckId,
    required String driverName,
    required String newTripId,
    required double startLat,
    required double startLng,
    required String startTimeLabel,
    double? startAccuracy,
    String? pendingTripId,
    String root = 'driver_routes',
    String runtime = 'mobile',
    String date = '',
    int? nowMs,
  }) async {
    if (!guard.canWrite) return const TripOpenResult(TripOpenStatus.notOwner);

    String tripId = newTripId;
    Map<dynamic, dynamic>? existing;
    RecoveredTrip kind = RecoveredTrip.none;
    if (pendingTripId != null) {
      try {
        final Object? v = await db.get('$root/$pendingTripId');
        kind = TripResumePolicy.classify(v, driverId: driverId, nowMs: nowMs);
        if (kind != RecoveredTrip.none && v is Map) {
          tripId = pendingTripId;
          existing = v;
        }
      } catch (_) {
        kind = RecoveredTrip.none;
      }
    }

    if (!await guard.bindTrip(tripId)) {
      return const TripOpenResult(TripOpenStatus.notOwner);
    }
    // Binding itself advances the guard generation, so ownership is re-checked
    // against the post-bind generation from here on.
    final int boundGen = guard.generation;
    if (!guard.isCurrent(boundGen)) return const TripOpenResult(TripOpenStatus.notOwner);

    try {
      if (existing == null) {
        // The trip record exists BEFORE anything points at it.
        await db.update('$root/$tripId', <String, Object?>{
          'truck_id': truckId,
          'driver_id': driverId,
          'driver_name': driverName,
          'start_time': startTimeLabel,
          'server_start_time': kServerTimestamp,
          'total_distance': 0.0,
          'route_status': 'ACTIVE',
          'isOnline': true,
          'is_simulation': root != 'driver_routes',
          'timestamp': kServerTimestamp,
          'date': date,
          'maintenanceProcessed': false,
          'start_lat': startLat,
          'start_lng': startLng,
          if (startAccuracy != null) 'start_accuracy': startAccuracy,
          'owner_token': guard.token,
          'runtime': runtime,
          'started_by': 'AUTO_LOGIN',
        });
        return TripOpenResult(TripOpenStatus.created, tripId: tripId);
      }
      await db.update('$root/$tripId', <String, Object?>{
        'owner_token': guard.token,
        'runtime': runtime,
        'resumed_at': kServerTimestamp,
        'isOnline': true,
      });
      return TripOpenResult(
        kind == RecoveredTrip.awaitingUnload ? TripOpenStatus.restoredFull : TripOpenStatus.resumed,
        tripId: tripId,
        trip: existing,
      );
    } catch (_) {
      // Temporary write failure: release the binding; the caller retries with the
      // SAME id, so no orphan trip is left behind.
      await guard.bindTrip(null);
      return TripOpenResult(TripOpenStatus.failed, tripId: tripId);
    }
  }
}
