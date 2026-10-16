import 'rtdb_port.dart';

/// What one user has done with the shared notification feed.
///
/// The `notifications` node is an OPERATIONAL LOG shared by everyone (analytics and
/// auditing read it). Reading, dismissing and "Clear all" therefore never touch it: they
/// are recorded per user under `notification_inbox/{role}_{userId}`.
class InboxState {
  const InboxState({this.clearedBeforeMs = 0, this.dismissed = const <String>{}, this.read = const <String>{}});

  /// "Clear all" hides every notification stamped at or before this server time.
  final int clearedBeforeMs;
  final Set<String> dismissed;
  final Set<String> read;

  static const InboxState empty = InboxState();

  factory InboxState.fromValue(Object? v) {
    if (v is! Map) return empty;
    Set<String> keys(Object? m) => m is Map ? m.keys.map((Object? k) => k.toString()).toSet() : <String>{};
    final Object? c = v['cleared_before_ms'];
    return InboxState(
      clearedBeforeMs: c is num ? c.toInt() : 0,
      dismissed: keys(v['dismissed']),
      read: keys(v['read']),
    );
  }
}

class NotificationInbox {
  NotificationInbox({required this.db, required String role, required Object userId})
      : _owner = '${role.toLowerCase()}_${userId.toString()}';

  final RtdbPort db;
  final String _owner;

  String get path => 'notification_inbox/$_owner';

  Stream<InboxState> watch() => db.watch(path).map(InboxState.fromValue);

  Future<InboxState> load() async => InboxState.fromValue(await db.get(path));

  /// Notifications the user can still see: relevant ones minus dismissed/cleared.
  static List<Map> visible(Iterable<Map> relevant, InboxState s) {
    return relevant.where((Map n) {
      final String key = '${n['key'] ?? n['id'] ?? ''}';
      if (key.isEmpty || s.dismissed.contains(key)) return false;
      return _ts(n) > s.clearedBeforeMs;
    }).toList();
  }

  /// Unread = visible and not read BY THIS USER (another user's read state is irrelevant).
  static int unreadCount(Iterable<Map> visibleList, InboxState s) =>
      visibleList.where((Map n) => !s.read.contains('${n['key'] ?? n['id'] ?? ''}')).length;

  static int _ts(Map n) {
    final Object? t = n['timestamp'];
    return t is num ? t.toInt() : int.tryParse('${t ?? ''}') ?? 0;
  }

  Future<void> markRead(Iterable<String> keys) async {
    final Map<String, Object?> updates = <String, Object?>{
      for (final String k in keys.where((String k) => k.isNotEmpty)) 'read/${_safe(k)}': true,
    };
    if (updates.isEmpty) return;
    await db.update(path, updates);
  }

  Future<void> dismiss(String key) async {
    if (key.isEmpty) return;
    await db.update(path, <String, Object?>{'dismissed/${_safe(key)}': true});
  }

  /// Undo of [dismiss].
  Future<void> undismiss(String key) async {
    if (key.isEmpty) return;
    await db.update(path, <String, Object?>{'dismissed/${_safe(key)}': null});
  }

  /// Hides everything this user currently sees. Uses the newest visible server
  /// timestamp (not the device clock), so later notifications are never hidden.
  Future<void> clearAll(Iterable<Map> visibleNow) async {
    int newest = 0;
    for (final Map n in visibleNow) {
      final int t = _ts(n);
      if (t > newest) newest = t;
    }
    if (newest == 0) return;
    await db.update(path, <String, Object?>{'cleared_before_ms': newest});
  }

  static String _safe(String key) => key.replaceAll(RegExp(r'[.$#\[\]/]'), '_');
}
