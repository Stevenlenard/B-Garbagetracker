import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

/// Server-timestamp placeholder. Identical to Firebase's `ServerValue.timestamp`.
const Map<String, String> kServerTimestamp = <String, String>{'.sv': 'timestamp'};

bool isServerTimestamp(Object? value) =>
    value is Map && value.length == 1 && value['.sv'] == 'timestamp';

/// Result of a transaction handler: abort, or commit [value].
class TxOutcome {
  final bool isAbort;
  final Object? value;
  const TxOutcome.abort()
      : isAbort = true,
        value = null;
  const TxOutcome.success(this.value) : isAbort = false;
}

typedef TxHandler = TxOutcome Function(Object? current);

/// The small slice of the Realtime Database the driver-session logic needs.
///
/// Keeping it behind an interface lets the ownership, publishing and trip-write
/// rules be unit-tested against an in-memory fake that reproduces the server's
/// compare-and-set transaction semantics.
abstract class RtdbPort {
  /// Optimistic-concurrency transaction at [path]. The handler may run more than
  /// once; the commit is conditional on the server value the handler last saw.
  /// Returns true only if the new value was committed.
  Future<bool> transaction(String path, TxHandler handler);

  /// Emits the current value, then every change.
  Stream<Object?> watch(String path);

  /// Multi-key update; a null value deletes the key.
  Future<void> update(String path, Map<String, Object?> values);

  /// Appends [value] under a new push key at [path].
  Future<void> push(String path, Map<String, Object?> value);

  Future<Object?> get(String path);
}

/// [RtdbPort] backed by the real Firebase Realtime Database.
class FirebaseRtdbPort implements RtdbPort {
  FirebaseRtdbPort([FirebaseDatabase? database]) : _db = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _db;

  @override
  Future<bool> transaction(String path, TxHandler handler) async {
    final TransactionResult result = await _db.ref(path).runTransaction((Object? current) {
      final TxOutcome outcome = handler(current);
      return outcome.isAbort ? Transaction.abort() : Transaction.success(outcome.value);
    });
    return result.committed;
  }

  @override
  Stream<Object?> watch(String path) => _db.ref(path).onValue.map((e) => e.snapshot.value);

  @override
  Future<void> update(String path, Map<String, Object?> values) => _db.ref(path).update(values);

  @override
  Future<void> push(String path, Map<String, Object?> value) => _db.ref(path).push().set(value);

  @override
  Future<Object?> get(String path) async => (await _db.ref(path).get()).value;
}
