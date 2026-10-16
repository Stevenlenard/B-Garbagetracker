import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/notification_inbox.dart';
import '../utils/relative_time.dart';

/// Shared notification center for Admin, Driver and Resident.
///
/// Frosted-glass panel (dialog on wide screens, bottom sheet on phones):
///  - swipe an item left OR right to remove it (Undo in the snackbar),
///  - "Clear all" (confirmed), "Mark all read", All / Unread filter,
///  - grouped Today / Yesterday / Earlier, colour-coded by alert type, live updates.
/// Removing and clearing are per user ([NotificationInbox]); the shared log is never edited.
Future<void> showNotificationCenter(
  BuildContext context, {
  required Stream<Object?> source,
  required bool Function(Map item) isRelevant,
  required NotificationInbox inbox,
  void Function(Map item)? onOpen,
  String title = 'Notifications',
}) async {
  final bool wide = MediaQuery.sizeOf(context).width >= 700;
  final Widget panel = NotificationCenter(source: source, isRelevant: isRelevant, inbox: inbox, onOpen: onOpen, title: title, asSheet: !wide);
  if (wide) {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close notifications',
      barrierColor: Colors.black.withValues(alpha: 0.28),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (BuildContext ctx, _, __) => BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460, maxHeight: MediaQuery.sizeOf(ctx).height * 0.82),
            child: Padding(padding: const EdgeInsets.all(16), child: panel),
          ),
        ),
      ),
      transitionBuilder: (BuildContext ctx, Animation<double> a, _, Widget child) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
        child: ScaleTransition(scale: Tween<double>(begin: 0.96, end: 1).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (BuildContext ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.86, child: panel),
    );
  }
}

/// Look and grouping of one notification (pure, testable).
class NotificationStyle {
  const NotificationStyle(this.icon, this.color, this.label);
  final IconData icon;
  final Color color;
  final String label;

  static NotificationStyle of(Map n) {
    final String t = (n['type'] ?? '').toString().toUpperCase();
    if (t == 'AUTO_ARRIVAL') return const NotificationStyle(Icons.where_to_vote_rounded, Color(0xFF2E7D32), 'Arrived');
    if (t == 'AUTO_APPROACH' || t == 'TRUCK_PROXIMITY') return const NotificationStyle(Icons.local_shipping_rounded, Color(0xFFEF6C00), 'Approaching');
    if (t == 'MANUAL_ALERT' || t == 'COLLECTION_ALERT') return const NotificationStyle(Icons.campaign_rounded, Color(0xFF00796B), 'Driver alert');
    if (t == 'COLLECTION_REMINDER') return const NotificationStyle(Icons.event_available_rounded, Color(0xFF1565C0), 'Reminder');
    if (t == 'COMPLAINT_RESOLVED') return const NotificationStyle(Icons.task_alt_rounded, Color(0xFF2E7D32), 'Resolved');
    if (t.contains('COMPLAINT')) return const NotificationStyle(Icons.feedback_rounded, Color(0xFF7B1FA2), 'Complaint');
    if (t.contains('REGISTRATION')) return const NotificationStyle(Icons.person_add_alt_1_rounded, Color(0xFF1E88E5), 'Account');
    if (t.contains('ISSUE')) return const NotificationStyle(Icons.build_circle_rounded, Color(0xFFD32F2F), 'Truck issue');
    if (t.contains('FULL') || t.contains('UNLOAD')) return const NotificationStyle(Icons.delete_rounded, Color(0xFFC62828), 'Truck full');
    return const NotificationStyle(Icons.notifications_rounded, Color(0xFF00796B), 'Update');
  }

  static int timestamp(Map n) {
    final Object? t = n['timestamp'];
    return t is num ? t.toInt() : int.tryParse('${t ?? ''}') ?? 0;
  }

  /// "Today" / "Yesterday" / "Earlier" relative to [now].
  static String group(Map n, DateTime now) {
    final int ms = timestamp(n);
    if (ms <= 0) return 'Earlier';
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
    final int days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    return days <= 0 ? 'Today' : (days == 1 ? 'Yesterday' : 'Earlier');
  }

  /// Same wording as everywhere else in the app ("5 minutes ago", "Yesterday", ...).
  static String ago(Map n, DateTime now) => RelativeTime.format(timestamp(n), nowMs: now.millisecondsSinceEpoch);

}

class NotificationCenter extends StatefulWidget {
  const NotificationCenter({
    super.key,
    required this.source,
    required this.isRelevant,
    required this.inbox,
    this.onOpen,
    this.title = 'Notifications',
    this.asSheet = false,
    this.clock,
  });

  final Stream<Object?> source;
  final bool Function(Map item) isRelevant;
  final NotificationInbox inbox;
  final void Function(Map item)? onOpen;
  final String title;
  final bool asSheet;
  final DateTime Function()? clock;

  @override
  State<NotificationCenter> createState() => _NotificationCenterState();
}

class _NotificationCenterState extends State<NotificationCenter> {
  static const Color _teal = Color(0xFF00796B);
  static const Color _ink = Color(0xFF1A2B3C);
  static const Color _muted = Color(0xFF64748B);

  StreamSubscription<Object?>? _srcSub;
  StreamSubscription<InboxState>? _inboxSub;
  List<Map> _relevant = const <Map>[];
  InboxState _state = InboxState.empty;
  bool _loaded = false;
  bool _unreadOnly = false;

  /// Removed in this session before the inbox write comes back (instant, no flicker).
  final Set<String> _hiddenNow = <String>{};
  int _clearedNow = 0;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _srcSub = widget.source.listen((Object? v) {
      final List<Map> list = <Map>[];
      if (v is Map) {
        v.forEach((Object? k, Object? val) {
          if (val is Map && widget.isRelevant(val)) list.add(<Object?, Object?>{...val, 'key': k.toString()});
        });
      }
      list.sort((Map a, Map b) => NotificationStyle.timestamp(b).compareTo(NotificationStyle.timestamp(a)));
      if (mounted) setState(() {
        _relevant = list;
        _loaded = true;
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _loaded = true);
    });
    _inboxSub = widget.inbox.watch().listen((InboxState s) {
      if (mounted) setState(() => _state = s);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    // Everything that was on screen is now read for this user.
    final List<String> keys = _visible.map((Map n) => n['key'].toString()).toList();
    if (keys.isNotEmpty) widget.inbox.markRead(keys);
    _srcSub?.cancel();
    _inboxSub?.cancel();
    super.dispose();
  }

  List<Map> get _visible => NotificationInbox.visible(_relevant, _state)
      .where((Map n) => !_hiddenNow.contains(n['key'].toString()) && NotificationStyle.timestamp(n) > _clearedNow)
      .toList();

  bool _isUnread(Map n) => !_state.read.contains(n['key'].toString());

  Future<void> _remove(Map n) async {
    final String key = n['key'].toString();
    setState(() => _hiddenNow.add(key));
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    await widget.inbox.dismiss(key);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      content: const Text('Notification removed'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: 'UNDO',
        onPressed: () async {
          await widget.inbox.undismiss(key);
          if (mounted) setState(() => _hiddenNow.remove(key));
        },
      ),
    ));
  }

  Future<void> _clearAll() async {
    final List<Map> now = _visible;
    if (now.isEmpty) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        icon: const Icon(Icons.delete_sweep_rounded, color: Color(0xFFD32F2F), size: 36),
        title: const Text('Clear all notifications?', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text('This removes ${now.length} notification${now.length == 1 ? '' : 's'} from your list. New ones will still appear.', textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearedNow = now.map(NotificationStyle.timestamp).fold<int>(0, (int a, int b) => b > a ? b : a));
    await widget.inbox.clearAll(now);
  }

  Future<void> _markAllRead() async {
    final List<String> keys = _visible.map((Map n) => n['key'].toString()).toList();
    await widget.inbox.markRead(keys);
  }

  void _open(Map n) {
    widget.inbox.markRead(<String>[n['key'].toString()]);
    if (widget.onOpen == null) return;
    Navigator.of(context).pop();
    widget.onOpen!(n);
  }

  @override
  Widget build(BuildContext context) {
    final List<Map> all = _visible;
    final List<Map> shown = _unreadOnly ? all.where(_isUnread).toList() : all;
    final int unread = all.where(_isUnread).length;
    final BorderRadius r = widget.asSheet ? const BorderRadius.vertical(top: Radius.circular(30)) : BorderRadius.circular(30);
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Colors.white.withValues(alpha: 0.93), const Color(0xFFF1F8F7).withValues(alpha: 0.9)],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.4),
              boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x33000000), blurRadius: 40, offset: Offset(0, 16))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              _header(all.length, unread),
              _toolbar(all.isNotEmpty, unread),
              Flexible(child: _list(shown)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _header(int total, int unread) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, widget.asSheet ? 10 : 18, 10, 16),
      decoration: const BoxDecoration(gradient: LinearGradient(colors: <Color>[Color(0xFF00897B), Color(0xFF00695C)])),
      child: Column(children: <Widget>[
        if (widget.asSheet)
          Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.white54, borderRadius: BorderRadius.circular(4))),
        Row(children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.notifications_active_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: <Widget>[
              Text(widget.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: -0.3)),
              const SizedBox(height: 2),
              Text(
                total == 0 ? 'You are all caught up' : (unread > 0 ? '$unread unread · $total total' : '$total notification${total == 1 ? '' : 's'}'),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ]),
          ),
          IconButton(onPressed: () => Navigator.of(context).maybePop(), tooltip: 'Close', icon: const Icon(Icons.close_rounded, color: Colors.white)),
        ]),
      ]),
    );
  }

  Widget _toolbar(bool hasItems, int unread) {
    Widget chip(String label, bool selected, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            label: Text(label),
            selected: selected,
            onSelected: (_) => onTap(),
            showCheckmark: false,
            labelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: selected ? Colors.white : _ink),
            selectedColor: _teal,
            backgroundColor: Colors.white,
            side: BorderSide(color: selected ? _teal : const Color(0xFFDDE5EA)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            visualDensity: VisualDensity.compact,
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
      child: Row(children: <Widget>[
        chip('All', !_unreadOnly, () => setState(() => _unreadOnly = false)),
        chip(unread > 0 ? 'Unread ($unread)' : 'Unread', _unreadOnly, () => setState(() => _unreadOnly = true)),
        const Spacer(),
        if (unread > 0)
          IconButton(onPressed: _markAllRead, tooltip: 'Mark all read', icon: const Icon(Icons.done_all_rounded, color: _teal, size: 20)),
        TextButton.icon(
          key: const ValueKey<String>('notif-clear-all'),
          onPressed: hasItems ? _clearAll : null,
          icon: const Icon(Icons.delete_sweep_rounded, size: 18),
          label: const Text('Clear all'),
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFD32F2F), textStyle: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }

  Widget _list(List<Map> items) {
    if (!_loaded) return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator(color: _teal)));
    if (items.isEmpty) return _empty();
    final DateTime now = _now();
    final List<Widget> rows = <Widget>[];
    String? group;
    for (final Map n in items) {
      final String g = NotificationStyle.group(n, now);
      if (g != group) {
        group = g;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
          child: Text(g.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _muted, letterSpacing: 1.1)),
        ));
      }
      rows.add(_item(n, now));
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
      children: <Widget>[
        ...rows,
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('Swipe left or right to remove', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _swipeBg(Alignment a) => Container(
        alignment: a,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: a == Alignment.centerLeft ? Alignment.centerLeft : Alignment.centerRight,
            end: a == Alignment.centerLeft ? Alignment.centerRight : Alignment.centerLeft,
            colors: const <Color>[Color(0xFFE53935), Color(0xFFFF8A80)],
          ),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Icon(Icons.delete_outline_rounded, color: Colors.white),
          SizedBox(width: 6),
          Text('Remove', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _item(Map n, DateTime now) {
    final NotificationStyle st = NotificationStyle.of(n);
    final bool unread = _isUnread(n);
    final String title = (n['title'] ?? st.label).toString();
    final String msg = (n['message'] ?? n['body'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey<String>('notif-${n['key']}'),
        direction: DismissDirection.horizontal,
        background: _swipeBg(Alignment.centerLeft),
        secondaryBackground: _swipeBg(Alignment.centerRight),
        onDismissed: (_) => _remove(n),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _open(n),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              decoration: BoxDecoration(
                color: unread ? Colors.white : Colors.white.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: unread ? st.color.withValues(alpha: 0.35) : const Color(0xFFE6EDF1)),
                boxShadow: unread ? <BoxShadow>[BoxShadow(color: st.color.withValues(alpha: 0.12), blurRadius: 14, offset: const Offset(0, 5))] : null,
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: <Color>[st.color.withValues(alpha: 0.18), st.color.withValues(alpha: 0.08)]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(st.icon, color: st.color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Row(children: <Widget>[
                      Expanded(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: unread ? FontWeight.w900 : FontWeight.w700, fontSize: 14, color: _ink)),
                      ),
                      const SizedBox(width: 8),
                      Text(NotificationStyle.ago(n, now), style: const TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w600)),
                    ]),
                    if (msg.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(msg, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, height: 1.35, color: Color(0xFF475569))),
                    ],
                    const SizedBox(height: 6),
                    Row(children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: st.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                        child: Text(st.label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: st.color)),
                      ),
                      if (unread) ...<Widget>[
                        const SizedBox(width: 6),
                        Container(width: 7, height: 7, decoration: const BoxDecoration(color: Color(0xFF1E88E5), shape: BoxShape.circle)),
                      ],
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 48),
      child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: <Color>[_teal.withValues(alpha: 0.16), _teal.withValues(alpha: 0.05)]),
          ),
          child: const Icon(Icons.notifications_off_rounded, size: 38, color: _teal),
        ),
        const SizedBox(height: 16),
        Text(_unreadOnly ? 'No unread notifications' : 'No notifications', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _ink)),
        const SizedBox(height: 4),
        const Text('New alerts will appear here.', style: TextStyle(color: _muted, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
