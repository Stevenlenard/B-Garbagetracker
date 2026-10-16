import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../api/api_guard.dart';
import '../api/api_service.dart';
import '../utils/complaint_flow.dart';

/// Primary Complaint Center tabs. Both read the same records; only the persisted status decides.
enum ComplaintScope { active, resolved }

/// Who filed it: resident complaints live in MySQL, driver truck reports in Firebase `truck_issues`.
enum ComplaintSource { resident, driver }

DateTime? _parseDate(Object? v) {
  if (v == null) return null;
  if (v is int) return v > 0 ? DateTime.fromMillisecondsSinceEpoch(v) : null;
  if (v is num) return v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
  final String s = v.toString().trim();
  if (s.isEmpty || s.startsWith('0000')) return null;
  final int? ms = int.tryParse(s);
  if (ms != null) return ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

String? _text(Object? v) {
  final String s = (v ?? '').toString().trim();
  return s.isEmpty ? null : s;
}

/// Stored puroks use several spellings of one service area ("Purok 1", "Central (Purok 1)");
/// the server matches any of these terms (same aliases as ServiceAreaService.canonicalizeAreaName).
class ComplaintLocations {
  ComplaintLocations._();

  static const Map<String, List<String>> _terms = <String, List<String>>{
    'Ayala Highway': <String>['ayala', 'almarius', 'almaris', 'fat grill'],
    'Brixton Homes': <String>['brixton'],
    'Central (Purok 1)': <String>['central', 'purok 1'],
    'Purok 2': <String>['purok 2'],
    'Purok 3': <String>['purok 3', 'dos riles', 'purok tres'],
    'Purok 4 / El Pueblo': <String>['purok 4', 'el pueblo', 'elpueblo'],
    'Purok Paraiso': <String>['paraiso', 'sweeping'],
    'Riverside': <String>['riverside'],
    'San Nicolas': <String>['san nicolas'],
    'T.M. Kalaw Street': <String>['kalaw', 't.m.'],
  };

  static List<String> termsFor(String area) => _terms[area] ?? <String>[area];

  /// The `location` request value: alias terms joined by "|".
  static String param(String area) => termsFor(area).join('|');
}

/// One complaint as every Complaint Center view shows it.
class ComplaintRecord {
  ComplaintRecord({
    required this.id,
    required this.source,
    required this.category,
    required this.description,
    required this.reporterName,
    required this.status,
    this.reporterId,
    this.purok,
    this.location,
    this.truckId,
    this.urgency,
    this.submittedAt,
    this.inProgressAt,
    this.resolvedAt,
    this.updatedAt,
    this.resolutionNote,
    this.resolvedBy,
    Map<String, dynamic>? raw,
  }) : raw = raw ?? const <String, dynamic>{};

  final String id;
  final ComplaintSource source;
  final String category;
  final String description;
  final String reporterName;
  final String? reporterId;
  final ComplaintStatus status;
  final String? purok;
  final String? location;
  final String? truckId;
  final String? urgency;
  final DateTime? submittedAt;
  final DateTime? inProgressAt;
  final DateTime? resolvedAt;
  final DateTime? updatedAt;

  /// admin_response (resident) / adminResponse (driver). For a resolved complaint this is the
  /// resolution note; before that, an optional review note.
  final String? resolutionNote;
  final String? resolvedBy;
  final Map<String, dynamic> raw;

  bool get isResolved => status == ComplaintStatus.resolved;

  String get roleLabel => source == ComplaintSource.resident ? 'Resident' : 'Driver';

  /// "#043" for MySQL complaints; driver reports have Firebase keys ("#…A1B2C3").
  String get displayId {
    if (source == ComplaintSource.resident) return ComplaintFlow.displayId(id);
    return '#${id.length > 6 ? id.substring(id.length - 6).toUpperCase() : id.toUpperCase()}';
  }

  String? get locationLabel {
    final String? p = purok == 'Unknown' ? null : purok;
    if (p != null && location != null && location != p) return '$p • $location';
    return p ?? location;
  }

  factory ComplaintRecord.fromResident(Map<String, dynamic> j) {
    return ComplaintRecord(
      id: (j['complaint_id'] ?? j['id'] ?? '').toString(),
      source: ComplaintSource.resident,
      category: _text(j['category']) ?? 'General',
      description: (j['description'] ?? '').toString(),
      reporterName: _text(j['full_name']) ?? 'Resident',
      reporterId: _text(j['resident_id'] ?? j['user_id']),
      status: ComplaintFlow.statusOf(j['status']),
      purok: _text(j['purok']),
      location: _text(j['location']),
      submittedAt: _parseDate(j['created_at']),
      inProgressAt: _parseDate(j['in_progress_at']),
      resolvedAt: _parseDate(j['resolved_at']),
      updatedAt: _parseDate(j['updated_at']),
      resolutionNote: _text(j['admin_response']),
      resolvedBy: _text(j['resolved_by_name']),
      raw: j,
    );
  }

  factory ComplaintRecord.fromDriverIssue(String key, Map<String, dynamic> j) {
    final ComplaintStatus status = ComplaintFlow.statusOf(j['status']);
    return ComplaintRecord(
      id: key,
      source: ComplaintSource.driver,
      category: _text(j['issueType']) ?? 'Truck Issue',
      description: (j['description'] ?? '').toString(),
      reporterName: _text(j['driverName']) ?? 'Driver',
      reporterId: _text(j['driverId']),
      status: status,
      truckId: _text(j['truckId']),
      urgency: _text(j['urgency']),
      submittedAt: _parseDate(j['createdAt']),
      inProgressAt: _parseDate(j['inProgressAt']),
      resolvedAt: _parseDate(j['resolvedAt']) ?? (status == ComplaintStatus.resolved ? _parseDate(j['updatedAt']) : null),
      updatedAt: _parseDate(j['updatedAt']),
      resolutionNote: _text(j['adminResponse']),
      resolvedBy: _text(j['resolvedByName']),
      raw: j,
    );
  }
}

class ComplaintCounts {
  const ComplaintCounts({this.pending = 0, this.inProgress = 0, this.resolved = 0});

  final int pending;
  final int inProgress;
  final int resolved;

  factory ComplaintCounts.fromJson(Object? j) {
    if (j is! Map) return const ComplaintCounts();
    int n(Object? v) => int.tryParse((v ?? '0').toString()) ?? 0;
    return ComplaintCounts(pending: n(j['pending']), inProgress: n(j['in_progress']), resolved: n(j['resolved']));
  }

  factory ComplaintCounts.of(Iterable<ComplaintRecord> all) {
    int p = 0, i = 0, r = 0;
    for (final ComplaintRecord c in all) {
      switch (c.status) {
        case ComplaintStatus.pending:
          p++;
        case ComplaintStatus.inProgress:
          i++;
        case ComplaintStatus.resolved:
          r++;
      }
    }
    return ComplaintCounts(pending: p, inProgress: i, resolved: r);
  }
}

/// Filters + page of one Complaint Center view.
class ComplaintQuery {
  const ComplaintQuery({
    this.scope = ComplaintScope.active,
    this.source = ComplaintSource.resident,
    this.status,
    this.search = '',
    this.category,
    this.location,
    this.from,
    this.to,
    this.page = 1,
    this.perPage = defaultPageSize,
  });

  static const int defaultPageSize = 15;

  final ComplaintScope scope;
  final ComplaintSource source;

  /// Pending or In Progress (Active Complaints only).
  final ComplaintStatus? status;
  final String search;
  final String? category;
  final String? location;
  final DateTime? from;
  final DateTime? to;
  final int page;
  final int perPage;

  bool get hasFilters =>
      search.trim().isNotEmpty || category != null || location != null || from != null || to != null || status != null;

  ComplaintQuery copyWith({
    ComplaintScope? scope,
    ComplaintSource? source,
    ComplaintStatus? Function()? status,
    String? search,
    String? Function()? category,
    String? Function()? location,
    DateTime? Function()? from,
    DateTime? Function()? to,
    int? page,
  }) {
    return ComplaintQuery(
      scope: scope ?? this.scope,
      source: source ?? this.source,
      status: status != null ? status() : this.status,
      search: search ?? this.search,
      category: category != null ? category() : this.category,
      location: location != null ? location() : this.location,
      from: from != null ? from() : this.from,
      to: to != null ? to() : this.to,
      page: page ?? this.page,
      perPage: perPage,
    );
  }

  /// Same filters, first page (any filter change starts again at page 1).
  ComplaintQuery cleared() => ComplaintQuery(scope: scope, source: source, perPage: perPage);

  static String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Query parameters for complaint_center.php (resident complaints).
  Map<String, dynamic> toParams() => <String, dynamic>{
        'action': 'list',
        'scope': scope == ComplaintScope.resolved ? 'resolved' : 'active',
        if (scope == ComplaintScope.active && status != null && status != ComplaintStatus.resolved)
          'status': ComplaintFlow.apiValue(status!),
        if (search.trim().isNotEmpty) 'q': search.trim(),
        if (category != null) 'category': category,
        if (location != null) 'location': ComplaintLocations.param(location!),
        if (from != null) 'date_from': ymd(from!),
        if (to != null) 'date_to': ymd(to!),
        'page': page,
        'per_page': perPage,
      };
}

class ComplaintPage {
  const ComplaintPage({
    required this.items,
    required this.total,
    required this.page,
    required this.perPage,
    required this.counts,
  });

  final List<ComplaintRecord> items;

  /// Every record matching the filters (not just this page).
  final int total;
  final int page;
  final int perPage;

  /// Real totals per state for the source (all records, unfiltered).
  final ComplaintCounts counts;

  int get pageCount => total == 0 ? 1 : ((total + perPage - 1) ~/ perPage);
  bool get hasMore => page < pageCount;
  int get firstIndex => total == 0 ? 0 : (page - 1) * perPage + 1;
  int get lastIndex => total == 0 ? 0 : (firstIndex + items.length - 1);

  static ComplaintPage fromJson(Map<String, dynamic> j) {
    final Object? data = j['data'];
    final List<ComplaintRecord> items = data is List
        ? data.whereType<Map>().map((Map m) => ComplaintRecord.fromResident(Map<String, dynamic>.from(m))).toList()
        : <ComplaintRecord>[];
    int n(Object? v, int d) => int.tryParse((v ?? '').toString()) ?? d;
    return ComplaintPage(
      items: items,
      total: n(j['total'], items.length),
      page: n(j['page'], 1),
      perPage: n(j['per_page'], ComplaintQuery.defaultPageSize),
      counts: ComplaintCounts.fromJson(j['counts']),
    );
  }
}

class ComplaintHistoryEvent {
  const ComplaintHistoryEvent({required this.status, this.at, this.note, this.by, this.derived = false});

  final ComplaintStatus status;
  final DateTime? at;
  final String? note;
  final String? by;

  /// Reconstructed from timestamps (no stored history row).
  final bool derived;

  factory ComplaintHistoryEvent.fromJson(Map<String, dynamic> j) => ComplaintHistoryEvent(
        status: ComplaintFlow.statusOf(j['to_status']),
        at: _parseDate(j['at']),
        note: _text(j['note']),
        by: _text(j['by']),
        derived: j['derived'] == true,
      );

  /// History available without a stored audit trail.
  static List<ComplaintHistoryEvent> derive(ComplaintRecord c) => <ComplaintHistoryEvent>[
        if (c.submittedAt != null) ComplaintHistoryEvent(status: ComplaintStatus.pending, at: c.submittedAt, derived: true),
        if (c.inProgressAt != null) ComplaintHistoryEvent(status: ComplaintStatus.inProgress, at: c.inProgressAt, derived: true),
        if (c.isResolved)
          ComplaintHistoryEvent(
              status: ComplaintStatus.resolved, at: c.resolvedAt, note: c.resolutionNote, by: c.resolvedBy, derived: true),
      ];
}

class ComplaintDetail {
  const ComplaintDetail({required this.record, required this.history});

  final ComplaintRecord record;
  final List<ComplaintHistoryEvent> history;
}

/// Outcome of an Admin status change, as confirmed by the authoritative store.
class TransitionResult {
  const TransitionResult({required this.changed, required this.status, this.message, this.notification});

  /// False when the complaint was already in [status] (double click, retry, another admin).
  final bool changed;
  final ComplaintStatus status;
  final String? message;

  /// 'sent' | 'already' | 'failed' | 'skipped' (null when the server did not say).
  final String? notification;

  bool get notificationFailed => notification == 'failed';
}

/// Resident complaints (MySQL, through the PHP API).
abstract class ResidentComplaintApi {
  Future<ComplaintPage> fetchPage(ComplaintQuery q);
  Future<ComplaintDetail> fetchDetail(String id);
  Future<TransitionResult> updateStatus(String id, ComplaintStatus to, String note);
}

class HttpResidentComplaintApi implements ResidentComplaintApi {
  HttpResidentComplaintApi([ApiService? api]) : _api = api ?? ApiService();

  final ApiService _api;

  @override
  Future<ComplaintPage> fetchPage(ComplaintQuery q) async {
    final Map<String, dynamic> body = ApiGuard.requireSuccess(ApiGuard.jsonMap(await _api.getComplaintCenter(q.toParams())),
        fallback: 'Complaints could not be loaded.');
    return ComplaintPage.fromJson(body);
  }

  @override
  Future<ComplaintDetail> fetchDetail(String id) async {
    final Map<String, dynamic> body = ApiGuard.requireSuccess(ApiGuard.jsonMap(await _api.getComplaintDetail(id)),
        fallback: 'The complaint could not be loaded.');
    final ComplaintRecord record = ComplaintRecord.fromResident(Map<String, dynamic>.from(body['data'] as Map));
    final Object? h = body['history'];
    final List<ComplaintHistoryEvent> history = h is List
        ? h.whereType<Map>().map((Map m) => ComplaintHistoryEvent.fromJson(Map<String, dynamic>.from(m))).toList()
        : ComplaintHistoryEvent.derive(record);
    return ComplaintDetail(record: record, history: history);
  }

  @override
  Future<TransitionResult> updateStatus(String id, ComplaintStatus to, String note) async {
    final int? n = int.tryParse(id);
    if (n == null) throw ApiResponseException('Invalid complaint id.');
    final Map<String, dynamic> body = ApiGuard.requireSuccess(
        ApiGuard.jsonMap(await _api.updateComplaint(n, ComplaintFlow.apiValue(to), note.trim().isEmpty ? null : note.trim())),
        fallback: 'The complaint could not be updated.');
    return TransitionResult(
      changed: body['changed'] != false,
      status: ComplaintFlow.statusOf(body['status'] ?? ComplaintFlow.apiValue(to)),
      message: ApiGuard.serverMessage(body),
      notification: body['notification']?.toString(),
    );
  }
}

/// Driver truck reports (Firebase `truck_issues`).
abstract class DriverIssueStore {
  Stream<List<ComplaintRecord>> watch();
  Future<TransitionResult> updateStatus(ComplaintRecord issue, ComplaintStatus to, String note);
}

class FirebaseDriverIssueStore implements DriverIssueStore {
  FirebaseDriverIssueStore([FirebaseDatabase? db]) : _db = db ?? FirebaseDatabase.instance;

  final FirebaseDatabase _db;

  @override
  Stream<List<ComplaintRecord>> watch() {
    return _db.ref('truck_issues').onValue.map((DatabaseEvent e) {
      final Object? v = e.snapshot.value;
      final List<ComplaintRecord> list = <ComplaintRecord>[];
      if (v is Map) {
        v.forEach((Object? k, Object? value) {
          if (value is Map) list.add(ComplaintRecord.fromDriverIssue(k.toString(), Map<String, dynamic>.from(value)));
        });
      }
      return list;
    });
  }

  /// Guarded with a Firebase transaction: only one Admin can move a report into a state, and
  /// the private notification uses one fixed key per report and state (no duplicates).
  @override
  Future<TransitionResult> updateStatus(ComplaintRecord issue, ComplaintStatus to, String note) async {
    final DatabaseReference ref = _db.ref('truck_issues/${issue.id}');
    final int now = DateTime.now().millisecondsSinceEpoch;
    String outcome = 'missing';
    final TransactionResult tx = await ref.runTransaction((Object? current) {
      if (current == null) {
        outcome = 'missing';
        return Transaction.success(current); // first local pass may be empty; the server value follows
      }
      if (current is! Map) {
        outcome = 'missing';
        return Transaction.abort();
      }
      final Map<String, dynamic> m = Map<String, dynamic>.from(current);
      final ComplaintStatus from = ComplaintFlow.statusOf(m['status']);
      if (from == to) {
        outcome = 'already';
        return Transaction.abort();
      }
      if (!ComplaintFlow.canTransition(from, to)) {
        outcome = 'conflict';
        return Transaction.abort();
      }
      outcome = 'changed';
      m['status'] = ComplaintFlow.driverIssueValue(to);
      if (note.trim().isNotEmpty) m['adminResponse'] = note.trim();
      m['updatedAt'] = now;
      if (to == ComplaintStatus.inProgress) m['inProgressAt'] = now;
      if (to == ComplaintStatus.resolved) m['resolvedAt'] = now;
      return Transaction.success(m);
    }, applyLocally: false);

    if (outcome == 'missing' || (outcome == 'changed' && !tx.committed)) {
      throw ApiResponseException('This report no longer exists or could not be updated.');
    }
    if (outcome == 'conflict') {
      throw ApiResponseException('This report was already resolved by another administrator. Please refresh.');
    }
    final String notification = await _notify(issue, to);
    return TransitionResult(
      changed: outcome == 'changed',
      status: to,
      message: outcome == 'already' ? 'This report is already ${ComplaintFlow.label(to).toLowerCase()}.' : null,
      notification: notification,
    );
  }

  Future<String> _notify(ComplaintRecord issue, ComplaintStatus to) async {
    final String? driverId = issue.reporterId;
    if (driverId == null) return 'skipped';
    try {
      final DatabaseReference ref = _db.ref('notifications/${ComplaintFlow.driverIssueNotificationKey(issue.id, to)}');
      if ((await ref.get()).exists) return 'already';
      await ref.set(ComplaintFlow.driverIssueNotification(
          issueId: issue.id, driverId: driverId, issueType: issue.category, status: to, timestamp: ServerValue.timestamp));
      return 'sent';
    } catch (e) {
      debugPrint('driver report notification failed: $e');
      return 'failed';
    }
  }
}

/// Client-side filter + page for driver reports (the whole `truck_issues` node is streamed).
class DriverIssuePager {
  DriverIssuePager._();

  static bool matches(ComplaintRecord c, ComplaintQuery q) {
    if (q.scope == ComplaintScope.resolved ? !c.isResolved : c.isResolved) return false;
    if (q.scope == ComplaintScope.active && q.status != null && c.status != q.status) return false;
    if (q.category != null && c.category != q.category) return false;
    final String s = q.search.trim().toLowerCase();
    if (s.isNotEmpty) {
      final String hay = '${c.displayId} ${c.id} ${c.reporterName} ${c.truckId ?? ''} ${c.category}'.toLowerCase();
      if (!hay.contains(s.startsWith('#') ? s.substring(1) : s)) return false;
    }
    if (q.from != null || q.to != null) {
      final DateTime? d = q.scope == ComplaintScope.resolved ? (c.resolvedAt ?? c.submittedAt) : c.submittedAt;
      if (d == null) return false;
      final DateTime day = DateTime(d.year, d.month, d.day);
      if (q.from != null && day.isBefore(DateTime(q.from!.year, q.from!.month, q.from!.day))) return false;
      if (q.to != null && day.isAfter(DateTime(q.to!.year, q.to!.month, q.to!.day))) return false;
    }
    return true;
  }

  static ComplaintPage page(List<ComplaintRecord> all, ComplaintQuery q) {
    final List<ComplaintRecord> hits = all.where((ComplaintRecord c) => matches(c, q)).toList()
      ..sort((ComplaintRecord a, ComplaintRecord b) {
        DateTime key(ComplaintRecord c) =>
            (q.scope == ComplaintScope.resolved ? (c.resolvedAt ?? c.submittedAt) : c.submittedAt) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final int byDate = key(b).compareTo(key(a));
        return byDate != 0 ? byDate : b.id.compareTo(a.id);
      });
    final int pages = hits.isEmpty ? 1 : (hits.length + q.perPage - 1) ~/ q.perPage;
    final int page = q.page.clamp(1, pages);
    final int start = (page - 1) * q.perPage;
    return ComplaintPage(
      items: hits.skip(start).take(q.perPage).toList(),
      total: hits.length,
      page: page,
      perPage: q.perPage,
      counts: ComplaintCounts.of(all),
    );
  }
}

/// State of the Admin Complaint Center (one controller, four views: Active/Resolved x Residents/Drivers).
class ComplaintCenterController extends ChangeNotifier {
  ComplaintCenterController({ResidentComplaintApi? residentApi, DriverIssueStore? driverStore})
      : _residentApi = residentApi ?? HttpResidentComplaintApi(),
        _driverStore = driverStore ?? FirebaseDriverIssueStore();

  final ResidentComplaintApi _residentApi;
  final DriverIssueStore _driverStore;
  StreamSubscription<List<ComplaintRecord>>? _driverSub;

  ComplaintQuery _query = const ComplaintQuery();
  ComplaintPage? _page;
  ComplaintCounts _residentCounts = const ComplaintCounts();
  List<ComplaintRecord>? _driverIssues;
  String? _driverError;
  bool _loading = false;
  String? _error;
  int _generation = 0;
  bool _disposed = false;

  ComplaintQuery get query => _query;
  ComplaintPage? get page => _page;
  List<ComplaintRecord> get items => _page?.items ?? const <ComplaintRecord>[];
  bool get loading => _loading;
  String? get error => _query.source == ComplaintSource.driver ? (_driverError ?? _error) : _error;
  bool get driverIssuesLoaded => _driverIssues != null;

  /// True once the server has returned resident counts at least once. Until then the counts
  /// are UNKNOWN (shown as "–"), never a confirmed zero; a later failed reload keeps the last
  /// counts the server returned.
  bool get residentCountsLoaded => _residentCountsLoaded;
  bool _residentCountsLoaded = false;

  /// Whether the counters for the current source come from real data.
  bool get countsKnown => _query.source == ComplaintSource.driver ? driverIssuesLoaded : _residentCountsLoaded;

  ComplaintCounts get counts => _query.source == ComplaintSource.driver
      ? ComplaintCounts.of(_driverIssues ?? const <ComplaintRecord>[])
      : _residentCounts;

  /// Starts the driver report stream and loads the first resident page.
  void start() {
    _driverSub ??= _driverStore.watch().listen((List<ComplaintRecord> list) {
      _driverIssues = list;
      _driverError = null;
      if (_query.source == ComplaintSource.driver) _rebuildDriverPage();
      _notify();
    }, onError: (Object e) {
      _driverError = 'Driver reports could not be loaded: ${ApiGuard.messageFor(e)}';
      _notify();
    });
    load();
  }

  Future<void> setScope(ComplaintScope s) => _apply(_query.copyWith(scope: s, status: () => null, page: 1));

  /// Active Complaints, optionally only Pending or only In Progress (one request).
  Future<void> showActive({ComplaintStatus? status}) =>
      _apply(_query.copyWith(scope: ComplaintScope.active, status: () => status, page: 1));
  Future<void> setSource(ComplaintSource s) => _apply(ComplaintQuery(scope: _query.scope, source: s, perPage: _query.perPage));
  Future<void> setStatus(ComplaintStatus? s) => _apply(_query.copyWith(status: () => s, page: 1));
  Future<void> setSearch(String s) => s.trim() == _query.search.trim() ? Future<void>.value() : _apply(_query.copyWith(search: s, page: 1));
  Future<void> setCategory(String? c) => _apply(_query.copyWith(category: () => c, page: 1));
  Future<void> setLocation(String? l) => _apply(_query.copyWith(location: () => l, page: 1));
  Future<void> setDateRange(DateTime? from, DateTime? to) => _apply(_query.copyWith(from: () => from, to: () => to, page: 1));
  Future<void> clearFilters() => _apply(_query.cleared());
  Future<void> goToPage(int p) => _apply(_query.copyWith(page: p < 1 ? 1 : p));

  Future<void> _apply(ComplaintQuery q) {
    _query = q;
    return load();
  }

  /// Reloads the current view (and the counters) from the authoritative store.
  Future<void> load({bool silent = false}) async {
    if (_query.source == ComplaintSource.driver) {
      _rebuildDriverPage();
      _notify();
      return;
    }
    final int gen = ++_generation;
    if (!silent) {
      _loading = true;
      _error = null;
      _notify();
    }
    try {
      final ComplaintPage p = await _residentApi.fetchPage(_query);
      if (gen != _generation) return; // a newer request superseded this one
      // A page that emptied after a change (e.g. its last item was resolved) steps back.
      if (p.items.isEmpty && p.total > 0 && _query.page > p.pageCount) {
        _query = _query.copyWith(page: p.pageCount);
        await load(silent: silent);
        return;
      }
      _page = p;
      _residentCounts = p.counts;
      _residentCountsLoaded = true;
      _error = null;
    } catch (e) {
      if (gen != _generation) return;
      _error = ApiGuard.messageFor(e);
    } finally {
      if (gen == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  void _rebuildDriverPage() {
    final List<ComplaintRecord>? all = _driverIssues;
    _loading = all == null && _driverError == null;
    _page = all == null ? null : DriverIssuePager.page(all, _query);
    if (_page != null && _page!.page != _query.page) _query = _query.copyWith(page: _page!.page);
  }

  Future<ComplaintDetail> detail(ComplaintRecord c) async {
    if (c.source == ComplaintSource.driver) {
      final ComplaintRecord current =
          _driverIssues?.firstWhere((ComplaintRecord x) => x.id == c.id, orElse: () => c) ?? c;
      return ComplaintDetail(record: current, history: ComplaintHistoryEvent.derive(current));
    }
    return _residentApi.fetchDetail(c.id);
  }

  /// Re-sends the same status after a failed notification: the store finds the complaint
  /// already in [status] (no second transition) and re-checks/writes the one notification.
  Future<TransitionResult> retryNotification(ComplaintRecord c, ComplaintStatus status) async {
    final TransitionResult r = c.source == ComplaintSource.driver
        ? await _driverStore.updateStatus(c, status, '')
        : await _residentApi.updateStatus(c.id, status, '');
    await load(silent: true);
    return r;
  }

  bool _transitionInFlight = false;

  /// Applies a status change and waits for the store's confirmation before reporting success.
  /// The view and counters are then reloaded from the store (never patched locally).
  Future<TransitionResult> transition(ComplaintRecord c, ComplaintStatus to, String note) async {
    if (_transitionInFlight) throw ApiResponseException('Another update is still being saved. Please wait.');
    if (to == ComplaintStatus.resolved) {
      final String? invalid = ComplaintFlow.validateResolutionNote(note);
      if (invalid != null) throw ApiResponseException(invalid);
    }
    _transitionInFlight = true;
    try {
      final TransitionResult r = c.source == ComplaintSource.driver
          ? await _driverStore.updateStatus(c, to, note)
          : await _residentApi.updateStatus(c.id, to, note);
      await load(silent: true);
      return r;
    } finally {
      _transitionInFlight = false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _driverSub?.cancel();
    super.dispose();
  }
}
