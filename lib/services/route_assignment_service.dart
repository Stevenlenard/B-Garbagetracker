import 'dart:convert';

import 'package:dio/dio.dart';

import '../api/api_client.dart';
import '../models/route_assignment.dart';

/// Why an assignment request did not succeed. The UI shows [message]; nothing is retried
/// without a token and nothing falls back to token-less access.
enum AssignmentFailure { none, notConfigured, notSetUp, unauthorized, forbidden, conflict, invalid, network }

class AssignmentResult<T> {
  const AssignmentResult.ok(this.value)
      : failure = AssignmentFailure.none,
        message = null;
  const AssignmentResult.fail(this.failure, this.message) : value = null;

  final T? value;
  final AssignmentFailure failure;
  final String? message;
  bool get isOk => failure == AssignmentFailure.none;
}

class AssignmentList {
  const AssignmentList({required this.items, required this.summary, required this.today});
  final List<RouteAssignment> items;
  final AssignmentSummary summary;
  final String today;
}

class RouteAssignmentService {
  RouteAssignmentService({Dio? dio}) : _dio = dio ?? ApiClient.instance;
  final Dio _dio;

  /// Maps an HTTP status + body to a failure (pure; unit tested).
  static AssignmentResult<Map<dynamic, dynamic>> interpret(int? status, Object? body) {
    if (body is String) {
      final String t = body.trimLeft();
      // An endpoint that is not uploaded yet: Hostinger answers with the web app's index.html
      // (HTTP 200) or an HTML 404 page. That is "not set up", not a broken response.
      // 401/403/503 keep their meaning (handled below) whatever the body.
      if (t.startsWith('<') && status != 401 && status != 403 && status != 503) {
        return const AssignmentResult.fail(AssignmentFailure.notSetUp, 'Route assignments are not available on this server yet.');
      }
      // JSON sent with a non-JSON content type.
      try {
        body = jsonDecode(t);
      } catch (_) {}
    }
    final Map<dynamic, dynamic> data = body is Map ? body : const <dynamic, dynamic>{};
    final String? serverMsg = data['message']?.toString();
    switch (status) {
      case 401:
        return const AssignmentResult.fail(AssignmentFailure.unauthorized, 'Your session has expired. Please log in again.');
      case 403:
        return const AssignmentResult.fail(AssignmentFailure.forbidden, 'You are not allowed to do this.');
      case 503:
        return const AssignmentResult.fail(AssignmentFailure.notConfigured,
            'Route assignments are not available yet: server authorization has not been configured.');
      case 404:
        return AssignmentResult.fail(AssignmentFailure.invalid, serverMsg ?? 'Assignment not found.');
      case 409:
        return AssignmentResult.fail(AssignmentFailure.conflict, serverMsg ?? 'This conflicts with another assignment.');
    }
    if (body is! Map) {
      return const AssignmentResult.fail(AssignmentFailure.network, 'Unexpected response from the server.');
    }
    if (data['available'] == false) {
      return AssignmentResult.fail(AssignmentFailure.notSetUp, serverMsg ?? 'Route assignments are not set up on this server yet.');
    }
    if (data['success'] != true) {
      return AssignmentResult.fail(AssignmentFailure.invalid, serverMsg ?? 'The request was not accepted.');
    }
    return AssignmentResult.ok(data);
  }

  Future<AssignmentResult<Map<dynamic, dynamic>>> _post(String endpoint, Map<String, dynamic> body) async {
    try {
      final Response<dynamic> r = await _dio.post(endpoint, data: body);
      return interpret(r.statusCode, r.data);
    } on DioException catch (e) {
      if (e.response != null) return interpret(e.response!.statusCode, e.response!.data);
      return const AssignmentResult.fail(AssignmentFailure.network, 'Could not reach the server. Check the connection and try again.');
    }
  }

  /// Admin: all assignments in the range (optional filters). Driver: the server returns only
  /// the signed-in driver's own assignments, whatever is requested.
  Future<AssignmentResult<AssignmentList>> list({required String startDate, required String endDate, int? driverId}) async {
    final AssignmentResult<Map<dynamic, dynamic>> r = await _post('get_assignments.php', <String, dynamic>{
      'start_date': startDate,
      'end_date': endDate,
      if (driverId != null) 'driver_id': driverId,
    });
    if (!r.isOk) return AssignmentResult.fail(r.failure, r.message);
    final Map<dynamic, dynamic> d = r.value!;
    return AssignmentResult.ok(AssignmentList(
      items: <RouteAssignment>[
        for (final Object? x in (d['data'] is List ? d['data'] as List : const <Object?>[]))
          if (x is Map) RouteAssignment.fromJson(x),
      ],
      summary: AssignmentSummary.fromJson(d['summary'] is Map ? d['summary'] as Map : null),
      today: (d['today'] ?? '').toString(),
    ));
  }

  Future<AssignmentResult<RouteAssignment>> save({
    int? assignmentId,
    required String date,
    required int driverId,
    required String truckId,
    required List<AssignmentArea> areas,
    String? notes,
  }) async {
    final AssignmentResult<Map<dynamic, dynamic>> r = await _post('save_assignment.php', <String, dynamic>{
      if (assignmentId != null) 'assignment_id': assignmentId,
      'assignment_date': date,
      'driver_id': driverId,
      'truck_id': truckId,
      'areas': areas.map((AssignmentArea a) => a.toJson()).toList(),
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    });
    if (!r.isOk) return AssignmentResult.fail(r.failure, r.message);
    final Object? d = r.value!['data'];
    return d is Map ? AssignmentResult.ok(RouteAssignment.fromJson(d)) : const AssignmentResult.fail(AssignmentFailure.invalid, 'Saved, but the reply was incomplete.');
  }

  Future<AssignmentResult<RouteAssignment>> cancel(int assignmentId) async {
    final AssignmentResult<Map<dynamic, dynamic>> r = await _post('cancel_assignment.php', <String, dynamic>{'assignment_id': assignmentId});
    if (!r.isOk) return AssignmentResult.fail(r.failure, r.message);
    final Object? d = r.value!['data'];
    return d is Map ? AssignmentResult.ok(RouteAssignment.fromJson(d)) : const AssignmentResult.fail(AssignmentFailure.invalid, 'Cancelled, but the reply was incomplete.');
  }

  /// Driver: link the running trip (identity comes from the token on the server). Returns the
  /// server reason ('linked', 'no_assignment', 'truck_mismatch', ...). Never throws.
  Future<AssignmentResult<String>> linkTrip({required String tripId, required String truckId, required int tripStartedAtMs}) async {
    final AssignmentResult<Map<dynamic, dynamic>> r = await _post('link_assignment_trip.php', <String, dynamic>{
      'trip_id': tripId,
      'truck_id': truckId,
      'trip_started_at_ms': tripStartedAtMs,
    });
    if (!r.isOk) return AssignmentResult.fail(r.failure, r.message);
    return AssignmentResult.ok((r.value!['reason'] ?? (r.value!['linked'] == true ? 'linked' : 'not_linked')).toString());
  }
}
