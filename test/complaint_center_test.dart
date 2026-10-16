import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/api/api_client.dart';
import 'package:garbage_tracking_app/api/api_guard.dart';
import 'package:garbage_tracking_app/api/api_service.dart';
import 'package:garbage_tracking_app/models/user.dart';
import 'package:garbage_tracking_app/screens/complaints_screen.dart';
import 'package:garbage_tracking_app/services/complaint_center_service.dart';
import 'package:garbage_tracking_app/services/notification_service.dart';
import 'package:garbage_tracking_app/utils/complaint_flow.dart';

// ---------------------------------------------------------------- fakes

/// In-memory stand-in for complaint_center.php + update_complaint.php (same rules).
class FakeResidentApi implements ResidentComplaintApi {
  FakeResidentApi(int count) {
    for (int i = 1; i <= count; i++) {
      rows.add(<String, dynamic>{
        'id': i,
        'complaint_id': i,
        'resident_id': i.isOdd ? '5' : '6',
        'full_name': i.isOdd ? 'Res Five' : 'Res Six',
        'category': i % 3 == 0 ? 'Uncollected Garbage' : 'Spilled Waste',
        'description': 'complaint $i',
        'status': i % 5 == 0 ? 'resolved' : (i % 5 == 1 ? 'in_progress' : 'pending'),
        'admin_response': i % 5 == 0 ? 'Collected by the morning crew' : '',
        'purok': 'Purok 2',
        'created_at': '2026-09-${i.toString().padLeft(2, '0')} 08:00:00',
      });
    }
  }

  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
  final List<ComplaintQuery> queries = <ComplaintQuery>[];
  final List<(String, ComplaintStatus, String)> updates = <(String, ComplaintStatus, String)>[];
  Object? failWith;
  Completer<void>? gate;
  String notification = 'sent';

  @override
  Future<ComplaintPage> fetchPage(ComplaintQuery q) async {
    queries.add(q);
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    final List<ComplaintRecord> all = rows.map(ComplaintRecord.fromResident).toList();
    final List<ComplaintRecord> hits = all.where((ComplaintRecord c) {
      if (q.scope == ComplaintScope.resolved ? !c.isResolved : c.isResolved) return false;
      if (q.status != null && c.status != q.status) return false;
      if (q.search.isNotEmpty && !'${c.id} ${c.reporterName}'.toLowerCase().contains(q.search.toLowerCase())) return false;
      if (q.category != null && c.category != q.category) return false;
      return true;
    }).toList()
      ..sort((ComplaintRecord a, ComplaintRecord b) => int.parse(b.id).compareTo(int.parse(a.id)));
    return ComplaintPage(
      items: hits.skip((q.page - 1) * q.perPage).take(q.perPage).toList(),
      total: hits.length,
      page: q.page,
      perPage: q.perPage,
      counts: ComplaintCounts.of(all),
    );
  }

  @override
  Future<ComplaintDetail> fetchDetail(String id) async {
    final ComplaintRecord r = ComplaintRecord.fromResident(rows.firstWhere((Map<String, dynamic> m) => '${m['id']}' == id));
    return ComplaintDetail(record: r, history: ComplaintHistoryEvent.derive(r));
  }

  @override
  Future<TransitionResult> updateStatus(String id, ComplaintStatus to, String note) async {
    updates.add((id, to, note));
    final Map<String, dynamic> row = rows.firstWhere((Map<String, dynamic> m) => '${m['id']}' == id);
    final ComplaintStatus from = ComplaintFlow.statusOf(row['status']);
    if (from == to) return TransitionResult(changed: false, status: to, notification: 'already');
    if (!ComplaintFlow.canTransition(from, to)) throw ApiResponseException('This complaint is already resolved.');
    row['status'] = ComplaintFlow.apiValue(to);
    if (note.isNotEmpty) row['admin_response'] = note;
    return TransitionResult(changed: true, status: to, notification: notification);
  }
}

class FakeDriverStore implements DriverIssueStore {
  final StreamController<List<ComplaintRecord>> _ctrl = StreamController<List<ComplaintRecord>>.broadcast();
  List<ComplaintRecord> issues = <ComplaintRecord>[
    ComplaintRecord.fromDriverIssue('-NabcA1', <String, dynamic>{
      'driverId': 11, 'driverName': 'Juan', 'truckId': 'GT-007', 'issueType': 'Brakes', 'description': 'squeaking',
      'status': 'PENDING', 'createdAt': DateTime(2026, 9, 3).millisecondsSinceEpoch,
    }),
    ComplaintRecord.fromDriverIssue('-NabcB2', <String, dynamic>{
      'driverId': 12, 'driverName': 'Ana', 'truckId': 'GT-009', 'issueType': 'Tires', 'description': 'flat',
      'status': 'RESOLVED', 'adminResponse': 'Tire replaced at the depot', 'createdAt': DateTime(2026, 9, 1).millisecondsSinceEpoch,
      'resolvedAt': DateTime(2026, 9, 2).millisecondsSinceEpoch,
    }),
  ];
  final List<(String, ComplaintStatus)> updates = <(String, ComplaintStatus)>[];

  @override
  Stream<List<ComplaintRecord>> watch() {
    scheduleMicrotask(() => _ctrl.add(issues));
    return _ctrl.stream;
  }

  @override
  Future<TransitionResult> updateStatus(ComplaintRecord issue, ComplaintStatus to, String note) async {
    updates.add((issue.id, to));
    issues = issues
        .map((ComplaintRecord c) => c.id != issue.id
            ? c
            : ComplaintRecord.fromDriverIssue(c.id, <String, dynamic>{
                ...c.raw,
                'status': ComplaintFlow.driverIssueValue(to),
                if (note.isNotEmpty) 'adminResponse': note,
              }))
        .toList();
    _ctrl.add(issues);
    return TransitionResult(changed: true, status: to, notification: 'sent');
  }
}

/// Records each request and answers with a canned body (Hostinger/PHP stand-in).
class _Adapter implements HttpClientAdapter {
  _Adapter(this.body, {this.contentType = 'application/json', this.status = 200});

  String body;
  String contentType;
  int status;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(body, status, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[contentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dio(_Adapter adapter, Future<String?> Function() token) {
  final Dio dio = Dio(BaseOptions(baseUrl: 'https://indigo-bear-885857.hostingersite.com/backend/'));
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(AuthTokenInterceptor(tokenProvider: token));
  return dio;
}

Response<dynamic> _response(Object? data, {int status = 200}) =>
    Response<dynamic>(requestOptions: RequestOptions(path: 'x.php'), data: data, statusCode: status);

void main() {
  // ---------------------------------------------------------------- lifecycle rules
  group('Complaint lifecycle rules', () {
    test('stored spellings map to the three states (same as the PHP API)', () {
      expect(ComplaintFlow.statusOf('pending'), ComplaintStatus.pending);
      expect(ComplaintFlow.statusOf(null), ComplaintStatus.pending);
      expect(ComplaintFlow.statusOf('in_progress'), ComplaintStatus.inProgress);
      expect(ComplaintFlow.statusOf('In Progress'), ComplaintStatus.inProgress);
      expect(ComplaintFlow.statusOf('IN_PROGRESS'), ComplaintStatus.inProgress);
      expect(ComplaintFlow.statusOf('under review'), ComplaintStatus.inProgress);
      expect(ComplaintFlow.statusOf('RESOLVED'), ComplaintStatus.resolved);
      expect(ComplaintFlow.statusOf('completed'), ComplaintStatus.resolved);
    });

    test('only Pending -> In Progress -> Resolved (and Pending -> Resolved) are allowed', () {
      expect(ComplaintFlow.canTransition(ComplaintStatus.pending, ComplaintStatus.inProgress), isTrue);
      expect(ComplaintFlow.canTransition(ComplaintStatus.inProgress, ComplaintStatus.resolved), isTrue);
      expect(ComplaintFlow.canTransition(ComplaintStatus.pending, ComplaintStatus.resolved), isTrue);
      expect(ComplaintFlow.canTransition(ComplaintStatus.resolved, ComplaintStatus.inProgress), isFalse, reason: 'no reopening');
      expect(ComplaintFlow.canTransition(ComplaintStatus.inProgress, ComplaintStatus.pending), isFalse);
      expect(ComplaintFlow.canTransition(ComplaintStatus.inProgress, ComplaintStatus.inProgress), isFalse);
    });

    test('a resolution note is required and must be meaningful', () {
      expect(ComplaintFlow.validateResolutionNote(''), isNotNull);
      expect(ComplaintFlow.validateResolutionNote('   ok    '), isNotNull);
      expect(ComplaintFlow.validateResolutionNote('Collected on Monday.'), isNull);
      expect(ComplaintFlow.validateResolutionNote('x' * 2001), isNotNull);
    });

    test('complaint numbers are shown as #043', () {
      expect(ComplaintFlow.displayId(43), '#043');
      expect(ComplaintFlow.displayId('1250'), '#1250');
    });

    test('notification keys match the server (one record per complaint and state)', () {
      expect(ComplaintFlow.resolvedNotificationKey(7), 'complaint_resolved_7');
      expect(ComplaintFlow.inProgressNotificationKey(7), 'complaint_in_progress_7');
      expect(ComplaintFlow.driverIssueNotificationKey('-Nx', ComplaintStatus.resolved), 'truck_issue_-Nx_resolved');
    });
  });

  // ---------------------------------------------------------------- API reply validation
  group('API replies (Web HTML fallback, invalid JSON, server errors)', () {
    test('Hostinger serving index.html (HTTP 200) for a missing endpoint is an error, not data', () {
      expect(
        () => ApiGuard.parse('<!DOCTYPE html><html><head><title>Garbage Tracker</title></head></html>', statusCode: 200),
        throwsA(isA<ApiResponseException>().having((ApiResponseException e) => e.htmlFallback, 'htmlFallback', isTrue)),
      );
    });

    test('invalid JSON is an error with a readable message', () {
      expect(() => ApiGuard.parse('Warning: Undefined index {"success":true}'),
          throwsA(isA<ApiResponseException>().having((ApiResponseException e) => e.message, 'message', ApiGuard.invalidJsonMessage)));
      expect(() => ApiGuard.parse(<int>[1, 2]), throwsA(isA<ApiResponseException>()));
    });

    test('JSON delivered as text is decoded', () {
      expect(ApiGuard.parse('{"success":true,"complaint_id":9}')['complaint_id'], 9);
    });

    test('non-2xx replies surface the server message', () {
      expect(() => ApiGuard.parse(<String, dynamic>{'success': false, 'message': 'Please log in again.'}, statusCode: 401),
          throwsA(isA<ApiResponseException>().having((ApiResponseException e) => e.message, 'message', 'Please log in again.')));
    });

    test('auth failures are explained without exception dumps', () {
      DioException bad(int code, Object? data) => DioException(
            requestOptions: RequestOptions(path: 'update_complaint.php'),
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(requestOptions: RequestOptions(path: 'x'), statusCode: code, data: data),
          );
      expect(ApiGuard.messageFor(bad(401, null)), contains('sign in again'));
      expect(ApiGuard.messageFor(bad(403, <String, dynamic>{'message': 'You are not allowed to perform this action.'})),
          'You are not allowed to perform this action.');
      expect(ApiGuard.messageFor(bad(500, '<html>')), isNot(contains('DioException')));
    });

    test('submission result: success returns the id; refusals and HTML never look like success', () {
      expect(ComplaintFlow.submissionResult(_response(<String, dynamic>{'success': true, 'complaint_id': 12})), 12);
      expect(() => ComplaintFlow.submissionResult(_response(<String, dynamic>{'success': false, 'message': 'Missing data'})),
          throwsA(isA<ApiResponseException>().having((ApiResponseException e) => e.message, 'message', 'Missing data')));
      expect(() => ComplaintFlow.submissionResult(_response('<html><body>index</body></html>')),
          throwsA(isA<ApiResponseException>().having((ApiResponseException e) => e.htmlFallback, 'htmlFallback', isTrue)));
      expect(() => ComplaintFlow.submissionResult(_response('')), throwsA(isA<ApiResponseException>()));
    });
  });

  // ---------------------------------------------------------------- submission request (Android and Web share it)
  group('Resident complaint submission request', () {
    test('posts the same form fields to file_complaint.php with the access token', () async {
      final _Adapter adapter = _Adapter('{"success":true,"message":"Complaint filed successfully","complaint_id":31}');
      final ApiService api = ApiService(dio: _dio(adapter, () async => 'token-A'));
      final Response<dynamic> r = await api.fileComplaint('5', 'Uncollected Garbage', 'pa collect', purok: 'Purok 2', location: 'Purok 2');
      expect(ComplaintFlow.submissionResult(r), 31);
      final RequestOptions sent = adapter.requests.single;
      expect(sent.path, 'file_complaint.php');
      expect(sent.method, 'POST');
      expect(sent.headers['X-GT-Token'], 'token-A');
      final FormData form = sent.data as FormData;
      expect(Map<String, String>.fromEntries(form.fields), <String, String>{
        'resident_id': '5',
        'category': 'Uncollected Garbage',
        'description': 'pa collect',
        'purok': 'Purok 2',
        'location': 'Purok 2',
      });
    });

    test('after an automatic access-token renewal the next submission carries the new token', () async {
      final _Adapter adapter = _Adapter('{"success":true,"complaint_id":1}');
      final List<String> tokens = <String>['expired-soon', 'renewed'];
      final ApiService api = ApiService(dio: _dio(adapter, () async => tokens.removeAt(0)));
      await api.fileComplaint('5', 'Other', 'first');
      await api.fileComplaint('5', 'Other', 'second');
      expect(adapter.requests.map((RequestOptions o) => o.headers['X-GT-Token']), <String>['expired-soon', 'renewed']);
    });

    test('a session without a token still submits (legacy server, older sessions)', () async {
      final _Adapter adapter = _Adapter('{"success":true,"complaint_id":2}');
      final ApiService api = ApiService(dio: _dio(adapter, () async => null));
      await api.fileComplaint('5', 'Other', 'no token');
      expect(adapter.requests.single.headers.containsKey('X-GT-Token'), isFalse);
    });

    test('a missing endpoint served as the Web index page is reported, not shown as success', () async {
      final _Adapter adapter = _Adapter('<!DOCTYPE html><html><body><script src="main.dart.js"></script></body></html>',
          contentType: 'text/html');
      final ApiService api = ApiService(dio: _dio(adapter, () async => 'token-A'));
      final Response<dynamic> r = await api.fileComplaint('5', 'Other', 'x');
      expect(() => ComplaintFlow.submissionResult(r), throwsA(isA<ApiResponseException>()));
    });

    test('a server refusal keeps its message', () async {
      final _Adapter adapter = _Adapter('{"success":false,"message":"Resident account not found. Please log in again."}');
      final ApiService api = ApiService(dio: _dio(adapter, () async => 'token-A'));
      final Response<dynamic> r = await api.fileComplaint('5', 'Other', 'x');
      expect(() => ComplaintFlow.submissionResult(r),
          throwsA(isA<ApiResponseException>().having((ApiResponseException e) => e.message, 'message', contains('Resident account not found'))));
    });
  });

  // ---------------------------------------------------------------- Complaint Center requests
  group('Complaint Center requests', () {
    test('filters are sent to the server (not applied to the loaded page)', () {
      final Map<String, dynamic> p = ComplaintQuery(
        scope: ComplaintScope.active,
        status: ComplaintStatus.inProgress,
        search: ' #043 ',
        category: 'Spilled Waste',
        location: 'Central (Purok 1)',
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 30),
        page: 3,
      ).toParams();
      expect(p, <String, dynamic>{
        'action': 'list',
        'scope': 'active',
        'status': 'in_progress',
        'q': '#043',
        'category': 'Spilled Waste',
        'location': 'central|purok 1',
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
        'page': 3,
        'per_page': 15,
      });
    });

    test('the Archive never sends a Pending/In Progress status filter', () {
      final Map<String, dynamic> p = const ComplaintQuery(scope: ComplaintScope.resolved, status: ComplaintStatus.pending).toParams();
      expect(p['scope'], 'resolved');
      expect(p.containsKey('status'), isFalse);
    });

    test('list request goes to complaint_center.php and parses page + real counts', () async {
      final _Adapter adapter = _Adapter('{"success":true,"data":[{"id":43,"complaint_id":43,"resident_id":"5","full_name":"Res Five",'
          '"category":"Spilled Waste","description":"x","status":"in_progress","created_at":"2026-09-02 08:00:00","purok":"Purok 2"}],'
          '"total":31,"page":2,"per_page":15,"has_more":true,"counts":{"pending":12,"in_progress":7,"resolved":40}}');
      final HttpResidentComplaintApi api = HttpResidentComplaintApi(ApiService(dio: _dio(adapter, () async => 'adm')));
      final ComplaintPage page = await api.fetchPage(const ComplaintQuery(page: 2));
      expect(adapter.requests.single.path, 'complaint_center.php');
      expect(adapter.requests.single.queryParameters['scope'], 'active');
      expect(page.items.single.displayId, '#043');
      expect(page.items.single.status, ComplaintStatus.inProgress);
      expect(page.total, 31);
      expect(page.pageCount, 3);
      expect(page.firstIndex, 16);
      expect(page.counts.resolved, 40);
    });

    test('status change: success is reported only from the server reply', () async {
      final _Adapter adapter = _Adapter('{"success":true,"changed":true,"status":"resolved","previous_status":"in_progress","notification":"sent"}');
      final HttpResidentComplaintApi api = HttpResidentComplaintApi(ApiService(dio: _dio(adapter, () async => 'adm')));
      final TransitionResult r = await api.updateStatus('43', ComplaintStatus.resolved, 'Collected on Monday.');
      expect(r.changed, isTrue);
      expect(r.notificationFailed, isFalse);
      final FormData form = adapter.requests.single.data as FormData;
      expect(Map<String, String>.fromEntries(form.fields),
          <String, String>{'complaint_id': '43', 'status': 'resolved', 'admin_response': 'Collected on Monday.'});

      adapter.body = '{"success":false,"code":"NOTE_REQUIRED","message":"Please enter a resolution note."}';
      await expectLater(api.updateStatus('43', ComplaintStatus.resolved, 'x'),
          throwsA(isA<ApiResponseException>().having((ApiResponseException e) => e.message, 'message', 'Please enter a resolution note.')));

      adapter.body = '{"success":true,"changed":true,"status":"resolved","notification":"failed"}';
      expect((await api.updateStatus('44', ComplaintStatus.resolved, 'Collected on Monday.')).notificationFailed, isTrue);

      adapter.body = '<html></html>';
      adapter.contentType = 'text/html';
      await expectLater(api.updateStatus('45', ComplaintStatus.inProgress, ''), throwsA(isA<ApiResponseException>()));
    });
  });

  // ---------------------------------------------------------------- driver reports
  group('Driver reports (Firebase truck_issues): archive, filters, pages', () {
    List<ComplaintRecord> issues(int n) => <ComplaintRecord>[
          for (int i = 1; i <= n; i++)
            ComplaintRecord.fromDriverIssue('k$i', <String, dynamic>{
              'driverId': i, 'driverName': i.isOdd ? 'Juan' : 'Ana', 'truckId': 'GT-00$i', 'issueType': i.isOdd ? 'Brakes' : 'Tires',
              'status': i % 4 == 0 ? 'RESOLVED' : (i % 4 == 1 ? 'IN_PROGRESS' : 'PENDING'),
              'createdAt': DateTime(2026, 9, i).millisecondsSinceEpoch,
              if (i % 4 == 0) 'resolvedAt': DateTime(2026, 10, 30 - i).millisecondsSinceEpoch,
            }),
        ];

    test('Active holds pending + in progress, newest first; the Archive only resolved', () {
      final ComplaintPage active = DriverIssuePager.page(issues(20), const ComplaintQuery(source: ComplaintSource.driver));
      expect(active.total, 15);
      expect(active.items.first.id, 'k19');
      expect(active.items.every((ComplaintRecord c) => !c.isResolved), isTrue);
      final ComplaintPage archive =
          DriverIssuePager.page(issues(20), const ComplaintQuery(source: ComplaintSource.driver, scope: ComplaintScope.resolved));
      expect(archive.items.map((ComplaintRecord c) => c.id), <String>['k4', 'k8', 'k12', 'k16', 'k20'],
          reason: 'newest resolution first');
    });

    test('pagination is deterministic and counts cover everything', () {
      final List<ComplaintRecord> all = issues(40);
      final ComplaintPage p1 = DriverIssuePager.page(all, const ComplaintQuery(source: ComplaintSource.driver));
      final ComplaintPage p2 = DriverIssuePager.page(all, const ComplaintQuery(source: ComplaintSource.driver, page: 2));
      expect(p1.items.length, 15);
      expect(p2.items.length, 15);
      expect(p1.items.toSet().intersection(p2.items.toSet()), isEmpty);
      expect(p1.counts.resolved + p1.counts.pending + p1.counts.inProgress, 40);
      expect(p1.counts.resolved, 10);
    });

    test('search, category, status and date filters', () {
      final List<ComplaintRecord> all = issues(20);
      ComplaintPage q(ComplaintQuery query) => DriverIssuePager.page(all, query);
      expect(q(const ComplaintQuery(source: ComplaintSource.driver, search: 'ana')).items.every((ComplaintRecord c) => c.reporterName == 'Ana'), isTrue);
      expect(q(const ComplaintQuery(source: ComplaintSource.driver, search: 'GT-003')).items.single.id, 'k3');
      expect(q(const ComplaintQuery(source: ComplaintSource.driver, category: 'Tires')).items.every((ComplaintRecord c) => c.category == 'Tires'), isTrue);
      expect(q(const ComplaintQuery(source: ComplaintSource.driver, status: ComplaintStatus.inProgress)).total, 5);
      expect(q(ComplaintQuery(source: ComplaintSource.driver, from: DateTime(2026, 9, 2), to: DateTime(2026, 9, 3))).items.map((ComplaintRecord c) => c.id),
          <String>['k3', 'k2']);
    });

    test('the driver notification is private to the reporting driver', () {
      final Map<String, Object?> n = ComplaintFlow.driverIssueNotification(
          issueId: '-Nabc', driverId: 11, issueType: 'Brakes', status: ComplaintStatus.resolved, timestamp: 1);
      expect(n['targetUserId'], '11');
      expect(n.containsKey('targetRole'), isFalse, reason: 'targetRole "driver" would reach every driver');
      expect(n.containsKey('truck_id'), isFalse, reason: 'truck_id would reach every driver of that truck');
      expect(n['type'], 'ISSUE_UPDATE');
      expect(n['title'], 'Report Resolved');
    });
  });

  // ---------------------------------------------------------------- notification recipients
  group('Complaint status notifications reach only the complainant', () {
    final Map<String, dynamic> inProgress = <String, dynamic>{
      'type': 'COMPLAINT_IN_PROGRESS', 'title': 'Complaint In Progress', 'resident_id': '5', 'targetRole': 'resident', 'complaint_id': 43,
    };
    final Map<String, dynamic> resolved = <String, dynamic>{...inProgress, 'type': 'COMPLAINT_RESOLVED'};
    final Map<String, dynamic> driverUpdate = <String, dynamic>{'type': 'ISSUE_UPDATE', 'targetUserId': '5', 'relatedId': '-Nabc'};

    test('the complaining resident gets both updates', () {
      final UserData me = UserData(userId: 5, role: 'resident');
      expect(NotificationService.isRelevantFor(inProgress, me), isTrue);
      expect(NotificationService.isRelevantFor(resolved, me), isTrue);
    });

    test('another resident gets neither', () {
      final UserData other = UserData(userId: 6, role: 'resident');
      expect(NotificationService.isRelevantFor(inProgress, other), isFalse);
      expect(NotificationService.isRelevantFor(resolved, other), isFalse);
    });

    test('a driver or admin with the same numeric id never sees a resident complaint update', () {
      expect(NotificationService.isRelevantFor(inProgress, UserData(userId: 5, role: 'driver')), isFalse);
      expect(NotificationService.isRelevantFor(resolved, UserData(userId: 5, role: 'driver')), isFalse);
      expect(NotificationService.isRelevantFor(inProgress, UserData(userId: 5, role: 'admin')), isFalse);
    });

    test('a driver report update goes to that driver only, never to a resident with the same id', () {
      expect(NotificationService.isRelevantFor(driverUpdate, UserData(userId: 5, role: 'driver')), isTrue);
      expect(NotificationService.isRelevantFor(driverUpdate, UserData(userId: 6, role: 'driver')), isFalse);
      expect(NotificationService.isRelevantFor(driverUpdate, UserData(userId: 5, role: 'resident')), isFalse);
    });

    test('tapping a notification knows which complaint to open', () {
      expect(ComplaintFlow.notificationComplaintId(inProgress), '43');
      expect(ComplaintFlow.notificationComplaintId(<String, dynamic>{'relatedId': 17}), '17');
      expect(ComplaintFlow.notificationComplaintId(<String, dynamic>{}), isNull);
    });
  });

  // ---------------------------------------------------------------- controller
  group('Complaint Center controller', () {
    test('loads Active with real counts; resolving moves the complaint to the Archive after the server confirms', () async {
      final FakeResidentApi api = FakeResidentApi(23);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore());
      c.start();
      await pumpEventQueue();
      expect(c.page!.total, 19);
      expect(c.items.length, 15);
      expect(c.counts.resolved, 4);
      expect(c.items.first.id, '23');

      final ComplaintRecord target = c.items.firstWhere((ComplaintRecord r) => r.id == '22');
      final TransitionResult r = await c.transition(target, ComplaintStatus.resolved, 'Collected and cleaned the area.');
      expect(r.changed, isTrue);
      expect(api.updates.single, ('22', ComplaintStatus.resolved, 'Collected and cleaned the area.'));
      expect(c.items.any((ComplaintRecord x) => x.id == '22'), isFalse, reason: 'reloaded from the store');
      expect(c.counts.resolved, 5);
      await c.setScope(ComplaintScope.resolved);
      expect(c.items.any((ComplaintRecord x) => x.id == '22'), isTrue);
      c.dispose();
    });

    test('resolving without a note never reaches the server', () async {
      final FakeResidentApi api = FakeResidentApi(5);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore())..start();
      await pumpEventQueue();
      await expectLater(c.transition(c.items.first, ComplaintStatus.resolved, '  '), throwsA(isA<ApiResponseException>()));
      expect(api.updates, isEmpty);
      c.dispose();
    });

    test('a double click sends one update', () async {
      final FakeResidentApi api = FakeResidentApi(5);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore())..start();
      await pumpEventQueue();
      final ComplaintRecord first = c.items.firstWhere((ComplaintRecord r) => r.status == ComplaintStatus.pending);
      api.gate = Completer<void>(); // the reload after the update waits
      final Future<TransitionResult> a = c.transition(first, ComplaintStatus.inProgress, '');
      await expectLater(c.transition(first, ComplaintStatus.inProgress, ''), throwsA(isA<ApiResponseException>()));
      api.gate!.complete();
      api.gate = null;
      await a;
      expect(api.updates.length, 1);
      c.dispose();
    });

    test('filters and pages are server requests; a filter change starts at page 1', () async {
      final FakeResidentApi api = FakeResidentApi(40);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore())..start();
      await pumpEventQueue();
      await c.goToPage(2);
      expect(api.queries.last.page, 2);
      expect(c.page!.firstIndex, 16);
      await c.setCategory('Spilled Waste');
      expect(api.queries.last.page, 1);
      expect(api.queries.last.category, 'Spilled Waste');
      await c.setSearch('Six');
      expect(c.items.every((ComplaintRecord r) => r.reporterName == 'Res Six'), isTrue);
      await c.clearFilters();
      expect(api.queries.last.hasFilters, isFalse);
      c.dispose();
    });

    test('an older, slower reply never overwrites a newer one', () async {
      final FakeResidentApi api = FakeResidentApi(30);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore())..start();
      await pumpEventQueue();
      api.gate = Completer<void>();
      final Future<void> slow = c.setScope(ComplaintScope.resolved);
      api.gate!.complete();
      api.gate = null;
      await c.setScope(ComplaintScope.active);
      await slow;
      expect(c.query.scope, ComplaintScope.active);
      expect(c.items.every((ComplaintRecord r) => !r.isResolved), isTrue);
      c.dispose();
    });

    test('server errors are shown and can be retried', () async {
      final FakeResidentApi api = FakeResidentApi(5)..failWith = ApiResponseException(ApiGuard.htmlFallbackMessage, htmlFallback: true);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore())..start();
      await pumpEventQueue();
      expect(c.error, ApiGuard.htmlFallbackMessage);
      api.failWith = null;
      await c.load();
      expect(c.error, isNull);
      expect(c.items, isNotEmpty);
      c.dispose();
    });

    test('Drivers source uses the Firebase reports with their own counts', () async {
      final FakeDriverStore store = FakeDriverStore();
      final ComplaintCenterController c = ComplaintCenterController(residentApi: FakeResidentApi(5), driverStore: store)..start();
      await pumpEventQueue();
      await c.setSource(ComplaintSource.driver);
      expect(c.items.single.reporterName, 'Juan');
      expect(c.counts.resolved, 1);
      await c.transition(c.items.single, ComplaintStatus.resolved, 'Brake pads replaced.');
      await pumpEventQueue();
      expect(store.updates.single, ('-NabcA1', ComplaintStatus.resolved));
      expect(c.items, isEmpty);
      expect(c.counts.resolved, 2);
      c.dispose();
    });
  });

  // ---------------------------------------------------------------- screen
  group('Complaint Center screen (Android narrow and Web wide)', () {
    Future<(ComplaintCenterController, FakeResidentApi, FakeDriverStore)> pumpCenter(WidgetTester tester, Size size, {int count = 23}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final FakeResidentApi api = FakeResidentApi(count);
      final FakeDriverStore store = FakeDriverStore();
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: store);
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: ComplaintsScreen(controller: c, listenForNewComplaints: false)));
      await tester.pumpAndSettle();
      return (c, api, store);
    }

    for (final (String name, Size size) in <(String, Size)>[('narrow Android', const Size(360, 780)), ('wide Web', const Size(1366, 900))]) {
      testWidgets('$name: new names, counters, tabs and paginated cards without overflow', (WidgetTester tester) async {
        await pumpCenter(tester, size);
        expect(find.text('Complaint Center'), findsOneWidget);
        expect(find.text('Manage, track, and resolve resident and driver complaints'), findsOneWidget);
        expect(find.text('Resolve Radar'), findsNothing);
        expect(find.byKey(const ValueKey<String>('counter-pending')), findsOneWidget);
        expect(find.textContaining('RESOLVED ARCHIVE'), findsOneWidget);
        expect(find.text('Showing 1–15 of 19 active resident complaints'), findsOneWidget);
        expect(find.text('View Details'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Resolved Archive shows read-only resolutions', (WidgetTester tester) async {
      await pumpCenter(tester, const Size(1366, 900));
      await tester.tap(find.byKey(const ValueKey<String>('scope-resolved')));
      await tester.pumpAndSettle();
      expect(find.text('Showing 1–4 of 4 resolved resident complaints'), findsOneWidget);
      expect(find.text('View Resolution'), findsNWidgets(4));
      await tester.tap(find.byKey(const ValueKey<String>('complaint-card-resident-20')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('resolution-panel')), findsOneWidget);
      expect(find.text('Collected by the morning crew'), findsWidgets);
      expect(find.byKey(const ValueKey<String>('action-resolve')), findsNothing);
      expect(find.byKey(const ValueKey<String>('action-in-progress')), findsNothing);
    });

    testWidgets('narrow: resolve requires a note, waits for the server, then leaves Active', (WidgetTester tester) async {
      final (ComplaintCenterController c, FakeResidentApi api, _) = await pumpCenter(tester, const Size(360, 780));
      await tester.tap(find.byKey(const ValueKey<String>('complaint-card-resident-23')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('action-resolve')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('status-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('status-error')), findsOneWidget);
      expect(api.updates, isEmpty);

      await tester.enterText(find.byKey(const ValueKey<String>('status-note')), 'Collected by truck GT-007 this morning.');
      await tester.tap(find.byKey(const ValueKey<String>('status-confirm')));
      await tester.pumpAndSettle();
      expect(api.updates.single.$1, '23');
      expect(find.textContaining('#023 resolved and moved to the Resolved Archive'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('complaint-card-resident-23')), findsNothing);
      expect(c.counts.resolved, 5);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('Mark In Progress from a pending complaint; a failed notification is offered for retry', (WidgetTester tester) async {
      final (_, FakeResidentApi api, _) = await pumpCenter(tester, const Size(1366, 900));
      api.notification = 'failed';
      await tester.tap(find.byKey(const ValueKey<String>('complaint-card-resident-22')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('action-in-progress')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('status-confirm')));
      await tester.pumpAndSettle();
      expect(api.updates.single.$2, ComplaintStatus.inProgress);
      expect(find.text('Notification not delivered'), findsOneWidget);
      api.notification = 'sent';
      await tester.tap(find.text('Retry notification'));
      await tester.pumpAndSettle();
      expect(api.updates.length, 2, reason: 'the retry re-sends the same status');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('pagination and the Drivers tab', (WidgetTester tester) async {
      final (_, FakeResidentApi api, _) = await pumpCenter(tester, const Size(1366, 900));
      expect(find.text('Page 1 of 2'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey<String>('page-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('page-next')));
      await tester.pumpAndSettle();
      expect(api.queries.last.page, 2);
      expect(find.text('Showing 16–19 of 19 active resident complaints'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('source-driver')));
      await tester.pumpAndSettle();
      expect(find.text('Showing 1–1 of 1 active driver reports'), findsOneWidget);
      expect(find.textContaining('Juan'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('filter-location')), findsNothing, reason: 'driver reports have no purok');
    });

    testWidgets('a server error shows Retry instead of an empty list', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final FakeResidentApi api = FakeResidentApi(5)..failWith = ApiResponseException(ApiGuard.htmlFallbackMessage, htmlFallback: true);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore());
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: ComplaintsScreen(controller: c, listenForNewComplaints: false)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('complaint-error')), findsOneWidget);
      expect(find.textContaining('web page instead of data'), findsOneWidget);
      api.failWith = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('complaint-error')), findsNothing);
      expect(find.text('View Details'), findsWidgets);
    });

    testWidgets('failed first load: no endless "Loading…", counts unknown (–), not zero', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1366, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // What a browser reports when the endpoint is missing and the fallback page has no CORS header.
      final FakeResidentApi api = FakeResidentApi(7)
        ..failWith = DioException(requestOptions: RequestOptions(path: 'complaint_center.php'), type: DioExceptionType.connectionError);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore());
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: ComplaintsScreen(controller: c, listenForNewComplaints: false)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not reach the server'), findsOneWidget);
      expect(find.textContaining('Loading active resident complaints'), findsNothing);
      expect(find.text('Could not load active resident complaints'), findsOneWidget);
      expect(c.countsKnown, isFalse);
      for (final String k in <String>['pending', 'in-progress', 'resolved']) {
        expect(find.descendant(of: find.byKey(ValueKey<String>('counter-$k')), matching: find.text('–')), findsOneWidget);
        expect(find.descendant(of: find.byKey(ValueKey<String>('counter-$k')), matching: find.text('0')), findsNothing);
      }
      // Resolved tab after the failure: same honest state.
      await tester.tap(find.byKey(const ValueKey<String>('scope-resolved')));
      await tester.pumpAndSettle();
      expect(find.text('Could not load resolved resident complaints'), findsOneWidget);
      expect(find.textContaining('Loading resolved resident complaints'), findsNothing);
    });

    testWidgets('a later failed reload keeps the last real counts and shows the error', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1366, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final FakeResidentApi api = FakeResidentApi(10);
      final ComplaintCenterController c = ComplaintCenterController(residentApi: api, driverStore: FakeDriverStore());
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: ComplaintsScreen(controller: c, listenForNewComplaints: false)));
      await tester.pumpAndSettle();
      final int pending = c.counts.pending;
      expect(c.countsKnown, isTrue);
      api.failWith = ApiResponseException(ApiGuard.htmlFallbackMessage, htmlFallback: true);
      await c.load();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('complaint-error')), findsOneWidget);
      expect(c.counts.pending, pending);
      expect(find.descendant(of: find.byKey(const ValueKey<String>('counter-pending')), matching: find.text('$pending')), findsOneWidget);
    });
  });
}
