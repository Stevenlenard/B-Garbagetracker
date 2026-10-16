import 'dart:async';
import 'dart:math';

import 'rtdb_port.dart';

/// Whether this driver runtime currently holds write authority.
enum OwnershipState { unclaimed, owner, lost }

/// The authoritative per-driver session record stored at `driver_sessions/{driverId}`.
///
/// Runtime identity (`token`) is deliberately separate from trip identity
/// (`tripId`): a runtime may be restarted and resume the same trip, but only the
/// runtime whose token is on this record may publish for it.
class SessionRecord {
  final String? token;
  final String? truckId;
  final String? tripId;
  final String? runtime;

  /// Increases by one on every takeover; lets nodes written by the owner reject
  /// writes from any runtime with a smaller epoch (a stale, replaced runtime).
  final int epoch;

  const SessionRecord({this.token, this.truckId, this.tripId, this.runtime, this.epoch = 0});

  static SessionRecord? fromValue(Object? value) {
    if (value is! Map) return null;
    String? s(Object? v) => (v == null || v.toString().isEmpty) ? null : v.toString();
    return SessionRecord(
      token: s(value['token']),
      truckId: s(value['truck_id']),
      tripId: s(value['trip_id']),
      runtime: s(value['runtime']),
      epoch: value['epoch'] is num ? (value['epoch'] as num).toInt() : 0,
    );
  }
}

/// Pure transaction handlers. Each is a compare-and-set against the current
/// server value, so two runtimes can never both believe they won.
class OwnershipRules {
  OwnershipRules._();

  /// Takeover: the newest runtime to start always becomes the owner, and the
  /// previous owner's token is recorded. Atomic, so concurrent claims serialize.
  static TxOutcome claim(
    Object? current, {
    required String token,
    required String driverId,
    required String truckId,
    required String runtime,
  }) {
    String? displaced;
    int epoch = 1;
    if (current is Map) {
      if (current['token'] != null && current['token'].toString() != token) {
        displaced = current['token'].toString();
      }
      final Object? prev = current['epoch'];
      epoch = (prev is num ? prev.toInt() : 0) + 1;
    }
    return TxOutcome.success(<String, Object?>{
      'token': token,
      'epoch': epoch,
      'driver_id': driverId,
      'truck_id': truckId,
      'trip_id': null,
      'runtime': runtime,
      'claimed_at': kServerTimestamp,
      if (displaced != null) 'displaced_token': displaced,
    });
  }

  /// Read-only check made authoritative by a no-op transaction: commits only if
  /// the server still lists [token] as the owner.
  static TxOutcome validate(Object? current, {required String token}) {
    if (current is Map && current['token']?.toString() == token) return TxOutcome.success(current);
    return const TxOutcome.abort();
  }

  /// Binds (or, with a null [tripId], unbinds) the trip, only for the owner.
  static TxOutcome bindTrip(Object? current, {required String token, required String? tripId}) {
    if (current is! Map || current['token']?.toString() != token) return const TxOutcome.abort();
    final Map<String, Object?> next = Map<String, Object?>.from(current);
    next['trip_id'] = tripId;
    next['trip_bound_at'] = kServerTimestamp;
    return TxOutcome.success(next);
  }

  /// Releases authority only if this runtime still owns it, so logging out can
  /// never erase a newer runtime's authority. The record is NOT deleted: it keeps
  /// its `epoch` (a tombstone), because the epoch must stay monotonic across
  /// logouts; otherwise the next login would restart at 1 and be rejected by a
  /// truck node still stamped with a higher epoch.
  static TxOutcome release(Object? current, {required String token}) {
    if (current is Map && current['token']?.toString() == token) {
      return TxOutcome.success(<String, Object?>{
        'epoch': current['epoch'],
        'driver_id': current['driver_id'],
        'truck_id': current['truck_id'],
        'released_at': kServerTimestamp,
      });
    }
    return const TxOutcome.abort();
  }
}

String generateRuntimeToken(String driverId, {Random? random}) {
  final Random r = random ?? Random.secure();
  final String hex = List<String>.generate(12, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  return '$driverId-$hex';
}

/// Authoritative runtime ownership for one driver.
///
/// * [claim] is an atomic takeover (used at login): the newest runtime wins and
///   every older runtime loses write authority the moment its listener (or its
///   next validating write) sees the new token.
/// * Reconnecting never reclaims: the runtime only re-validates ([validate]).
/// * [generation] changes on every ownership or trip change so delayed async
///   callbacks can detect that they are stale.
///
/// Without Firebase Auth and security rules this is cooperative: a client that
/// does not run this code (an older APK) can still write. See the design notes.
class DriverSessionGuard {
  /// The guard of the driver runtime that is on screen, for code outside the
  /// dashboard (settings logout, truck handover) that must not write when obsolete.
  static DriverSessionGuard? active;
  static bool get activeCanWrite => active?.canWrite ?? false;

  DriverSessionGuard({
    required this.db,
    required this.driverId,
    required this.runtimeLabel,
    String? token,
  }) : token = token ?? generateRuntimeToken(driverId);

  final RtdbPort db;
  final String driverId;
  final String runtimeLabel;
  final String token;

  OwnershipState _state = OwnershipState.unclaimed;
  int _generation = 0;
  String? _truckId;
  String? _tripId;
  int _epoch = 0;
  StreamSubscription<Object?>? _watch;
  final StreamController<OwnershipState> _changes = StreamController<OwnershipState>.broadcast(sync: true);

  String get path => 'driver_sessions/$driverId';
  OwnershipState get state => _state;
  bool get canWrite => _state == OwnershipState.owner;
  int get generation => _generation;
  String? get truckId => _truckId;

  /// Ownership epoch of the last successful claim (0 before any claim).
  int get epoch => _epoch;

  /// The trip this runtime is currently authorised to write to, if any.
  String? get tripId => _tripId;

  Stream<OwnershipState> get changes => _changes.stream;

  /// True while [gen] is still the current generation and this runtime owns the session.
  bool isCurrent(int gen) => gen == _generation && canWrite;

  /// Runs [handler] as a transaction. `lostToOther` is true only when the handler
  /// itself aborted, i.e. the server record proves another runtime owns the
  /// session. A commit failure without that (network, cancelled) is transient and
  /// must not be treated as lost ownership.
  Future<({bool committed, bool lostToOther})> _tx(TxHandler handler) async {
    bool handlerAborted = false;
    final bool committed = await db.transaction(path, (cur) {
      final TxOutcome o = handler(cur);
      handlerAborted = o.isAbort;
      return o;
    });
    return (committed: committed, lostToOther: !committed && handlerAborted);
  }

  void _setState(OwnershipState next) {
    if (_state == next) return;
    _state = next;
    _generation++;
    _changes.add(next);
  }

  /// Atomic takeover. Returns true if this runtime is now the owner.
  Future<bool> claim({required String truckId}) async {
    int claimedEpoch = 0;
    final r = await _tx((cur) {
      final TxOutcome o = OwnershipRules.claim(cur, token: token, driverId: driverId, truckId: truckId, runtime: runtimeLabel);
      // The handler may run more than once; the last run is the committed one.
      final Object? v = o.value;
      if (v is Map && v['epoch'] is num) claimedEpoch = (v['epoch'] as num).toInt();
      return o;
    });
    if (!r.committed) {
      // A claim never aborts by rule, so this is a transient failure: no authority.
      return false;
    }
    _truckId = truckId;
    _tripId = null;
    _epoch = claimedEpoch;
    _generation++;
    _setState(OwnershipState.owner);
    // Confirm the outcome from the server's current record before reporting
    // success: a concurrent claim that committed after ours must win cleanly.
    await _startWatching().timeout(const Duration(seconds: 3), onTimeout: () {});
    return canWrite;
  }

  /// Re-checks ownership against the server (used on reconnect). Never reclaims.
  /// Returns false when ownership is lost OR the check could not complete.
  Future<bool> validate() async {
    if (_state != OwnershipState.owner) return false;
    final r = await _tx((cur) => OwnershipRules.validate(cur, token: token));
    if (r.lostToOther) _setState(OwnershipState.lost);
    return r.committed;
  }

  /// Binds this runtime to [tripId] (null = no trip). Fails if ownership was lost.
  Future<bool> bindTrip(String? tripId) async {
    if (_state != OwnershipState.owner) return false;
    final r = await _tx((cur) => OwnershipRules.bindTrip(cur, token: token, tripId: tripId));
    if (!r.committed) {
      if (r.lostToOther) _setState(OwnershipState.lost);
      return false;
    }
    _tripId = tripId;
    _generation++;
    return true;
  }

  /// Releases authority (logout). Only removes the record if still the owner.
  Future<void> release() async {
    final bool wasOwner = _state == OwnershipState.owner;
    // Local revocation first, so nothing in flight can still publish.
    _setState(OwnershipState.unclaimed);
    _tripId = null;
    await _watch?.cancel();
    _watch = null;
    if (wasOwner) {
      try {
        await db.transaction(path, (cur) => OwnershipRules.release(cur, token: token));
      } catch (_) {
        // Best effort: the record is simply replaced by the next login's claim.
      }
    }
  }

  /// Starts listening to the session record. The returned future completes after
  /// the first event, i.e. once the current server record has been evaluated.
  Future<void> _startWatching() {
    _watch?.cancel();
    final Completer<void> first = Completer<void>();
    _watch = db.watch(path).listen((Object? value) {
      if (_state == OwnershipState.owner) {
        final SessionRecord? record = SessionRecord.fromValue(value);
        if (record == null || record.token != token) {
          _setState(OwnershipState.lost);
        }
      }
      if (!first.isCompleted) first.complete();
    });
    return first.future;
  }

  Future<void> dispose() async {
    if (identical(active, this)) active = null;
    await _watch?.cancel();
    _watch = null;
    await _changes.close();
  }
}
