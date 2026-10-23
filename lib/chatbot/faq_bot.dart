/// Rule-based help assistant ("Truck Buddy"). Runs fully on the device: no AI service, no network.
///
/// How it answers:
///  1. The message is normalised (lower case, punctuation removed) and split into words.
///  2. Every knowledge entry has trigger keywords (English and Tagalog). A matching phrase or word
///     adds that keyword's weight to the entry's score.
///  3. Only entries for the signed-in role can be answered. If the best match is an admin-only
///     topic and the user is not an admin, the bot declines instead of answering.
///  4. Below the confidence threshold the bot says it is not sure and offers related questions.
///  5. Live questions ("how many trucks are online?", "where is GT-007?") are answered from the
///     same truck feed and online rules the maps use ([FleetSnapshot]); nothing is guessed.
///  6. Single-word keywords tolerate one typo ("notifcation"), and rude messages get a polite reply.
library;

import '../services/collection_schedule_service.dart';
import '../services/service_area_service.dart';
import 'fleet_snapshot.dart';

/// Screens the bot can open for the user. Each dashboard maps these to its own tabs.
enum BotAction { signIn, createAccount, downloadApp, home, track, collectionStatus, complaints, fileComplaint, routeHistory, settings, routePlan, users, analytics, routeAssignments }

/// guest = the public landing page (not signed in).
enum BotRole { guest, resident, driver, admin }

/// The screens each role's page can really open. A reply never offers a button for a screen the
/// user's page does not have (the button would otherwise land on an unrelated tab).
const Map<BotRole, Set<BotAction>> botSupportedActions = <BotRole, Set<BotAction>>{
  BotRole.guest: <BotAction>{BotAction.signIn, BotAction.createAccount, BotAction.downloadApp, BotAction.track, BotAction.collectionStatus},
  BotRole.resident: <BotAction>{BotAction.home, BotAction.track, BotAction.collectionStatus, BotAction.complaints, BotAction.fileComplaint, BotAction.routeHistory, BotAction.settings},
  BotRole.driver: <BotAction>{BotAction.home, BotAction.track, BotAction.routePlan, BotAction.routeHistory, BotAction.settings},
  BotRole.admin: <BotAction>{
    BotAction.home, BotAction.track, BotAction.collectionStatus, BotAction.complaints, BotAction.routeHistory, BotAction.settings,
    BotAction.users, BotAction.analytics, BotAction.routeAssignments,
  },
};

/// Registered fleet counts from `get_public_stats.php` (counts only, no personal data).
class PublicStats {
  const PublicStats({required this.drivers, required this.trucks, this.serviceAreas});
  final int drivers;
  final int trucks;
  final int? serviceAreas;
}

BotRole botRoleFrom(String? role) {
  switch ((role ?? '').toLowerCase()) {
    case 'admin':
      return BotRole.admin;
    case 'driver':
      return BotRole.driver;
    case 'guest':
    case '':
      return BotRole.guest;
    default:
      return BotRole.resident;
  }
}

class FaqEntry {
  final String id;
  final String question;
  final String answer;

  /// Roles that may receive this answer.
  final Set<BotRole> roles;

  /// keyword or phrase -> weight. Phrases (with spaces) must appear in order.
  final Map<String, int> keywords;
  final BotAction? action;
  final String? actionLabel;

  const FaqEntry({
    required this.id,
    required this.question,
    required this.answer,
    required this.roles,
    required this.keywords,
    this.action,
    this.actionLabel,
  });

  bool get adminOnly => roles.length == 1 && roles.contains(BotRole.admin);
}

enum BotReplyKind { answer, live, smallTalk, restricted, fallback }

class BotReply {
  final BotReplyKind kind;
  final String text;
  final FaqEntry? entry;
  final List<String> suggestions;

  final BotAction? _action;
  final String? _actionLabel;

  const BotReply(this.kind, this.text, {this.entry, this.suggestions = const <String>[], BotAction? action, String? actionLabel, this.noAction = false})
      : _action = action,
        _actionLabel = actionLabel;

  /// [noAction]: the answer is shown without a button (e.g. a resident how-to shown to an admin).
  final bool noAction;

  BotAction? get action => noAction ? null : (_action ?? entry?.action);
  String? get actionLabel => action == null ? null : (_actionLabel ?? entry?.actionLabel);

  BotReply copyWith({String? text, bool? noAction}) => BotReply(kind, text ?? this.text,
      entry: entry, suggestions: suggestions, action: _action, actionLabel: _actionLabel, noAction: noAction ?? this.noAction);
}

class FaqBot {
  final BotRole role;
  final List<FaqEntry> entries;

  /// Minimum score for a confident answer.
  static const int threshold = 3;

  FaqBot(this.role, {List<FaqEntry>? entries}) : entries = entries ?? faqKnowledgeBase;

  List<FaqEntry> get available => entries.where((FaqEntry e) => e.roles.contains(role)).toList();

  /// Starter questions shown as chips when the chat opens.
  List<String> get starters {
    const Map<BotRole, List<String>> ids = <BotRole, List<String>>{
      BotRole.guest: <String>['guest_where_truck', 'map_colors', 'guest_login', 'guest_sign_up'],
      BotRole.resident: <String>['where_truck', 'when_collect', 'map_colors', 'file_complaint'],
      BotRole.driver: <String>['driver_start', 'driver_status_buttons', 'driver_gps', 'driver_route_plan'],
      BotRole.admin: <String>['admin_approve', 'admin_assign', 'admin_complaints', 'admin_backup'],
    };
    return ids[role]!.map((String id) => entries.firstWhere((FaqEntry e) => e.id == id).question).toList();
  }

  /// Lower case, punctuation removed, simple plural stripping ("alerts" -> "alert"), padded with
  /// spaces so keywords only match whole words.
  static String normalize(String s) {
    final List<String> words = s
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9ñ\s]"), ' ')
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .map((String w) => (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) ? w.substring(0, w.length - 1) : w)
        .toList();
    return ' ${words.join(' ')} ';
  }

  /// Light English stemming so "managing", "managed" and "manage" match ("resolving" ->
  /// "resolv"). Only used for keyword matching; both sides are stemmed the same way.
  static String stem(String w) {
    if (w.length <= 3) return w;
    String s = w;
    if (s.length > 5 && s.endsWith('ing')) {
      s = s.substring(0, s.length - 3);
    } else if (s.length > 4 && s.endsWith('ed')) {
      s = s.substring(0, s.length - 2);
    }
    if (s.length > 3 && s.endsWith('e')) s = s.substring(0, s.length - 1);
    return s;
  }

  static String _stemmed(String normalized) => ' ${normalized.trim().split(' ').where((String w) => w.isNotEmpty).map(stem).join(' ')} ';

  static int score(FaqEntry e, String normalized) {
    final List<String> words = normalized.trim().split(' ');
    final String stemmed = _stemmed(normalized);
    int total = 0;
    e.keywords.forEach((String k, int w) {
      final String key = normalize(k);
      if (normalized.contains(key) || stemmed.contains(_stemmed(key))) {
        total += w;
      } else {
        // One typo allowed in longer single words ("notifcation", "complain").
        final String word = key.trim();
        if (!word.contains(' ') && word.length >= 6 && words.any((String t) => t.length >= 5 && t[0] == word[0] && _withinOneEdit(t, word))) {
          total += w;
        }
      }
    });
    return total;
  }

  static bool _withinOneEdit(String a, String b) {
    if (a == b) return true;
    if ((a.length - b.length).abs() > 1) return false;
    int i = 0, j = 0, edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length > b.length) {
        i++;
      } else if (a.length < b.length) {
        j++;
      } else {
        i++;
        j++;
      }
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
  }

  /// [previous]: the user's previous message. A short follow-up that is not understood on its own
  /// ("paano?", "how about drivers?", "eh yung sa resolved?") is read together with it.
  BotReply reply(
    String message, {
    FleetSnapshot? fleet,
    PublicStats? stats,
    Map<String, CollectionSchedule>? schedules,
    String? purok,
    String? previous,
  }) {
    final BotReply first = _reply(message, fleet: fleet, stats: stats, schedules: schedules, purok: purok);
    if (first.kind == BotReplyKind.fallback && previous != null && previous.trim().isNotEmpty && _isShort(message)) {
      final BotReply again = _reply('$previous $message', fleet: fleet, stats: stats, schedules: schedules, purok: purok);
      if (again.kind == BotReplyKind.answer || again.kind == BotReplyKind.live) return _guard(again);
    }
    return _guard(first);
  }

  /// Admin answers for topics that residents and drivers also ask about in their own words.
  static const Set<String> adminMirrorTopics = <String>{
    'admin_complaints', 'admin_driver_reports', 'admin_track', 'admin_notifications', 'admin_collection_status', 'admin_eta', 'admin_dashboard', 'admin_reports_export',
  };

  static bool _isShort(String message) => normalize(message).trim().split(' ').length <= 7;

  /// Drops a button that this role's page cannot open.
  BotReply _guard(BotReply r) {
    final BotAction? a = r.action;
    if (a != null && !botSupportedActions[role]!.contains(a)) return r.copyWith(noAction: true);
    return r;
  }

  static String _audience(FaqEntry e) => e.roles.contains(BotRole.resident)
      ? 'residents'
      : e.roles.contains(BotRole.driver)
          ? 'drivers'
          : 'visitors of the public page';

  /// Administrators may read another role's how-to (useful when helping a resident or driver);
  /// it is labelled and has no button, because the button would open a different admin page.
  BotReply _assist(FaqEntry e) => BotReply(BotReplyKind.answer, 'For ${_audience(e)}: ${e.answer}', entry: e, noAction: true);

  BotReply _reply(
    String message, {
    FleetSnapshot? fleet,
    PublicStats? stats,
    Map<String, CollectionSchedule>? schedules,
    String? purok,
  }) {
    final String text = normalize(message);
    if (text.trim().isEmpty) return BotReply(BotReplyKind.fallback, 'Type a question about the app, or tap one below.', suggestions: starters);

    if (_isRude(text)) {
      return BotReply(BotReplyKind.smallTalk, "Let's keep it friendly. I am here to help you with the Garbage Tracker. You can ask me things like:", suggestions: starters);
    }
    final BotReply? sched = _schedule(text, schedules, purok);
    if (sched != null) return sched;
    final BotReply? counts = _counts(text, fleet, stats);
    if (counts != null) return counts;
    final BotReply? live = _live(text, fleet);
    if (live != null) return live;

    final bool isAdmin = role == BotRole.admin;

    // Exact question (from a tapped chip). The user's own entries first: roles share some
    // question texts with different answers.
    for (final FaqEntry e in <FaqEntry>[...available, ...entries]) {
      if (normalize(e.question) == text) {
        if (e.roles.contains(role)) return BotReply(BotReplyKind.answer, e.answer, entry: e);
        return isAdmin ? _assist(e) : _restricted(e);
      }
    }

    final BotReply? talk = _smallTalk(text);

    FaqEntry? best;
    int bestScore = 0;
    FaqEntry? bestBlocked;
    int blockedScore = 0;
    final List<MapEntry<FaqEntry, int>> related = <MapEntry<FaqEntry, int>>[];
    for (final FaqEntry e in entries) {
      final int s = score(e, text);
      if (s == 0) continue;
      if (e.roles.contains(role)) {
        related.add(MapEntry<FaqEntry, int>(e, s));
        if (s > bestScore) {
          best = e;
          bestScore = s;
        }
      } else if (isAdmin) {
        // Another role's how-to: only when clearly better than the admin's own answers.
        if (s - 2 > bestScore) {
          best = e;
          bestScore = s - 2;
        }
      } else if (s > blockedScore) {
        bestBlocked = e;
        blockedScore = s;
      }
    }

    // Decline only for a real administrator tool (approve users, backups, analytics...) that matches
    // at least as well as the user's own answers. Topics every role has in its own words (trucks,
    // complaints, notifications, trips) never block the user's own answer; another role's feature
    // is declined only when nothing of the user's own fits.
    if (bestBlocked != null && blockedScore >= threshold) {
      final bool adminTool = bestBlocked.adminOnly && !adminMirrorTopics.contains(bestBlocked.id);
      // Visitors: account features clearly asked about get the "sign in first" reply.
      final bool visitorAccountFeature = role == BotRole.guest && !bestBlocked.adminOnly && blockedScore > bestScore;
      if (bestScore < threshold || (adminTool && blockedScore >= bestScore) || visitorAccountFeature) return _restricted(bestBlocked);
    }
    if (best != null && bestScore >= threshold) {
      if (!best.roles.contains(role)) return _assist(best);
      // "Where is the truck?" also gets the live situation.
      final String extra = const <String>{'where_truck', 'guest_where_truck', 'admin_track'}.contains(best.id) ? _fleetSummary(fleet) : '';
      return BotReply(BotReplyKind.answer, extra.isEmpty ? best.answer : '$extra\n\n${best.answer}', entry: best);
    }
    if (talk != null) return talk;

    related.sort((MapEntry<FaqEntry, int> a, MapEntry<FaqEntry, int> b) => b.value.compareTo(a.value));
    final List<String> maybe = related.take(3).map((MapEntry<FaqEntry, int> m) => m.key.question).toList();
    return BotReply(
      BotReplyKind.fallback,
      maybe.isEmpty
          ? "Sorry, I don't have an answer for that. I only know about using this app (trucks, alerts, complaints, accounts${isAdmin ? ', and the admin tools' : ''}). Try one of these, or use Contact Support in Account Settings."
          : 'I am not sure I understood. Did you mean one of these?',
      suggestions: maybe.isEmpty ? starters : maybe,
    );
  }


  // ---- usual collection days (admin-set schedule only; nothing is guessed) -------------------

  static bool _asksSchedule(String t) {
    bool has(List<String> ks) => ks.any((String k) => t.contains(' $k '));
    return has(<String>[
      'schedule', 'iskedyul', 'what day', 'which day', 'anong araw', 'kailan ang koleksyon', 'usual day', 'usually', 'collection day',
      'pickup day', 'every week', 'weekly', 'what time', 'anong oras', 'tuwing', 'kailan dumadaan', 'kailan kinukuha', 'operate', 'operating day',
      'when do you collect', 'when is collection', 'when is the collection', 'collection time', 'garbage day',
    ]);
  }

  BotReply? _schedule(String t, Map<String, CollectionSchedule>? schedules, String? purok) {
    if (!_asksSchedule(t)) return null;
    // "How do I set / change the schedule?" is a how-to question (admin FAQ), not a lookup.
    if (<String>[' set ', ' edit ', ' change ', ' update ', ' how do i ', ' paano ', ' progress '].any(t.contains)) return null;
    // A purok named in the question wins over the user's own purok.
    String? asked;
    for (final String n in ServiceAreaService.documentedAreaNames) {
      final String norm = normalize(n);
      if (norm.trim().isNotEmpty && t.contains(norm)) asked = n;
    }
    asked ??= _shortPurokIn(t);
    final String? area = asked ?? purok;
    if (schedules == null) {
      return const BotReply(BotReplyKind.live, 'I am still loading the collection schedule. Please ask again in a few seconds.');
    }
    if (schedules.isEmpty) {
      return BotReply(
        BotReplyKind.live,
        'The barangay has not published a fixed weekly collection schedule in the app yet. '
        'Trucks are tracked live instead: ${role == BotRole.guest ? 'with a resident account you get' : 'you get'} a notification about 15, 10 and 5 minutes before a truck reaches ${role == BotRole.guest ? 'your' : 'your registered'} purok, and when it arrives.',
      );
    }
    if (area != null) {
      final CollectionSchedule? sc = CollectionScheduleService.forPurok(schedules, area);
      if (sc != null) {
        final String next = _nextLabel(sc);
        return BotReply(BotReplyKind.live,
            'Collection in ${sc.area}: ${sc.summary}.$next${sc.note.isNotEmpty ? '\nNote: ${sc.note}' : ''}\nTimes are approximate; the live map and alerts show where the truck really is.');
      }
      if (asked != null || role == BotRole.resident) {
        return BotReply(BotReplyKind.live,
            'There is no fixed schedule for ${area.trim()} in the app yet. You still get alerts when a truck is approaching. Areas with a schedule:\n${_allSchedules(schedules)}');
      }
    }
    return BotReply(BotReplyKind.live, 'Usual collection days per area:\n${_allSchedules(schedules)}\nTimes are approximate; the live map and alerts show where the truck really is.');
  }

  static String? _shortPurokIn(String t) {
    final RegExpMatch? m = RegExp(r' purok (\d) ').firstMatch(t);
    return m == null ? null : ServiceAreaService.canonicalizeAreaName('purok ${m.group(1)}');
  }

  static String _allSchedules(Map<String, CollectionSchedule> all) {
    final List<CollectionSchedule> list = all.values.toList()..sort((CollectionSchedule a, CollectionSchedule b) => a.area.compareTo(b.area));
    return list.map((CollectionSchedule s) => '• ${s.area}: ${s.summary}').join('\n');
  }

  static String _nextLabel(CollectionSchedule sc) {
    final DateTime now = DateTime.now();
    final DateTime? n = sc.nextAfter(now);
    if (n == null) return '';
    final DateTime today = DateTime(now.year, now.month, now.day);
    final int days = DateTime(n.year, n.month, n.day).difference(today).inDays;
    final String when = days == 0 ? 'today' : (days == 1 ? 'tomorrow' : 'on ${CollectionSchedule.dayNames[n.weekday - 1]}');
    return '\nNext: $when at about ${sc.timeLabel}.';
  }

  // ---- fleet size (registered) + online now ---------------------------------------------------

  BotReply? _counts(String t, FleetSnapshot? fleet, PublicStats? stats) {
    bool has(List<String> ks) => ks.any((String k) => t.contains(' $k '));
    final bool asksCount = has(<String>['how many', 'ilan', 'ilang', 'number of', 'total', 'count', 'gaano karami', 'registered']);
    final bool aboutDrivers = has(<String>['driver', 'drayber', 'collector', 'tsuper']);
    final bool aboutTrucks = has(<String>['truck', 'trak', 'vehicle', 'fleet', 'sasakyan']);
    if (!asksCount || !(aboutDrivers || aboutTrucks)) return null;
    final bool onlyNow = has(<String>['online', 'now', 'ngayon', 'active', 'collecting']) && !has(<String>['registered', 'total']);
    if (onlyNow) return null; // "how many trucks are online now" -> live answer
    final String online = fleet == null
        ? ''
        : (fleet.trucks.isEmpty ? ' Right now no truck is online.' : ' Right now ${fleet.trucks.length} ${fleet.trucks.length == 1 ? 'truck is' : 'trucks are'} online.');
    if (stats == null) {
      return BotReply(BotReplyKind.live, 'I could not load the registered fleet numbers right now.$online');
    }
    final String d = '${stats.drivers} registered driver${stats.drivers == 1 ? '' : 's'}';
    final String tr = '${stats.trucks} garbage truck${stats.trucks == 1 ? '' : 's'}';
    final String areas = stats.serviceAreas != null && stats.serviceAreas! > 0 ? ' The system serves ${stats.serviceAreas} areas (puroks) of Barangay Balintawak.' : '';
    return BotReply(BotReplyKind.live, 'Barangay Balintawak has $d and $tr in the system.$online$areas');
  }

  static const List<String> _rude = <String>[
    'tangina', 'tanginamo', 'putangina', 'putang', 'gago', 'gaga', 'tanga', 'bobo', 'ulol', 'inutil', 'punyeta', 'leche', 'pakyu',
    'fuck', 'fck', 'shit', 'bitch', 'stupid', 'idiot', 'bullshit', 'asshole',
  ];

  static bool _isRude(String t) => _rude.any((String w) => t.contains(' $w ') || t.contains(' ${w}mo ') || t.contains(' ${w}ng '));

  static final RegExp _truckIdPattern = RegExp(r' (gt|tr) ?0*(\d{1,3}) ');

  /// Truck id mentioned in the message ("gt 7", "GT-007"), normalised like the maps (GT-007).
  static String? truckIdIn(String normalized) {
    final RegExpMatch? m = _truckIdPattern.firstMatch(normalized.replaceAllMapped(RegExp(r'(gt|tr)(\d)'), (Match x) => '${x[1]} ${x[2]}'));
    if (m == null) return null;
    return '${m.group(1)!.toUpperCase()}-${m.group(2)!.padLeft(3, '0')}';
  }

  static String statusMeaning(String status) => switch (status) {
        'ACTIVE' || 'COLLECTING' => 'on an active collection trip',
        'IDLE' => 'online but not moving at the moment',
        'PAUSED' => 'paused by the driver',
        'FULL' => 'full and going to unload',
        'COMPLETED' || 'FINISHED' => 'finished for this trip',
        _ => status.toLowerCase(),
      };

  static String _ago(int sec) => sec < 60 ? '$sec seconds ago' : '${(sec / 60).round()} minute${(sec / 60).round() == 1 ? '' : 's'} ago';

  String _describe(LiveTruck t) {
    final bool names = role == BotRole.admin || role == BotRole.driver;
    final String who = names && t.driver != null ? ' (driver: ${t.driver})' : '';
    final String where = t.area != null ? ' in ${t.area}' : ' inside the barangay';
    return '${t.id}$who is ${statusMeaning(t.status)}$where. Last GPS update ${_ago(t.ageSec)}.';
  }

  String _fleetSummary(FleetSnapshot? fleet) {
    if (fleet == null) return '';
    if (fleet.trucks.isEmpty) return 'Right now no garbage truck is online.';
    final String n = fleet.trucks.length == 1 ? '1 truck is' : '${fleet.trucks.length} trucks are';
    return 'Right now $n online:\n${fleet.trucks.map((LiveTruck t) => '• ${_describe(t)}').join('\n')}';
  }

  BotReply? _live(String t, FleetSnapshot? fleet) {
    bool has(List<String> ks) => ks.any((String k) => t.contains(' $k '));
    final String? id = truckIdIn(t);
    final bool countQ = has(<String>['how many', 'ilan', 'ilang', 'any truck', 'is there a truck', 'are there truck', 'meron bang truck', 'may truck ba', 'may truck', 'online ba', 'trucks online', 'truck online', 'active truck', 'collecting now', 'right now', 'ngayon']);
    if (id == null && !countQ) return null;
    // "Is the truck online?" style questions only; leave rules questions ("why is a truck not online") to the FAQ.
    if (id == null && has(<String>['why', 'bakit', 'mean', 'meaning', 'ibig sabihin', 'how do', 'paano'])) return null;
    final BotAction? open = switch (role) {
      BotRole.guest => null,
      BotRole.admin || BotRole.resident || BotRole.driver => BotAction.track,
    };
    if (fleet == null) {
      return const BotReply(BotReplyKind.live, 'I am still loading the live truck data. Please ask again in a few seconds.');
    }
    if (id != null) {
      final LiveTruck? truck = fleet.byId(id);
      return BotReply(
        BotReplyKind.live,
        truck == null
            ? '$id is not online right now. A truck appears on the map only while its driver is on a trip and its GPS has updated in the last 3 minutes.'
            : _describe(truck),
        action: open,
        actionLabel: open == null ? null : 'Open the live map',
      );
    }
    return BotReply(BotReplyKind.live, _fleetSummary(fleet), action: open, actionLabel: open == null ? null : 'Open the live map');
  }

  BotReply _restricted(FaqEntry blocked) {
    if (role == BotRole.guest && !blocked.adminOnly) {
      return BotReply(
        BotReplyKind.restricted,
        'That is available after you sign in. Tap Log in below, or ask me how to create a free resident account.',
        action: BotAction.signIn,
        actionLabel: 'Log in',
        suggestions: starters,
      );
    }
    if (!blocked.adminOnly) {
      // Another role's feature (not an administrator topic).
      return BotReply(
        BotReplyKind.restricted,
        role == BotRole.driver
            ? 'That is a resident feature (for example filing complaints or purok alerts), so it is not on a driver account. For a truck problem, use Report Issue in Account Settings.'
            : 'That is part of the driver app, so it is not on a resident account. I can help you with tracking trucks, alerts, complaints and your account.',
        suggestions: starters,
      );
    }
    return BotReply(
        BotReplyKind.restricted,
        role == BotRole.driver
            ? 'That is handled by the barangay administrator, so I cannot help with it here. You can send them a note through Report Issue in Settings.'
            : role == BotRole.guest
                ? 'That is handled by the barangay administrator, so I cannot help with it here.'
                : 'That is handled by the barangay administrator, so I cannot help with it here. If something is wrong, you can file a report in Report Complaints.',
        suggestions: starters,
      );
  }

  BotReply? _smallTalk(String t) {
    bool any(List<String> words) => words.any((String w) => t.contains(' $w '));
    if (any(<String>['hi', 'hello', 'hey', 'kumusta', 'kamusta', 'good morning', 'good afternoon', 'good evening', 'magandang umaga', 'magandang hapon', 'magandang gabi'])) {
      return BotReply(BotReplyKind.smallTalk, 'Hi! I am Truck Buddy. Ask me how to use the app, for example:', suggestions: starters);
    }
    if (any(<String>['thanks', 'thank you', 'salamat', 'ty'])) {
      return const BotReply(BotReplyKind.smallTalk, 'You are welcome! Anything else?');
    }
    if (any(<String>['who are you', 'what are you', 'sino ka', 'ano ka', 'bot'])) {
      return BotReply(BotReplyKind.smallTalk,
          'I am Truck Buddy, a help assistant built into the app. I answer questions about using the Garbage Tracker from a fixed list of answers; I do not use AI or the internet.',
          suggestions: starters);
    }
    if (any(<String>['help', 'tulong', 'menu', 'what can you do', 'ano pwede'])) {
      return BotReply(BotReplyKind.smallTalk, 'Here are some things I can help with:', suggestions: available.take(6).map((FaqEntry e) => e.question).toList());
    }
    return null;
  }
}

const Set<BotRole> _all = <BotRole>{BotRole.resident, BotRole.driver, BotRole.admin};
const Set<BotRole> _everyone = <BotRole>{BotRole.guest, BotRole.resident, BotRole.driver, BotRole.admin};
const Set<BotRole> _guest = <BotRole>{BotRole.guest};
const Set<BotRole> _resident = <BotRole>{BotRole.resident};
const Set<BotRole> _driver = <BotRole>{BotRole.driver};
const Set<BotRole> _admin = <BotRole>{BotRole.admin};

/// Each role gets answers written for its own screens. Administrators can still read a resident or
/// driver how-to (labelled "For residents:" / "For drivers:", without a button) when no admin
/// answer fits.
const List<FaqEntry> faqKnowledgeBase = <FaqEntry>[
  // ---- Public landing page (not signed in) ----------------------------------------------------
  FaqEntry(
    id: 'guest_what',
    question: 'What is this website?',
    answer: 'This is the Garbage Truck Tracker of Barangay Balintawak, Lipa City. The map shows garbage trucks that are collecting right now. Residents can sign in for collection alerts, the collection status of their purok and to report missed collections.',
    roles: _guest,
    keywords: <String, int>{'what is this': 4, 'website': 3, 'about': 2, 'ano ito': 4, 'para saan': 4, 'purpose': 3},
  ),
  FaqEntry(
    id: 'guest_where_truck',
    question: 'Where is the garbage truck now?',
    answer: 'Trucks that are collecting appear on this map in real time. The card on the map says when no truck is online. Tap a truck to see its details.',
    roles: _guest,
    keywords: <String, int>{'where': 2, 'truck': 1, 'where is the truck': 4, 'nasaan': 3, 'saan': 1, 'location': 2, 'track': 3, 'live': 2, 'map': 2, 'online': 2, 'mapa': 2},
  ),
  FaqEntry(
    id: 'guest_download',
    question: 'How do I get the mobile app?',
    answer: 'Tap Download App at the top of this page to download the Android app, then open the file to install it. Everything also works in this website.',
    roles: _guest,
    keywords: <String, int>{'download': 4, 'app': 2, 'install': 4, 'android': 3, 'apk': 4, 'mobile': 2, 'phone': 2, 'cellphone': 3},
    action: BotAction.downloadApp,
    actionLabel: 'Download App',
  ),
  FaqEntry(
    id: 'guest_sign_up',
    question: 'How do I create an account?',
    answer: 'Tap Create an account below, then choose Resident or Driver. Residents choose their purok and can sign in right away. Drivers must be approved by the barangay administrator first.',
    roles: _guest,
    keywords: <String, int>{'create account': 5, 'create an account': 5, 'sign up': 4, 'signup': 4, 'register': 4, 'account': 2, 'magparehistro': 4, 'gumawa ng account': 5},
    action: BotAction.createAccount,
    actionLabel: 'Create an account',
  ),
  FaqEntry(
    id: 'guest_login',
    question: 'How do I log in?',
    answer: 'Tap Log in below and enter your username or email and password. If you do not have an account yet, ask me how to create one.',
    roles: _guest,
    keywords: <String, int>{'login': 4, 'log in': 4, 'sign in': 4, 'signin': 4, 'mag login': 5, 'paano mag login': 5, 'pumasok': 3},
    action: BotAction.signIn,
    actionLabel: 'Log in',
  ),
  FaqEntry(
    id: 'guest_alerts',
    question: 'Can I get alerts when the truck is near?',
    answer: 'With a free resident account you receive:\n'
        '• "Garbage Truck Approaching" about 15, 10 and 5 minutes before a truck reaches your purok\n'
        '• "Truck arrived" when it reaches your purok\n'
        '• Alerts the driver sends to your purok\n'
        '• Updates when your complaint is In Progress or Resolved\n'
        '• A reminder on your purok\'s collection days (when the barangay has set a schedule)\n'
        'Create an account and choose your purok to start.',
    roles: _guest,
    keywords: <String, int>{'alert': 3, 'notification': 4, 'what notification': 5, 'notify': 3, 'abiso': 3, 'near': 2, 'malapit': 3, 'paalala': 3, 'receive': 2, 'matatanggap': 4},
    action: BotAction.createAccount,
    actionLabel: 'Create an account',
  ),
  FaqEntry(
    id: 'guest_report',
    question: 'How do I report a missed collection?',
    answer: 'Sign in with a resident account, then open Report Complaints and tap New Complaint.',
    roles: _guest,
    keywords: <String, int>{'complaint': 3, 'report': 2, 'reklamo': 3, 'missed': 3, 'uncollected': 3, 'hindi nakolekta': 4, 'hindi kinuha': 4, 'sumbong': 3},
    action: BotAction.signIn,
    actionLabel: 'Log in',
  ),
  FaqEntry(
    id: 'guest_privacy',
    question: 'What information does this page show?',
    answer: "This public page shows only the garbage trucks that are online and their status. Residents' personal details and complaints are never shown here.",
    roles: _guest,
    keywords: <String, int>{'privacy': 4, 'personal': 3, 'data': 2, 'information': 2, 'safe': 2, 'public': 3, 'impormasyon': 3},
  ),

  // ---- Map knowledge (everyone who can see a map) ---------------------------------------------
  FaqEntry(
    id: 'map_colors',
    question: 'What do the colours on the map mean?',
    answer: 'There are three kinds of colour:\n'
        '• Truck colour (the dot and its route line): fixed per truck, so a truck such as GT-007 always has the same colour on every map.\n'
        '• Ring around a truck: its status. Green = collecting, orange = idle or paused, red = full, blue = trip completed, gray = unknown.\n'
        '• Purok markers in Collection Status: green ✓ recent, red ◷ due or overdue, orange ! partial, gray ? no record.\n'
        'Ask me about any of these for details.',
    roles: _everyone,
    keywords: <String, int>{'color': 2, 'colour': 2, 'kulay': 3, 'legend': 3, 'ibig sabihin ng kulay': 4, 'what do the color': 3, 'map color': 4},
  ),
  FaqEntry(
    id: 'map_truck_color',
    question: 'Why does each truck have a different colour?',
    answer: 'Each truck gets its own fixed colour from its truck number, so you can tell trucks apart. GT-007 has the same colour on the live map, in Route History and in the legend. The colour never changes with the status; the ring around the truck shows the status.',
    roles: _everyone,
    keywords: <String, int>{'truck color': 5, 'truck colour': 5, 'different color': 5, 'different colour': 5, 'kulay ng truck': 5, 'iba iba': 3, 'route line color': 4, 'line color': 3},
  ),
  FaqEntry(
    id: 'map_ring',
    question: 'What does the ring around a truck mean?',
    answer: 'The ring (and the status word on the label) is the truck status:\n'
        '• Green: ACTIVE, collecting\n'
        '• Orange: IDLE (online but not moving) or PAUSED by the driver\n'
        '• Red: FULL, going to unload\n'
        '• Blue: COMPLETED, trip finished\n'
        '• Gray: status unknown',
    roles: _everyone,
    keywords: <String, int>{'ring': 5, 'outline': 4, 'border': 3, 'green ring': 5, 'orange ring': 5, 'red ring': 5, 'blue ring': 5, 'bilog': 3},
  ),
  FaqEntry(
    id: 'map_status_words',
    question: 'What do ACTIVE, IDLE, FULL and COMPLETED mean on the map?',
    answer: '• ACTIVE: the truck is on a collection trip.\n'
        '• IDLE: the driver is online but the truck is not moving right now.\n'
        '• PAUSED: the driver paused collecting.\n'
        '• FULL: the truck is full and going to unload; this ends the collection for that trip.\n'
        '• COMPLETED: the trip is finished.\n'
        '• OFFLINE: the driver is not online; offline trucks are not shown on the live map.',
    roles: _everyone,
    keywords: <String, int>{'active': 2, 'idle': 4, 'paused': 3, 'offline': 3, 'status word': 4, 'truck status': 4, 'what does idle mean': 5, 'what does full mean': 5, 'status ng truck': 4},
  ),
  FaqEntry(
    id: 'map_gps_delayed',
    question: 'What does "GPS delayed" mean?',
    answer: '"GPS delayed" appears on a truck label when its phone has not sent a new location for 3 minutes. The marker stays at the last known position until a new GPS update arrives. Weak signal, no mobile data or a closed app usually causes it.',
    roles: _everyone,
    keywords: <String, int>{'gps delayed': 6, 'delayed': 3, 'delay': 2, 'late update': 3, 'not updating': 3, 'stuck': 3, 'hindi gumagalaw': 3},
  ),
  FaqEntry(
    id: 'map_truck_missing',
    question: 'Why is a truck not showing on the map?',
    answer: 'A truck appears on the live map only when all of these are true:\n'
        '• its driver is signed in and on a trip (not COMPLETED or OFFLINE),\n'
        '• its GPS sent a real location in the last 3 minutes,\n'
        '• the driver signed in less than 12 hours ago.\n'
        'A trip starts only after the first real GPS fix, so a truck can take a moment to appear after the driver signs in. A driver using a browser must allow location and keep that tab open.',
    roles: _everyone,
    keywords: <String, int>{'not showing': 5, 'not appear': 5, 'no truck': 3, 'missing': 3, 'disappeared': 5, 'nawala': 5, 'wala sa mapa': 5, 'hindi lumalabas': 5, 'cant see truck': 5, 'not online': 4, 'why offline': 4},
  ),
  FaqEntry(
    id: 'map_verified_visit',
    question: 'What is a verified visit?',
    answer: 'A verified visit is counted when a truck on a real (not simulated) collection trip records at least 3 GPS points and stays at least 60 seconds in one continuous stay inside the purok boundary. It proves the truck was there to collect, but not that every household was served.',
    roles: _everyone,
    keywords: <String, int>{'verified visit': 6, 'verified': 4, 'visit': 2, 'counted': 3, 'how do you know': 3, 'paano nalalaman': 4},
  ),
  FaqEntry(
    id: 'map_no_record',
    question: 'Does "No record" mean my purok was skipped?',
    answer: 'Not necessarily. "No record" (gray ?) means the system has no verified truck visit in that purok in the last 90 days, for example because GPS was off. It is not proof of a missed collection. If garbage was really not collected, please report it.',
    roles: _everyone,
    keywords: <String, int>{'no record': 6, 'question mark': 5, 'gray': 3, 'grey': 3, 'skipped': 4, 'nilaktawan': 5, 'hindi dinaanan': 5},
  ),
  FaqEntry(
    id: 'map_filters',
    question: 'What do "7+ days", "14+ days" and "Live" mean?',
    answer: 'They are filters on the Collection Status map: "7+ days" shows only puroks whose last verified visit is 7 or more days old, "14+ days" shows 14 or more, "All" shows every purok, and "Live" means the status updates automatically as trips are recorded.',
    roles: _everyone,
    keywords: <String, int>{'7 day': 5, '14 day': 5, 'filter': 4, 'live badge': 4, 'seven day': 4, 'fourteen day': 4},
  ),
  FaqEntry(
    id: 'map_eta',
    question: 'How is the ETA calculated?',
    answer: 'The ETA is the distance from the truck to your purok divided by the truck\'s current or recent average speed, so it is approximate. It shows "Arrived" when the truck is within about 60 metres, and "–" when no truck is on the way.',
    roles: _everyone,
    keywords: <String, int>{'eta': 5, 'estimated time': 5, 'arrival time': 4, 'gaano katagal': 4, 'how long': 3, 'minutes away': 4},
  ),
  FaqEntry(
    id: 'map_you_marker',
    question: 'What is the blue dot labelled YOU?',
    answer: 'The blue dot labelled YOU is your own location from your device, shown only to you and only if you allow location. It is never sent to other users.',
    roles: _everyone,
    keywords: <String, int>{'you marker': 6, 'blue dot': 6, 'my location': 4, 'ako ba': 3, 'label you': 5},
  ),
  FaqEntry(
    id: 'map_overlap',
    question: 'Why do some trucks share one label?',
    answer: 'When trucks are within about 5 metres of each other, they keep their real positions and the first marker shows one combined label listing all of them, so labels do not cover each other.',
    roles: _everyone,
    keywords: <String, int>{'share one label': 6, 'same label': 5, 'overlap': 5, 'magkapatong': 5, 'two trucks same place': 5},
  ),
  FaqEntry(
    id: 'map_route_history_line',
    question: 'What do the lines and numbers in Route History mean?',
    answer: 'The line is the recorded GPS path of the selected trip, in that truck\'s colour. The chips show distance, moving time, stationary time and number of stops. A long straight segment usually means GPS was missing for a while, not that the truck drove in a straight line.',
    roles: _all,
    keywords: <String, int>{'route line': 5, 'straight line': 5, 'stops': 3, 'stationary': 4, 'moving time': 4, 'distance': 2, 'playback': 4},
  ),

  // ---- Notifications (signed in) -----------------------------------------------------------------
  FaqEntry(
    id: 'notif_what',
    question: 'What notifications will I receive?',
    answer: 'As a resident you receive:\n'
        '• "Garbage Truck Approaching" about 15, 10 and 5 minutes before a truck reaches your purok\n'
        '• "Truck arrived" when it reaches your purok\n'
        '• Alerts the driver sends to your purok\n'
        '• Updates when your complaint becomes In Progress or Resolved\n'
        '• A reminder on your purok\'s collection days (when the barangay has set a schedule)\n'
        'They appear on your phone and in the bell on your dashboard.',
    roles: _resident,
    keywords: <String, int>{'notification': 4, 'alert': 3, 'what notification': 5, 'receive': 2, 'matatanggap': 4, 'abiso': 3, 'paalala': 3},
  ),
  FaqEntry(
    id: 'notif_driver',
    question: 'What notifications do drivers get?',
    answer: 'Drivers get messages from the administrator, updates on their truck issue reports, and announcements for drivers. Your own GPS creates the approach and arrival alerts that residents receive.',
    roles: _driver,
    keywords: <String, int>{'notification': 4, 'alert': 3, 'what notification': 5, 'receive': 2, 'abiso': 3},
  ),
  FaqEntry(
    id: 'notif_not_receiving',
    question: 'Why am I not receiving notifications?',
    answer: 'Check these:\n'
        '• Notifications are ON in Account Settings and allowed for the app in your phone settings\n'
        '• Your purok in your profile is correct\n'
        '• The app is open or running in the background. If you fully close (swipe away) the app, live truck alerts cannot arrive; collection-day reminders still do\n'
        '• Alerts only come while a driver is on a real trip with GPS on',
    roles: _all,
    keywords: <String, int>{'not receiving': 6, 'no notification': 6, 'not getting': 5, 'walang notification': 6, 'hindi dumarating': 6, 'missing notification': 5, 'no alert': 5},
    action: BotAction.settings,
    actionLabel: 'Open Account Settings',
  ),
  FaqEntry(
    id: 'notif_tap',
    question: 'What happens when I tap a notification?',
    answer: 'Tapping a notification opens your dashboard on the Home tab. If you are not signed in, you go to the sign-in page first.',
    roles: _all,
    keywords: <String, int>{'tap notification': 6, 'click notification': 6, 'press notification': 5, 'pindot': 3, 'open notification': 5},
  ),
  FaqEntry(
    id: 'notif_clear',
    question: 'How do I clear my notifications?',
    answer: 'Open the bell on your dashboard. Swipe a notification left or right to remove it, or tap Clear all to remove them all. Clearing only hides them for your account.',
    roles: _all,
    keywords: <String, int>{'clear': 4, 'clear all': 6, 'delete notification': 6, 'remove notification': 6, 'burahin': 4, 'swipe': 4, 'tanggalin': 4},
  ),
  FaqEntry(
    id: 'notif_turn_off',
    question: 'How do I turn notifications on or off?',
    answer: 'Go to Account Settings and use the notifications switch. Your phone must also allow notifications for Garbage Tracker.',
    roles: _all,
    keywords: <String, int>{'turn off': 5, 'turn on': 5, 'disable notification': 6, 'enable notification': 6, 'patayin': 4, 'mute': 4},
    action: BotAction.settings,
    actionLabel: 'Open Account Settings',
  ),
  FaqEntry(
    id: 'eta_resident',
    question: 'What is the Estimated Time on my dashboard?',
    answer: 'It is how long the nearest truck on an active trip needs to reach your purok: distance divided by the truck\'s current or recent average speed. It shows "Arrived" when the truck is within about 60 metres and "–" when no truck is on the way. It is an estimate, not a guarantee (traffic, stops and GPS signal affect it).',
    roles: _resident,
    keywords: <String, int>{'eta': 5, 'estimated time': 6, 'estimate': 3, 'arrival': 3, 'how long': 3, 'gaano katagal': 5, 'minutes away': 4, 'dash': 2},
  ),

  // ---- Complaints (everyone may ask; filing needs a resident account) -------------------------
  FaqEntry(
    id: 'complaint_categories',
    question: 'What can I report in a complaint?',
    answer: 'Complaint categories: Uncollected Garbage, Spilled Waste, Driver Behavior, Schedule Issue and Other. Choose your purok and describe what happened, when and where. Photos cannot be attached yet.',
    roles: _everyone,
    keywords: <String, int>{'category': 4, 'categories': 4, 'what can i report': 6, 'type of complaint': 6, 'complaint type': 6, 'ano pwedeng ireklamo': 6, 'driver behavior': 5, 'spilled': 3},
  ),
  FaqEntry(
    id: 'complaint_status_meaning',
    question: 'What do Pending, In Progress and Resolved mean?',
    answer: '• Pending: received, not yet handled\n• In Progress: the barangay is working on it\n• Resolved: the barangay marked it as done\nYou get a notification when it becomes In Progress or Resolved.',
    roles: _everyone,
    keywords: <String, int>{'pending': 4, 'in progress': 5, 'resolved': 4, 'complaint status': 5, 'status ng reklamo': 6},
  ),
  FaqEntry(
    id: 'complaint_who',
    question: 'Who can file a complaint, and who sees it?',
    answer: 'Any resident with an account can file a complaint. Only you and the barangay administrators can see it; other residents and drivers cannot. You can delete your own complaint record from Report Complaints.',
    roles: _everyone,
    keywords: <String, int>{'who can file': 6, 'who sees': 6, 'can i complain': 6, 'pwede ba magreklamo': 6, 'private': 3, 'anonymous': 4, 'delete complaint': 6, 'delete my complaint': 7, 'cancel complaint': 6, 'cancel my complaint': 7},
  ),
  FaqEntry(
    id: 'complaint_guest',
    question: 'Can I file a complaint without an account?',
    answer: 'No. Complaints need a resident account so the barangay can reply and keep you updated. Creating one is free.',
    roles: _guest,
    keywords: <String, int>{'without account': 6, 'no account': 5, 'walang account': 6, 'complaint': 2, 'file complaint': 4, 'reklamo': 2},
    action: BotAction.createAccount,
    actionLabel: 'Create an account',
  ),

  // ---- Terms, privacy and policies (everyone) ---------------------------------------------------
  FaqEntry(
    id: 'terms_summary',
    question: 'What are the Terms and Conditions?',
    answer: 'In short: the app is for residents and authorized drivers of Brgy. Balintawak, Lipa City. Give accurate information (including your purok), keep your password safe, use complaints for real issues, and do not impersonate others or try to get around security. GPS and ETA are estimates. Accounts that break the terms can be suspended. You can read the full text from the Terms & Conditions link on the sign-in page.',
    roles: _everyone,
    keywords: <String, int>{'terms': 5, 'terms and conditions': 6, 'condition': 3, 'rules': 3, 'patakaran': 5, 'tuntunin': 5, 'policy': 2},
  ),
  FaqEntry(
    id: 'privacy_summary',
    question: 'What is the Privacy Policy?',
    answer: 'The app collects your name, email, contact number and purok (drivers also license and truck details, and GPS while on duty), plus complaints you file. It is used only to run garbage tracking, alerts and complaint handling. Your data is not sold. Passwords are never stored in plain text. You can update your profile in Account Settings. The full text is linked as Privacy Policy on the sign-in page.',
    roles: _everyone,
    keywords: <String, int>{'privacy': 5, 'privacy policy': 6, 'personal data': 5, 'data privacy': 6, 'my data': 4, 'impormasyon': 3, 'datos': 4},
  ),
  FaqEntry(
    id: 'privacy_location',
    question: 'Who can see my location?',
    answer: 'Drivers: your truck\'s location is visible on the maps only while you are on a collection trip. Residents: your own location (the blue YOU dot) is only shown on your phone and is never shared with other users. Your registered purok is used for alerts.',
    roles: _everyone,
    keywords: <String, int>{'see my location': 6, 'track me': 5, 'my location': 4, 'location privacy': 6, 'nakikita ba': 4, 'lokasyon ko': 5},
  ),
  FaqEntry(
    id: 'privacy_rights',
    question: 'Can I ask the barangay to delete my data?',
    answer: 'Yes. Under the Data Privacy Act (RA 10173) you may request access to, correction of, or deletion of your personal data. Contact the Brgy. Balintawak administration (Contact Support in Account Settings). Some records, such as complaint history, may be kept without your name for barangay records.',
    roles: _everyone,
    keywords: <String, int>{'data privacy act': 9, 'ra 10173': 9, 'delete my data': 9, 'remove my data': 9, 'burahin ang data': 6, 'right to': 3},
  ),

  // ---- General FAQs (everyone) -----------------------------------------------------------------
  FaqEntry(
    id: 'faq_cost',
    question: 'Is the app free?',
    answer: 'Yes. Garbage Tracker is free for residents and drivers of Brgy. Balintawak.',
    roles: _everyone,
    keywords: <String, int>{'free': 4, 'cost': 4, 'bayad': 5, 'libre': 5, 'magkano': 5, 'price': 4},
  ),
  FaqEntry(
    id: 'faq_languages',
    question: 'What languages does the app support?',
    answer: 'English, Filipino and Bisaya. Change the language with the selector on the sign-in page or in Settings. I (Truck Buddy) understand English and Tagalog.',
    roles: _everyone,
    keywords: <String, int>{'language': 5, 'wika': 5, 'tagalog': 4, 'filipino': 4, 'bisaya': 4, 'english': 3},
  ),
  FaqEntry(
    id: 'faq_devices',
    question: 'Which devices can I use?',
    answer: 'The Android app (Download App on the website) or any web browser on a phone or computer. Live truck alerts on a phone need the Android app.',
    roles: _everyone,
    keywords: <String, int>{'device': 4, 'iphone': 5, 'ios': 4, 'computer': 4, 'laptop': 4, 'browser': 4, 'cellphone': 3},
  ),
  FaqEntry(
    id: 'faq_who_runs',
    question: 'Who manages this system?',
    answer: 'The Brgy. Balintawak administration in Lipa City. Administrators approve drivers, handle complaints and manage the collection schedule. For concerns, contact the barangay office or use Contact Support in Account Settings.',
    roles: _everyone,
    keywords: <String, int>{'who manages': 6, 'who runs': 6, 'contact': 3, 'barangay office': 5, 'sino ang': 3, 'admin contact': 5, 'support': 3},
  ),

  // ---- Residents --------------------------------------------------------------------------------
  FaqEntry(
    id: 'where_truck',
    question: 'Where is the garbage truck now?',
    answer: 'Open Truck Tracking to see every truck that is online on the live map. The Active Fleet Status panel lists each truck, its speed and its driver. If no truck is online, nobody is collecting at the moment.',
    roles: _resident,
    keywords: <String, int>{'where': 2, 'truck': 1, 'where is the truck': 4, 'nasaan': 3, 'saan': 1, 'location': 2, 'track': 3, 'tracking': 3, 'live': 2, 'map': 2, 'trak': 1, 'mapa': 2},
    action: BotAction.track,
    actionLabel: 'Open Truck Tracking',
  ),
  FaqEntry(
    id: 'when_collect',
    question: 'When will the truck come to my area?',
    answer: 'Your Dashboard Home shows your purok\'s Collection Schedule (set by the barangay) and an Estimated Time while a truck is on its way. You also get a notification about 15, 10 and 5 minutes before a truck reaches your purok, and when it arrives. Ask me "what day is collection?" for your schedule.',
    roles: _resident,
    keywords: <String, int>{'when': 2, 'schedule': 3, 'kailan': 3, 'oras': 2, 'time': 1, 'eta': 3, 'arrive': 2, 'darating': 3, 'dating': 2, 'iskedyul': 3, 'come': 1, 'estimated': 2},
  ),
  FaqEntry(
    id: 'collection_status',
    question: 'What do the Collection Status colours mean?',
    answer: 'Each purok marker shows how long ago a truck made a verified visit there (Philippine calendar days):\n'
        '• Green ✓ Recent: less than 7 days ago\n'
        '• Red ◷ Due: 7 to 13 days ago\n'
        '• Dark red ◷ Overdue: 14 days or more\n'
        '• Orange ! Partial: only a partial collection is recorded\n'
        '• Gray ? No record: no verified visit in the last 90 days\n'
        'These show truck visits, not a schedule check, and a visit does not prove every household was collected.',
    roles: _everyone,
    keywords: <String, int>{'collection status': 4, 'status color': 4, 'status colour': 4, 'overdue': 3, 'due': 2, 'recent': 2, 'partial': 3, 'nadaanan': 3, 'visited': 2, 'red purok': 3, 'green purok': 3},
    action: BotAction.collectionStatus,
    actionLabel: 'Open Collection Status',
  ),
  FaqEntry(
    id: 'file_complaint',
    question: 'How do I report a missed collection?',
    answer: 'Go to Report Complaints and tap New Complaint. Choose a category (Uncollected Garbage, Spilled Waste, Driver Behavior, Schedule Issue or Other), your purok, and describe the problem. The barangay will review it. You can send up to 3 reports in 24 hours.',
    roles: _resident,
    keywords: <String, int>{'complaint': 3, 'report': 2, 'reklamo': 3, 'missed': 3, 'uncollected': 3, 'hindi nakolekta': 4, 'hindi kinuha': 4, 'spilled': 2, 'file': 1, 'isumbong': 3, 'sumbong': 3, 'problem': 1, 'problema': 1},
    action: BotAction.fileComplaint,
    actionLabel: 'Open Report Complaints',
  ),
  FaqEntry(
    id: 'complaint_progress',
    question: 'How do I check my complaint?',
    answer: 'Open Report Complaints. Active shows complaints that are Pending or Under Review; Resolved shows finished ones. You are also notified when the status changes.',
    roles: _resident,
    keywords: <String, int>{'my complaint': 4, 'complaint status': 4, 'pending': 3, 'under review': 3, 'resolved': 3, 'check complaint': 4, 'follow up': 2, 'update sa reklamo': 4},
    action: BotAction.complaints,
    actionLabel: 'Open my complaints',
  ),
  FaqEntry(
    id: 'resident_route_history',
    question: 'Can I see past trips in my area?',
    answer: 'Yes. Route History shows recorded truck trips that passed through your purok. Use the area selector to switch to All areas, pick dates, then select a trip to replay its route.',
    roles: _resident,
    keywords: <String, int>{'route history': 4, 'past trips': 4, 'history': 2, 'previous': 2, 'kahapon': 2, 'replay': 3, 'nakaraan': 2, 'trips': 2},
    action: BotAction.routeHistory,
    actionLabel: 'Open Route History',
  ),
  FaqEntry(
    id: 'alerts',
    question: 'How do truck alerts work?',
    answer: 'You get a notification (the bell on your dashboard) when a truck on a real trip is about 15, 10 and 5 minutes from your registered purok, and when it arrives there. Keep notifications on in Account Settings and make sure your purok in your profile is correct.',
    roles: _resident,
    keywords: <String, int>{'alert': 3, 'alerts': 3, 'notification': 3, 'notify': 3, 'abiso': 3, 'bell': 2, 'proximity': 3, 'approaching': 2, 'paalala': 3},
    action: BotAction.settings,
    actionLabel: 'Open Account Settings',
  ),
  FaqEntry(
    id: 'change_purok',
    question: 'How do I change my purok or address?',
    answer: 'Go to Account Settings and tap Edit on your profile to update your purok. Your alerts and Route History use this purok.',
    roles: _resident,
    keywords: <String, int>{'purok': 2, 'purok ko': 2, 'palitan': 1, 'address': 3, 'change purok': 4, 'change my purok': 5, 'my purok': 2, 'lipat': 3, 'tirahan': 3, 'area': 1, 'location ko': 3, 'move': 2},
    action: BotAction.settings,
    actionLabel: 'Open Account Settings',
  ),

  // ---- Drivers ----------------------------------------------------------------------------------
  FaqEntry(
    id: 'driver_start',
    question: 'How do I start a collection trip?',
    answer: 'On Dashboard Home, tap NEW TRIP in the Vehicle Console. The trip begins as soon as your phone gets its first real GPS fix, and your truck then appears on the live maps. Keep location on and the app open while collecting. Signing in alone does not start a trip.',
    roles: _driver,
    keywords: <String, int>{'start': 3, 'begin': 3, 'simula': 3, 'umpisa': 3, 'trip': 2, 'collection': 1, 'shift': 2, 'new trip': 5, 'resume': 3},
    action: BotAction.home,
    actionLabel: 'Open Dashboard Home',
  ),
  FaqEntry(
    id: 'driver_status_buttons',
    question: 'What do PAUSE, FULL and COMPLETED do?',
    answer: 'They are in the Vehicle Console on Dashboard Home:\n'
        '• PAUSE: stop collecting for a while (status IDLE); tap RESUME to continue.\n'
        '• FULL: the truck reached capacity; this ends collecting for the trip.\n'
        '• COMPLETED: tap after unloading; the trip is closed and saved to Route History.',
    roles: _driver,
    keywords: <String, int>{'pause': 3, 'full': 3, 'completed': 3, 'complete': 2, 'puno': 3, 'tapos': 2, 'end trip': 3, 'stop': 2, 'button': 1},
  ),
  FaqEntry(
    id: 'driver_gps',
    question: 'My location is not updating. What should I do?',
    answer: 'Check that location (GPS) is turned on and the app is allowed to use it, that you have mobile data, and keep the app open. If it still shows "GPS delayed", log out and log in again. Report repeated problems through Report Issue in Settings.',
    roles: _driver,
    keywords: <String, int>{'gps': 3, 'location': 2, 'not updating': 4, 'delayed': 3, 'signal': 2, 'not moving': 3, 'hindi gumagalaw': 4, 'walang signal': 4, 'permission': 2},
  ),
  FaqEntry(
    id: 'driver_route_plan',
    question: 'Where can I see which areas to collect?',
    answer: 'Open Route Optimization (Route plan) from the sidebar or the Map tab. It shows the areas in your assignment and how recently each was visited.',
    roles: _driver,
    keywords: <String, int>{'route plan': 4, 'route optimization': 4, 'areas': 2, 'assignment': 2, 'which area': 3, 'which areas': 4, 'collect today': 3, 'saan pupunta': 4, 'ruta': 3, 'route': 1},
    action: BotAction.routePlan,
    actionLabel: 'Open Route plan',
  ),
  FaqEntry(
    id: 'driver_history',
    question: 'Can I see my past trips?',
    answer: 'Yes. Route History lists your own recorded trips. Pick a date range and select a trip to replay the route and see distance, stops and duration.',
    roles: _driver,
    keywords: <String, int>{'my trips': 4, 'past trips': 4, 'route history': 4, 'history': 2, 'previous': 2, 'nakaraan': 2},
    action: BotAction.routeHistory,
    actionLabel: 'Open Route History',
  ),
  FaqEntry(
    id: 'driver_issue',
    question: 'How do I report a truck problem?',
    answer: 'Go to Account Settings, Truck Information, then Report Issue. The administrator is notified about the vehicle problem.',
    roles: _driver,
    keywords: <String, int>{'truck problem': 4, 'vehicle': 3, 'issue': 2, 'sira': 3, 'breakdown': 3, 'flat': 2, 'report issue': 4, 'problema sa truck': 4},
    action: BotAction.settings,
    actionLabel: 'Open Account Settings',
  ),
  FaqEntry(
    id: 'driver_auto_logout',
    question: 'Why was I logged out automatically?',
    answer: 'Drivers are signed out automatically after 12 hours for safety. If you chose Remember account, your account stays on the login screen so you can sign in again quickly.',
    roles: _driver,
    keywords: <String, int>{'logged out': 4, 'auto logout': 4, 'automatically': 2, 'na logout': 4, 'nalogout': 4, '12 hours': 3},
  ),
  FaqEntry(
    id: 'driver_change_truck',
    question: 'Can I change my assigned truck?',
    answer: 'Truck and route assignments are set by the administrator. Contact the barangay office or use Contact Support in Settings if you need to be reassigned.',
    roles: _driver,
    keywords: <String, int>{'change truck': 4, 'assigned truck': 4, 'reassign': 3, 'palit truck': 4, 'ibang truck': 4},
  ),

  // ---- Everyone ---------------------------------------------------------------------------------
  FaqEntry(
    id: 'change_password',
    question: 'How do I change my password?',
    answer: 'Go to Account Settings and tap Change Password. If you forgot your password, tap Forgot Password on the login screen to reset it with a code sent to your email.',
    roles: _everyone,
    keywords: <String, int>{'password': 3, 'forgot': 3, 'reset': 2, 'nakalimutan': 3, 'palitan': 1, 'change password': 4},
    action: BotAction.settings,
    actionLabel: 'Open Account Settings',
  ),
  FaqEntry(
    id: 'remember_login',
    question: 'How does Remember account work?',
    answer: 'If Remember account is checked when you sign in, your account appears on the login screen next time so you can continue with one tap. Remove it from the login screen if you share the device.',
    roles: _all,
    keywords: <String, int>{'remember': 3, 'one tap': 3, 'saved login': 4, 'stay signed in': 4, 'auto login': 3},
  ),
  FaqEntry(
    id: 'edit_profile',
    question: 'How do I update my name or photo?',
    answer: 'Open Account Settings. Use Upload to change your photo and the Edit (pencil) button to update your profile details.',
    roles: _all,
    keywords: <String, int>{'profile': 3, 'photo': 3, 'picture': 3, 'name': 2, 'pangalan': 3, 'litrato': 3, 'edit profile': 4, 'email': 1, 'contact number': 3},
    action: BotAction.settings,
    actionLabel: 'Open Account Settings',
  ),
  FaqEntry(
    id: 'delete_account',
    question: 'Can I delete my account?',
    answer: 'Accounts cannot be deleted from the app. Please contact the barangay administrator through Contact Support in Account Settings for account removal requests.',
    roles: _all,
    keywords: <String, int>{'delete account': 5, 'delete my account': 5, 'remove account': 5, 'deactivate': 3, 'burahin': 4, 'tanggalin account': 5},
  ),
  FaqEntry(
    id: 'driver_register',
    question: 'How do I register as a driver?',
    answer: 'Choose Driver on the sign-up page and fill in your details. Driver accounts must be approved by the barangay administrator before you can log in.',
    roles: _everyone,
    keywords: <String, int>{'register': 2, 'sign up': 2, 'signup': 2, 'driver account': 3, 'approval': 2, 'approved': 2, 'magparehistro': 3, 'not approved': 3},
  ),

  // ---- Admin only -------------------------------------------------------------------------------
  FaqEntry(
    id: 'admin_approve',
    question: 'How do I approve new driver accounts?',
    answer: 'Open User Management. Pending driver registrations appear there; review the details, then approve or reject. New registrations also appear in your notifications.',
    roles: _admin,
    keywords: <String, int>{'approve': 4, 'approve driver': 5, 'approve account': 5, 'approve user': 5, 'reject': 4, 'pending driver': 4, 'pending account': 4, 'user management': 4, 'manage users': 4, 'archive user': 4, 'delete user': 4, 'users list': 3},
    action: BotAction.users,
    actionLabel: 'Open User Management',
  ),
  FaqEntry(
    id: 'admin_assign',
    question: 'How do I assign drivers and trucks to areas?',
    answer: 'Open Route Assignments. Pick the collection day, then set the driver, truck and service areas. Drivers see their assignment in their Route plan.',
    roles: _admin,
    keywords: <String, int>{'assign': 4, 'assignment': 3, 'route assignments': 5, 'assign driver': 5, 'assign truck': 5, 'italaga': 3},
    action: BotAction.routeAssignments,
    actionLabel: 'Open Route Assignments',
  ),
  FaqEntry(
    id: 'admin_complaints',
    question: 'How do I handle resident complaints?',
    answer: 'Open Complaint Management (called Complaint Center on phones):\n'
        '• Active lists Pending and In Progress complaints; Resolved Archive keeps finished ones.\n'
        '• Residents shows resident complaints; Drivers shows truck problems reported by drivers.\n'
        '• Search by complaint number or name, and filter by category, location, status and date.\n'
        '• Tap View Details, then Mark In Progress or Mark Resolved (a resolution note is required).\n'
        'The resident gets a notification each time the status changes.',
    roles: _admin,
    keywords: <String, int>{
      'complaint': 3, 'reklamo': 3, 'sumbong': 2, 'complaint management': 6, 'complaint center': 6, 'handle complaints': 6, 'update complaint': 6,
      'resolve complaint': 6, 'all complaints': 5, 'manage complaints': 6, 'manage': 1, 'handle': 1, 'resolve': 2, 'mark resolved': 6,
      'mark in progress': 6, 'resolution note': 6, 'view complaint': 5, 'see complaint': 5, 'check complaint': 5, 'resident complaint': 5,
      'new complaint': 4, 'complaint status': 4, 'pending complaint': 5, 'unresolved': 4, 'paano ayusin ang reklamo': 6,
    },
    action: BotAction.complaints,
    actionLabel: 'Open Complaint Management',
  ),
  FaqEntry(
    id: 'admin_driver_reports',
    question: 'Where do I see truck problems reported by drivers?',
    answer: 'Open Complaint Management and switch to Drivers. Each truck problem a driver sent through Report Issue is listed there; open it to mark it In Progress or Resolved. New reports also appear in your notifications.',
    roles: _admin,
    keywords: <String, int>{'driver report': 6, 'driver issue': 6, 'truck issue': 6, 'truck problem': 6, 'vehicle problem': 6, 'report issue': 5, 'sira': 3, 'breakdown': 4, 'reported by driver': 6, 'driver complaint': 6},
    action: BotAction.complaints,
    actionLabel: 'Open Complaint Management',
  ),
  FaqEntry(
    id: 'admin_backup',
    question: 'How do I back up or export system data?',
    answer: 'Go to System Settings, Data Management. Use Backup System Now for a database snapshot, Export System Data for reports, or Open Database Center for backups, archives and cleanup.',
    roles: _admin,
    keywords: <String, int>{'backup': 5, 'back up': 5, 'export': 4, 'database': 4, 'database center': 5, 'restore': 4, 'archive': 3, 'excel': 3},
    action: BotAction.settings,
    actionLabel: 'Open System Settings',
  ),
  FaqEntry(
    id: 'admin_schedule',
    question: 'How do I set the collection schedule?',
    answer: 'Go to System Settings, Service Area & Route Management, Collection Schedule. Pick the days and usual time for each purok and tap Save. Residents then see it on their dashboard, get reminders on their phone, and I can answer "what day is collection?".',
    roles: _admin,
    keywords: <String, int>{'set schedule': 6, 'collection schedule': 5, 'edit schedule': 6, 'change schedule': 6, 'schedule': 2, 'iskedyul': 3},
    action: BotAction.settings,
    actionLabel: 'Open System Settings',
  ),
  FaqEntry(
    id: 'admin_analytics',
    question: 'Where are the reports and analytics?',
    answer: 'Open System Analytics for collection, complaint, load and ETA performance charts. You can pick a date range and export a PDF report.',
    roles: _admin,
    keywords: <String, int>{'analytics': 5, 'statistics': 4, 'charts': 4, 'performance': 3, 'pdf report': 4, 'system report': 4, 'kpi': 4},
    action: BotAction.analytics,
    actionLabel: 'Open System Analytics',
  ),
  FaqEntry(
    id: 'admin_driver_tracking',
    question: "How do I see every driver's trips?",
    answer: 'Driver Route History shows the trips of all drivers. Filter by driver and date, then select a trip to replay it.',
    roles: _admin,
    keywords: <String, int>{'all drivers': 5, 'every driver': 5, 'other drivers': 5, 'driver trips': 4, 'driver performance': 5, 'driver records': 5},
    action: BotAction.routeHistory,
    actionLabel: 'Open Driver Route History',
  ),
  FaqEntry(
    id: 'admin_security',
    question: 'How do I manage system security settings?',
    answer: 'Open System Settings, Security, for two-factor authentication and administrator permissions.',
    roles: _admin,
    keywords: <String, int>{'permissions': 4, 'system settings': 4, 'admin access': 5, 'admin account': 5, 'other users password': 5, 'user passwords': 5, 'api key': 5, 'credentials': 5},
    action: BotAction.settings,
    actionLabel: 'Open System Settings',
  ),
  FaqEntry(
    id: 'admin_track',
    question: 'Where can I see the trucks live?',
    answer: 'Open Fleet GIS Tracking (Track on phones). It shows every truck that is online on the live map with its status ring, and Active Fleet Status lists each truck with its driver and speed. Use the Map / Satellite switch for the map style. The dashboard also has a small Live Fleet Monitoring map.',
    roles: _admin,
    keywords: <String, int>{'where': 2, 'truck': 1, 'where is the truck': 5, 'nasaan': 3, 'live map': 5, 'fleet': 3, 'fleet gis': 6, 'track': 3, 'tracking': 3, 'gps': 2, 'mapa': 2, 'map': 2, 'location': 2, 'monitor': 3},
    action: BotAction.track,
    actionLabel: 'Open Fleet GIS Tracking',
  ),
  FaqEntry(
    id: 'admin_notifications',
    question: 'What notifications do administrators get?',
    answer: 'You are notified about new complaints, new account registrations waiting for approval, truck problems reported by drivers, and trucks arriving in the puroks. Open the bell on the dashboard to read them; swipe one away or use Clear all (that only hides them for your account).',
    roles: _admin,
    keywords: <String, int>{'notification': 4, 'alert': 3, 'what notification': 5, 'bell': 3, 'abiso': 3, 'notify': 3},
  ),
  FaqEntry(
    id: 'admin_collection_status',
    question: 'How do I see which puroks were visited or are overdue?',
    answer: 'Open Collection Route Optimization. Each purok shows its last verified truck visit (green recent, red due or overdue, gray no record), and you can compare recorded trip paths. A verified visit needs a real trip that stayed inside the purok; it does not prove every household was served.',
    roles: _admin,
    keywords: <String, int>{'collection status': 5, 'overdue': 4, 'visited': 3, 'not visited': 5, 'route optimization': 6, 'coverage': 3, 'which purok': 4, 'skipped': 3, 'nadaanan': 4, 'optimization': 4},
    action: BotAction.collectionStatus,
    actionLabel: 'Open Collection Route Optimization',
  ),
  FaqEntry(
    id: 'admin_service_areas',
    question: 'How do I add or edit puroks and service areas?',
    answer: "Go to System Settings, Service Area & Route Management, Manage Service Areas. There you can review each area's coordinates, type and whether it is a collection stop. Reset Balintawak Defaults restores the original barangay areas.",
    roles: _admin,
    keywords: <String, int>{'service area': 6, 'add purok': 6, 'new purok': 6, 'add area': 6, 'new area': 5, 'edit purok': 6, 'delete purok': 6, 'purok': 2, 'purok boundary': 6, 'geofence': 6, 'coordinates': 4, 'manage areas': 6, 'collection stop': 5, 'truck stop': 5},
    action: BotAction.settings,
    actionLabel: 'Open System Settings',
  ),
  FaqEntry(
    id: 'admin_dashboard',
    question: 'What do the numbers on the admin dashboard mean?',
    answer: '• Online Drivers: drivers signed in right now\n'
        '• Pending Issues: resident complaints still pending (all time)\n'
        '• Route Coverage: share of collection areas with a verified visit in the last 7 days\n'
        '• Total Residents: registered resident accounts\n'
        'Recent Activity lists the latest system events.',
    roles: _admin,
    keywords: <String, int>{'dashboard': 4, 'online drivers': 5, 'pending issues': 6, 'route coverage': 6, 'total residents': 6, 'recent activity': 6, 'numbers': 2, 'overview': 3},
    action: BotAction.home,
    actionLabel: 'Open Dashboard Overview',
  ),
  FaqEntry(
    id: 'admin_eta',
    question: 'How accurate are the ETAs?',
    answer: "The ETA is the distance divided by the truck's current or recent average speed, so it is an estimate. System Analytics shows ETA performance: how close past ETAs were to the real arrival times.",
    roles: _admin,
    keywords: <String, int>{'eta': 5, 'estimated time': 5, 'eta performance': 6, 'accuracy': 4, 'accurate': 4, 'arrival': 3},
    action: BotAction.analytics,
    actionLabel: 'Open System Analytics',
  ),
  FaqEntry(
    id: 'admin_reports_export',
    question: 'How do I download a report?',
    answer: 'In System Analytics tap EXPORT, choose the report and PDF or Excel, then tap Download Report. For a full data export use System Settings, Data Management, Export System Data.',
    roles: _admin,
    keywords: <String, int>{'download report': 6, 'export report': 6, 'report': 2, 'pdf': 4, 'excel': 4, 'xlsx': 4, 'print': 3, 'ulat': 3},
    action: BotAction.analytics,
    actionLabel: 'Open System Analytics',
  ),
  FaqEntry(
    id: 'driver_manual_alert',
    question: 'How do I alert residents that I am arriving?',
    answer: 'On Dashboard Home, tap Manual Alert in the quick actions and choose the area; residents of that purok get a notification. Usually you do not need it: during a trip your GPS sends the approach and arrival alerts automatically.',
    roles: _driver,
    keywords: <String, int>{'manual alert': 6, 'alert resident': 6, 'notify resident': 6, 'send alert': 5, 'abisuhan': 5, 'announce': 4, 'arriving': 3},
    action: BotAction.home,
    actionLabel: 'Open Dashboard Home',
  ),
  FaqEntry(
    id: 'driver_simulation',
    question: 'What is Simulation mode?',
    answer: 'Simulation (in the quick actions) moves a demo truck along a route without real GPS, for training or demonstrations. Simulated trips are kept separately and never count as real collection visits. Tap Real GPS to switch back.',
    roles: _driver,
    keywords: <String, int>{'simulation': 6, 'simulate': 5, 'demo': 4, 'real gps': 5, 'practice': 3, 'test trip': 4},
    action: BotAction.home,
    actionLabel: 'Open Dashboard Home',
  ),
  FaqEntry(
    id: 'driver_progress',
    question: 'How do I see my collection progress this week?',
    answer: 'Tap Progress in the quick actions on Dashboard Home. It lists this week\'s areas and which ones you have already visited.',
    roles: _driver,
    keywords: <String, int>{'progress': 5, 'weekly': 3, 'this week': 4, 'checklist': 4, 'visited areas': 5, 'done areas': 4},
    action: BotAction.home,
    actionLabel: 'Open Dashboard Home',
  ),
  FaqEntry(
    id: 'driver_map',
    question: 'Where is the map for drivers?',
    answer: 'Open Map Tracking. It shows your truck, the other trucks that are online, and the collection areas. Route Optimization shows the areas in your assignment.',
    roles: _driver,
    keywords: <String, int>{'map': 3, 'map tracking': 6, 'live map': 5, 'where am i': 4, 'my truck': 3, 'other trucks': 4, 'mapa': 3},
    action: BotAction.track,
    actionLabel: 'Open Map Tracking',
  ),
];
