import 'dart:convert';

import 'package:dio/dio.dart';

/// A backend reply that cannot be trusted as an API answer (HTML page, invalid JSON, ...).
class ApiResponseException implements Exception {
  ApiResponseException(this.message, {this.statusCode, this.htmlFallback = false});

  final String message;
  final int? statusCode;

  /// The server answered with a web page, e.g. Hostinger serving the Flutter index.html
  /// (HTTP 200) for a PHP endpoint that has not been uploaded.
  final bool htmlFallback;

  @override
  String toString() => message;
}

/// Validates PHP endpoint replies before the app treats them as data.
class ApiGuard {
  ApiGuard._();

  static const String htmlFallbackMessage =
      'The server returned a web page instead of data. The backend may not be updated yet; please try again later.';
  static const String invalidJsonMessage = 'The server sent an unreadable response. Please try again.';

  /// The JSON object of [response], or throws [ApiResponseException].
  static Map<String, dynamic> jsonMap(Response<dynamic> response) =>
      parse(response.data, statusCode: response.statusCode);

  static Map<String, dynamic> parse(Object? data, {int? statusCode}) {
    Object? body = data;
    if (body is String) {
      final String text = body.trimLeft();
      if (text.startsWith('<')) {
        throw ApiResponseException(htmlFallbackMessage, statusCode: statusCode, htmlFallback: true);
      }
      try {
        body = jsonDecode(text);
      } catch (_) {
        throw ApiResponseException(invalidJsonMessage, statusCode: statusCode);
      }
    }
    if (body is! Map) throw ApiResponseException(invalidJsonMessage, statusCode: statusCode);
    final Map<String, dynamic> map = Map<String, dynamic>.from(body);
    if (statusCode != null && (statusCode < 200 || statusCode >= 300)) {
      throw ApiResponseException(serverMessage(map) ?? 'The server could not process the request (HTTP $statusCode).',
          statusCode: statusCode);
    }
    return map;
  }

  /// [map] with `success == true`, otherwise throws with the server's message.
  static Map<String, dynamic> requireSuccess(Map<String, dynamic> map, {String fallback = 'The request failed.'}) {
    if (map['success'] == true) return map;
    throw ApiResponseException(serverMessage(map) ?? fallback);
  }

  static String? serverMessage(Object? body) {
    if (body is Map) {
      final Object? m = body['message'];
      if (m is String && m.trim().isNotEmpty) return m.trim();
    }
    return null;
  }

  /// A readable message for any API failure (never an exception dump).
  static String messageFor(Object error) {
    if (error is ApiResponseException) return error.message;
    if (error is String && error.trim().isNotEmpty) return error;
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return 'Could not reach the server. Please check your connection and try again.';
        case DioExceptionType.badResponse:
          final int? code = error.response?.statusCode;
          Object? data = error.response?.data;
          if (data is String && data.trimLeft().startsWith('{')) {
            try {
              data = jsonDecode(data);
            } catch (_) {}
          }
          final String? server = serverMessage(data);
          if (code == 401) return 'Your session has expired. Please sign in again.';
          if (code == 403) return server ?? 'You are not allowed to perform this action.';
          if (code == 404) return 'This feature is not available on the server yet.';
          return server ?? 'The server could not process the request. Please try again later.';
        default:
          return 'Something went wrong. Please try again.';
      }
    }
    return 'Something went wrong. Please try again.';
  }
}
