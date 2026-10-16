import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chatbot/faq_bot.dart';
import '../chatbot/fleet_snapshot.dart';
import '../api/api_service.dart';
import '../services/collection_schedule_service.dart';
import '../services/service_area_service.dart';
import '../screens/collection_route_optimization_screen.dart' show FirebaseCollectionDataSource;
import '../utils/collection_visits.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import '../utils/session_manager.dart';

/// Floating "Truck Buddy" help button + chat panel. Must be placed directly in a Stack: it returns
/// a Positioned.fill (empty areas let taps through) so it never affects the size of that Stack.
///
/// The button can be dragged anywhere; its spot is remembered per role on this device.
/// [right] / [bottom] are only the starting spot before the user moves it.
class TruckChatLauncher extends StatefulWidget {
  final String? role;
  final void Function(BotAction action)? onAction;
  final double right;
  final double bottom;

  /// Live fleet for questions like "how many trucks are online?". Defaults to the shared
  /// truck feed the maps use; tests pass their own stream (or an empty one).
  final Stream<FleetSnapshot>? fleet;

  /// The signed-in resident's purok (their schedule is answered first).
  final String? purok;

  /// Tests: data sources (defaults: Firebase schedule stream, get_public_stats.php).
  final Stream<Map<String, CollectionSchedule>>? schedules;
  final Future<PublicStats?> Function()? loadStats;

  const TruckChatLauncher({
    super.key,
    required this.role,
    this.onAction,
    this.right = 24,
    this.bottom = 24,
    this.fleet,
    this.purok,
    this.schedules,
    this.loadStats,
  });

  /// Forgets remembered button spots and conversations (tests start fresh).
  @visibleForTesting
  static void debugResetSpots() {
    _TruckChatLauncherState._savedSpot.clear();
    _ChatHistory.resetMemory();
  }

  @override
  State<TruckChatLauncher> createState() => _TruckChatLauncherState();
}

class _ChatMessage {
  final bool fromUser;
  final String text;
  final BotAction? action;
  final String? actionLabel;
  final List<String> suggestions;
  final bool restricted;
  final DateTime at;

  _ChatMessage({required this.fromUser, required this.text, this.action, this.actionLabel, this.suggestions = const <String>[], this.restricted = false, DateTime? at})
      : at = at ?? DateTime.now();

  Map<String, Object?> toJson() => <String, Object?>{
        'u': fromUser,
        't': text,
        if (action != null) 'a': action!.name,
        if (actionLabel != null) 'l': actionLabel,
        if (suggestions.isNotEmpty) 's': suggestions,
        if (restricted) 'r': true,
        'at': at.millisecondsSinceEpoch,
      };

  static _ChatMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    final String? text = j['t'] as String?;
    if (text == null) return null;
    BotAction? action;
    for (final BotAction a in BotAction.values) {
      if (a.name == j['a']) action = a;
    }
    return _ChatMessage(
      fromUser: j['u'] == true,
      text: text,
      action: action,
      actionLabel: j['l'] as String?,
      suggestions: (j['s'] is List) ? (j['s'] as List).map((Object? e) => '$e').toList() : const <String>[],
      restricted: j['r'] == true,
      at: j['at'] is int ? DateTime.fromMillisecondsSinceEpoch(j['at'] as int) : null,
    );
  }
}

/// One conversation per account (role + user), kept while the app runs and saved on the device
/// for signed-in users, so the chat shows the earlier discussion like a messaging app: after
/// closing the panel, switching pages or reopening the app.
class _ChatHistory {
  _ChatHistory._();

  static const int maxMessages = 80;
  static final Map<String, List<_ChatMessage>> _memory = <String, List<_ChatMessage>>{};

  static String prefsKey(String conversation) => 'truck_buddy_chat_$conversation';

  static Future<List<_ChatMessage>> load(String conversation, {required bool persist}) async {
    final List<_ChatMessage>? inMemory = _memory[conversation];
    if (inMemory != null) return inMemory;
    final List<_ChatMessage> list = <_ChatMessage>[];
    if (persist) {
      try {
        final String? raw = (await SharedPreferences.getInstance()).getString(prefsKey(conversation));
        if (raw != null) {
          for (final Object? j in (jsonDecode(raw) as List)) {
            final _ChatMessage? m = _ChatMessage.fromJson(j);
            if (m != null) list.add(m);
          }
        }
      } catch (_) {/* unreadable or unavailable storage: start a new conversation */}
    }
    return _memory[conversation] = list;
  }

  static Future<void> save(String conversation, List<_ChatMessage> messages, {required bool persist}) async {
    if (messages.length > maxMessages) messages.removeRange(0, messages.length - maxMessages);
    _memory[conversation] = messages;
    if (!persist) return;
    try {
      await (await SharedPreferences.getInstance()).setString(prefsKey(conversation), jsonEncode(messages.map((_ChatMessage m) => m.toJson()).toList()));
    } catch (_) {}
  }

  static Future<void> clear(String conversation) async {
    _memory.remove(conversation);
    try {
      await (await SharedPreferences.getInstance()).remove(prefsKey(conversation));
    } catch (_) {}
  }

  @visibleForTesting
  static void resetMemory() => _memory.clear();
}

class _TruckChatLauncherState extends State<TruckChatLauncher> with SingleTickerProviderStateMixin {
  static const Color _teal = Color(0xFF00796B);
  static const Color _ink = Color(0xFF1A2B3C);

  late FaqBot _bot;
  List<_ChatMessage> _messages = <_ChatMessage>[];

  /// Conversation key: role + signed-in user ("guest" on the public page). Guests are kept in
  /// memory only (public computers).
  String? _conversation;
  bool get _persist => _bot.role != BotRole.guest;

  /// Shows the jump-to-latest button while the user reads older messages.
  bool _atBottom = true;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  bool _open = false;
  bool _typing = false;

  static const double _btn = 60;
  static const double _margin = 8;

  /// Button position as a fraction of the free area (survives resizes and tab switches).
  static final Map<BotRole, Offset> _savedSpot = <BotRole, Offset>{};
  Offset? _spot;
  Size _area = Size.zero;

  StreamSubscription<FleetSnapshot>? _fleetSub;
  FleetSnapshot? _fleet;
  StreamSubscription<Map<String, CollectionSchedule>>? _scheduleSub;
  Map<String, CollectionSchedule>? _schedules;
  PublicStats? _stats;
  DateTime? _statsAt;

  /// Drivers: approved, active accounts (server, counts only). Trucks: the truck registry
  /// entries with a plate number. Areas: the collection areas shown on the maps.
  static Future<PublicStats?> _fetchStats() async {
    try {
      final Future<dynamic> driversF = ApiService().getPublicStats().then((dynamic r) => r.data);
      final Future<Object?> trucksF = FirebaseDatabase.instance.ref('trucks').get().then((DataSnapshot s) => s.value);
      final Future<List<ServiceArea>> areasF = ServiceAreaService().getAllServiceAreas();
      final dynamic d = await driversF;
      if (d is! Map || d['success'] != true) return null;
      int? areas;
      try {
        areas = (await areasF).map(FirebaseCollectionDataSource.toGeofence).where((AreaGeofence g) => g.isTruckStop).length;
      } catch (_) {}
      return PublicStats(
        drivers: int.tryParse('${d['drivers']}') ?? 0,
        trucks: registeredTrucks(await trucksF),
        serviceAreas: areas,
      );
    } catch (_) {}
    return null;
  }

  /// Registry entries that are real trucks (a plate number is recorded).
  static int registeredTrucks(Object? registry) => TruckChatLauncherCounting.registeredTrucks(registry);


  /// Counts change rarely: loaded when the chat opens, at most every 5 minutes.
  void _refreshStats() {
    if (_statsAt != null && DateTime.now().difference(_statsAt!) < const Duration(minutes: 5)) return;
    _statsAt = DateTime.now();
    (widget.loadStats ?? _fetchStats)().then((PublicStats? s) {
      if (s != null) _stats = s;
    });
  }

  /// While dragging with the panel open, the panel stays on the same side of the button
  /// (otherwise it would flip sides as the button crosses the middle of the screen).
  bool? _lockAbove;
  bool? _lockRight;
  bool _lastAbove = true;
  bool _lastRight = true;

  void _dragStart() {
    _lockAbove = _lastAbove;
    _lockRight = _lastRight;
  }

  /// The side stays locked until the chat closes, so the panel never jumps after a drop.
  void _dragEnd() => _saveSpot();

  /// Drag handlers shared by the round button and the panel header.
  Widget _draggable(Widget child) => GestureDetector(
        onPanStart: (_) => _dragStart(),
        onPanUpdate: (DragUpdateDetails d) => _dragBy(d.delta),
        onPanEnd: (_) => _dragEnd(),
        child: child,
      );

  String get _prefsKey => 'truck_buddy_spot_${botRoleFrom(widget.role).name}';
  late final AnimationController _bounce = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _bot = FaqBot(botRoleFrom(widget.role));
    _spot = _savedSpot[_bot.role];
    _greet();
    _loadConversation();
    _scroll.addListener(_onScroll);
    if (_spot == null) _loadSpot();
    try {
      _fleetSub = (widget.fleet ?? LiveFleet.watch()).listen((FleetSnapshot f) => _fleet = f, onError: (Object _) {});
    } catch (_) {/* no live data: the bot still answers everything else */}
    try {
      _scheduleSub = (widget.schedules ?? CollectionScheduleService.watch())
          .listen((Map<String, CollectionSchedule> s) => _schedules = s, onError: (Object _) => _schedules = const <String, CollectionSchedule>{});
    } catch (_) {
      _schedules = const <String, CollectionSchedule>{};
    }
  }

  Future<void> _loadSpot() async {
    try {
      final List<String>? v = (await SharedPreferences.getInstance()).getStringList(_prefsKey);
      if (v == null || v.length != 2 || !mounted) return;
      final Offset o = Offset(double.parse(v[0]).clamp(0.0, 1.0), double.parse(v[1]).clamp(0.0, 1.0));
      setState(() => _spot = _savedSpot[_bot.role] = o);
    } catch (_) {/* storage unavailable: keep the default spot */}
  }

  Future<void> _saveSpot() async {
    final Offset? o = _spot;
    if (o == null) return;
    _savedSpot[_bot.role] = o;
    try {
      await (await SharedPreferences.getInstance()).setStringList(_prefsKey, <String>[o.dx.toStringAsFixed(4), o.dy.toStringAsFixed(4)]);
    } catch (_) {}
  }

  /// Top-left of the button in this layer's coordinates.
  Offset _buttonOffset(Size area) {
    final double freeW = math.max(0, area.width - _btn - 2 * _margin);
    final double freeH = math.max(0, area.height - _btn - 2 * _margin);
    final Offset f = _spot ??
        Offset(
          freeW == 0 ? 1 : ((area.width - widget.right - _btn - _margin) / freeW).clamp(0.0, 1.0),
          freeH == 0 ? 1 : ((area.height - widget.bottom - _btn - _margin) / freeH).clamp(0.0, 1.0),
        );
    return Offset(_margin + f.dx * freeW, _margin + f.dy * freeH);
  }

  double _panelH = 420;

  void _dragBy(Offset delta) {
    final double freeW = math.max(1, _area.width - _btn - 2 * _margin);
    final double freeH = math.max(1, _area.height - _btn - 2 * _margin);
    Offset now = _buttonOffset(_area) + delta;
    if (_open && _lockAbove != null && _lockRight != null) {
      // Keep the whole open panel on screen instead of letting it slide over the button.
      final double panelW = math.min(380, _area.width - 2 * _margin);
      final double minX = _lockRight! ? _margin + panelW - _btn : _margin;
      final double maxX = _lockRight! ? _area.width - _margin - _btn : _area.width - _margin - panelW;
      final double minY = _lockAbove! ? _margin + _panelH + 12 : _margin;
      final double maxY = _lockAbove! ? _area.height - _margin - _btn : _area.height - _margin - _panelH - 12 - _btn;
      if (maxX >= minX) now = Offset(now.dx.clamp(minX, maxX), now.dy);
      if (maxY >= minY) now = Offset(now.dx, now.dy.clamp(minY, maxY));
    }
    setState(() => _spot = Offset(((now.dx - _margin) / freeW).clamp(0.0, 1.0), ((now.dy - _margin) / freeH).clamp(0.0, 1.0)));
  }

  @override
  void didUpdateWidget(TruckChatLauncher old) {
    super.didUpdateWidget(old);
    if (botRoleFrom(old.role) != botRoleFrom(widget.role)) {
      _bot = FaqBot(botRoleFrom(widget.role));
      _messages = <_ChatMessage>[];
      _conversation = null;
      _greet();
      _loadConversation();
      _spot = _savedSpot[_bot.role];
      if (_spot == null) _loadSpot();
    }
  }

  /// Restores this account's earlier conversation (or starts one with the greeting).
  Future<void> _loadConversation() async {
    final BotRole role = _bot.role;
    String key = 'guest';
    if (role != BotRole.guest) {
      try {
        final user = await SessionManager.getUser();
        key = '${role.name}_${user?.userId ?? 0}';
      } catch (_) {
        key = '${role.name}_0';
      }
    }
    final List<_ChatMessage> saved = await _ChatHistory.load(key, persist: role != BotRole.guest);
    if (!mounted || _bot.role != role) return;
    setState(() {
      // Messages typed before the history finished loading are kept after it.
      final List<_ChatMessage> typed = _messages.where((_ChatMessage m) => m.fromUser || _messages.indexOf(m) > 0).toList();
      if (saved.isEmpty) {
        saved.addAll(_messages);
      } else {
        saved.addAll(typed);
      }
      _messages = saved;
      _conversation = key;
    });
    _save();
    _jumpToLatest();
  }

  void _save() {
    final String? key = _conversation;
    if (key != null) _ChatHistory.save(key, _messages, persist: _persist);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final bool atBottom = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _greet() {
    _messages.add(_ChatMessage(
      fromUser: false,
      text: "Hi! I'm Truck Buddy. Ask me anything about using the Garbage Tracker, in English or Tagalog.",
      suggestions: _bot.starters,
    ));
  }

  @override
  void dispose() {
    _fleetSub?.cancel();
    _scheduleSub?.cancel();
    _bounce.dispose();
    _input.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send(String raw) {
    final String text = raw.trim();
    if (text.isEmpty || _typing) return;
    _input.clear();
    _focus.requestFocus(); // Enter would otherwise leave the box unfocused
    // The question before this one, so short follow-ups ("paano?", "eh sa drivers?") are understood.
    String? previous;
    for (final _ChatMessage m in _messages.reversed) {
      if (m.fromUser) {
        previous = m.text;
        break;
      }
    }
    setState(() {
      _messages.add(_ChatMessage(fromUser: true, text: text));
      _typing = true;
    });
    _save();
    _scrollDown();
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final BotReply r = _bot.reply(text, fleet: _fleet, stats: _stats, schedules: _schedules, purok: widget.purok, previous: previous);
      setState(() {
        _typing = false;
        _messages.add(_ChatMessage(
          fromUser: false,
          text: r.text,
          action: widget.onAction == null ? null : r.action,
          actionLabel: r.actionLabel,
          suggestions: r.suggestions,
          restricted: r.kind == BotReplyKind.restricted,
        ));
      });
      _save();
      _scrollDown();
    });
  }

  /// Opens the chat at the newest message (after the list has been laid out).
  void _jumpToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      // Long histories finish measuring a frame later.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    });
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
    if (!_atBottom) setState(() => _atBottom = true);
  }

  /// "Start over": the saved conversation is deleted too.
  void _restart() {
    final String? key = _conversation;
    if (key != null) _ChatHistory.clear(key);
    setState(() {
      _messages = <_ChatMessage>[];
      _greet();
      _atBottom = true;
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
        _area = box.biggest;
        if (!_open) {
          _lockAbove = null;
          _lockRight = null;
        }
        final Offset b = _buttonOffset(_area);
        final double panelW = math.min(380, _area.width - 2 * _margin);
        // Open the panel on the side of the button that has more room (kept while dragging).
        final bool above = _lockAbove ?? (b.dy + _btn / 2 > _area.height / 2);
        final double room = above ? b.dy - 12 - _margin : _area.height - (b.dy + _btn + 12) - _margin;
        final double panelH = _lockAbove != null ? _panelH : math.min(560, math.max(260, room));
        _panelH = panelH;
        final bool alignRight = _lockRight ?? (b.dx + _btn / 2 > _area.width / 2);
        _lastAbove = above;
        _lastRight = alignRight;
        final double left = (alignRight ? b.dx + _btn - panelW : b.dx).clamp(_margin, math.max(_margin, _area.width - panelW - _margin));
        final double top = (above ? b.dy - 12 - panelH : b.dy + _btn + 12).clamp(_margin, math.max(_margin, _area.height - panelH - _margin));
        return Stack(clipBehavior: Clip.none, children: [
          if (_open)
            Positioned(
              left: left,
              top: top,
              width: panelW,
              height: panelH,
              child: PointerInterceptor(
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0.92, end: 1),
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  builder: (BuildContext context, double v, Widget? child) => Opacity(
                    opacity: ((v - 0.92) / 0.08).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: v,
                      alignment: Alignment(alignRight ? 1 : -1, above ? 1 : -1),
                      child: child,
                    ),
                  ),
                  child: _buildPanel(),
                ),
              ),
            ),
          Positioned(
            left: b.dx,
            top: b.dy,
            child: PointerInterceptor(
              child: _draggable(_buildLauncherButton()),
            ),
          ),
        ]);
      }),
    );
  }

  Widget _buildLauncherButton() {
    return Tooltip(
      message: _open ? 'Close Truck Buddy' : 'Ask Truck Buddy (drag to move)',
      child: AnimatedBuilder(
        animation: _bounce,
        builder: (BuildContext context, Widget? child) => Transform.translate(
          offset: Offset(0, _open ? 0 : -3 * Curves.easeInOut.transform(_bounce.value)),
          child: child,
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              setState(() => _open = !_open);
              if (_open) {
                _refreshStats();
                _atBottom = true;
                _jumpToLatest();
                Future<void>.delayed(const Duration(milliseconds: 250), () {
                  if (mounted && _open) _focus.requestFocus();
                });
              }
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [Color(0xFF00897B), Color(0xFF004D40)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [BoxShadow(color: _teal.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))],
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Icon(_open ? Icons.close_rounded : Icons.local_shipping_rounded, key: ValueKey<bool>(_open), color: Colors.white, size: 28),
                  ),
                ),
                if (!_open)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(color: const Color(0xFFFFB300), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                      child: const Icon(Icons.question_mark_rounded, size: 12, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanel() {
    return Material(
      color: Colors.white,
      elevation: 0,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE6EBF0)),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 30, offset: Offset(0, 12))],
        ),
        child: Column(children: [
          _buildHeader(),
          Expanded(
            child: Container(
              color: const Color(0xFFF6F8FA),
              child: Stack(children: [
                Positioned.fill(
                  child: Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                      itemCount: _messages.length + (_typing ? 1 : 0),
                      itemBuilder: (BuildContext context, int i) {
                        if (i == _messages.length) return _buildTyping();
                        final _ChatMessage m = _messages[i];
                        final bool newDay = i == 0 || !_sameDay(_messages[i - 1].at, m.at);
                        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                          if (newDay) _buildDaySeparator(m.at),
                          _buildMessage(m, i == _messages.length - 1),
                        ]);
                      },
                    ),
                  ),
                ),
                if (!_atBottom)
                  Positioned(
                    right: 12,
                    bottom: 10,
                    child: Material(
                      color: Colors.white,
                      shape: const CircleBorder(side: BorderSide(color: Color(0xFFB2DFDB))),
                      elevation: 3,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _scrollDown,
                        child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.keyboard_arrow_down_rounded, color: _teal, size: 22)),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          _buildInput(),
        ]),
      ),
    );
  }

  /// The header is the panel's drag handle: drag it to move the open chat anywhere.
  Widget _buildHeader() {
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: _draggable(_buildHeaderBar()),
    );
  }

  Widget _buildHeaderBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF00897B), Color(0xFF00695C)])),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), shape: BoxShape.circle),
          child: const Icon(Icons.local_shipping_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const Text('Truck Buddy', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
            Text('Drag this bar to move', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5, fontWeight: FontWeight.w600)),
          ]),
        ),
        IconButton(onPressed: _restart, tooltip: 'Start over', icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 20)),
        IconButton(onPressed: () => setState(() => _open = false), tooltip: 'Close', icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20)),
      ]),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _buildDaySeparator(DateTime at) {
    final DateTime now = DateTime.now();
    final String label = _sameDay(at, now)
        ? 'Today'
        : _sameDay(at, now.subtract(const Duration(days: 1)))
            ? 'Yesterday'
            : DateFormat('MMM d, yyyy').format(at);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFFE6EBF0), borderRadius: BorderRadius.circular(10)),
          child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF5B6B7B))),
        ),
      ),
    );
  }

  Widget _buildMessage(_ChatMessage m, bool isLast) {
    final BorderRadius r = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(m.fromUser ? 18 : 4),
      bottomRight: Radius.circular(m.fromUser ? 4 : 18),
    );
    final Widget bubble = Container(
      constraints: const BoxConstraints(maxWidth: 290),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: m.fromUser ? _teal : (m.restricted ? const Color(0xFFFFF4E5) : Colors.white),
        borderRadius: r,
        border: m.fromUser ? null : Border.all(color: m.restricted ? const Color(0xFFFFD8A8) : const Color(0xFFE6EBF0)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (m.restricted)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline_rounded, size: 14, color: Color(0xFFB26A00)),
              SizedBox(width: 4),
              Text('Administrator only', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFFB26A00))),
            ]),
          ),
        Text(m.text, style: TextStyle(color: m.fromUser ? Colors.white : _ink, fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w500)),
        if (m.action != null && widget.onAction != null) ...[
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: () {
              setState(() => _open = false);
              widget.onAction!(m.action!);
            },
            icon: const Icon(Icons.arrow_forward_rounded, size: 16),
            label: Text(m.actionLabel ?? 'Open'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE0F2F1),
              foregroundColor: _teal,
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
            ),
          ),
        ],
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: m.fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        bubble,
        Padding(
          padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
          child: Text(DateFormat('h:mm a').format(m.at), style: const TextStyle(fontSize: 10.5, color: Color(0xFF8A99A8), fontWeight: FontWeight.w600)),
        ),
        if (isLast && !m.fromUser && m.suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final String s in m.suggestions)
                  ActionChip(
                    label: Text(s, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _teal)),
                    onPressed: () => _send(s),
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFFB2DFDB)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _buildTyping() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE6EBF0))),
        child: AnimatedBuilder(
          animation: _bounce,
          builder: (BuildContext context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (int i = 0; i < 3; i++)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _teal.withValues(alpha: 0.3 + 0.7 * ((_bounce.value * 3 - i).abs() < 1 ? 1 - (_bounce.value * 3 - i).abs() : 0)),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Color(0xFFE6EBF0)))),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _input,
            focusNode: _focus,
            textInputAction: TextInputAction.send,
            onSubmitted: _send,
            onEditingComplete: () {}, // keep focus after Enter
            maxLength: 200,
            decoration: InputDecoration(
              hintText: 'Ask about the app…',
              counterText: '',
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF1F5F9),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          onPressed: () => _send(_input.text),
          tooltip: 'Send',
          style: IconButton.styleFrom(backgroundColor: _teal),
          icon: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
        ),
      ]),
    );
  }
}

/// Truck registry counting (public for tests).
class TruckChatLauncherCounting {
  TruckChatLauncherCounting._();

  static int registeredTrucks(Object? registry) {
    if (registry is! Map) return 0;
    int n = 0;
    registry.forEach((Object? k, Object? v) {
      final String id = '$k'.trim();
      if (v is Map && id.isNotEmpty && id.toLowerCase() != 'unknown' && '${v['plateNumber'] ?? v['plate_number'] ?? ''}'.trim().isNotEmpty) n++;
    });
    return n;
  }
}
