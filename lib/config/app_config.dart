import 'package:firebase_core/firebase_core.dart';

/// Build-time configuration for the isolated test environment.
///
/// Production behaviour is the default and is unchanged. The test configuration is
/// only used when the app is built/run with `--dart-define=GT_TEST_MODE=true`, and in
/// that case EVERY required value must be supplied: the app refuses to start rather
/// than falling back to the production Firebase project or Hostinger backend.
///
/// Required in test mode:
///   GT_FIREBASE_API_KEY, GT_FIREBASE_APP_ID, GT_FIREBASE_MESSAGING_SENDER_ID,
///   GT_FIREBASE_PROJECT_ID, GT_FIREBASE_DATABASE_URL, GT_API_BASE_URL
///
/// Optional (test mode only):
///   GT_TELEMETRY=true            enable development-only timing logs
///   GT_TELEMETRY_ROLE=driver|admin|resident   label for the log lines
class AppConfig {
  AppConfig._();

  static const bool isTestMode = bool.fromEnvironment('GT_TEST_MODE');

  static const String _fbApiKey = String.fromEnvironment('GT_FIREBASE_API_KEY');
  static const String _fbAppId = String.fromEnvironment('GT_FIREBASE_APP_ID');
  static const String _fbSenderId = String.fromEnvironment('GT_FIREBASE_MESSAGING_SENDER_ID');
  static const String _fbProjectId = String.fromEnvironment('GT_FIREBASE_PROJECT_ID');
  static const String _fbDatabaseUrl = String.fromEnvironment('GT_FIREBASE_DATABASE_URL');
  static const String _apiBaseUrl = String.fromEnvironment('GT_API_BASE_URL');

  static const bool telemetryRequested = bool.fromEnvironment('GT_TELEMETRY');
  static const String telemetryRole = String.fromEnvironment('GT_TELEMETRY_ROLE', defaultValue: 'unknown');

  /// Production identifiers, used ONLY as guards so test mode can never target them.
  static const String productionProjectId = 'garbagesis-78d39';
  static const String productionApiHostMarker = 'hostingersite.com';

  /// Problems with the current build-time configuration (empty = OK).
  static List<String> validate() => validateValues(
        testMode: isTestMode,
        apiKey: _fbApiKey,
        appId: _fbAppId,
        senderId: _fbSenderId,
        projectId: _fbProjectId,
        databaseUrl: _fbDatabaseUrl,
        apiBaseUrl: _apiBaseUrl,
      );

  /// Pure validation so the rules can be unit-tested. Messages name the missing
  /// keys only; they never include configured values.
  static List<String> validateValues({
    required bool testMode,
    String apiKey = '',
    String appId = '',
    String senderId = '',
    String projectId = '',
    String databaseUrl = '',
    String apiBaseUrl = '',
  }) {
    final List<String> problems = [];
    final Map<String, String> provided = {
      'GT_FIREBASE_API_KEY': apiKey,
      'GT_FIREBASE_APP_ID': appId,
      'GT_FIREBASE_MESSAGING_SENDER_ID': senderId,
      'GT_FIREBASE_PROJECT_ID': projectId,
      'GT_FIREBASE_DATABASE_URL': databaseUrl,
      'GT_API_BASE_URL': apiBaseUrl,
    };

    if (!testMode) {
      final List<String> stray = provided.entries.where((e) => e.value.trim().isNotEmpty).map((e) => e.key).toList();
      if (stray.isNotEmpty) {
        problems.add('${stray.join(', ')} supplied but GT_TEST_MODE is not true. '
            'Refusing to start so production is never used by mistake.');
      }
      return problems;
    }

    provided.forEach((key, value) {
      if (value.trim().isEmpty) problems.add('$key is required in test mode.');
    });
    if (problems.isNotEmpty) return problems;

    if (projectId.trim() == productionProjectId || databaseUrl.contains(productionProjectId)) {
      problems.add('GT_FIREBASE_* points at the production Firebase project. Use a separate test project.');
    }
    if (!databaseUrl.trim().startsWith('https://')) {
      problems.add('GT_FIREBASE_DATABASE_URL must start with https://.');
    }
    if (apiBaseUrl.contains(productionApiHostMarker)) {
      problems.add('GT_API_BASE_URL points at the production Hostinger backend. Use the local stub.');
    } else if (!_isLocalHttpUrl(apiBaseUrl)) {
      problems.add('GT_API_BASE_URL must be an http:// URL on loopback or a private LAN address (local stub).');
    }
    return problems;
  }

  /// `http(s)` URL whose host is localhost, loopback or an RFC1918 private address.
  static bool _isLocalHttpUrl(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return false;
    final String host = uri.host.toLowerCase();
    if (host == 'localhost') return true;
    final List<String> p = host.split('.');
    if (p.length != 4) return false;
    final List<int?> n = p.map(int.tryParse).toList();
    if (n.any((x) => x == null || x < 0 || x > 255)) return false;
    final int a = n[0]!, b = n[1]!;
    return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  /// Firebase options for test mode. Only valid after [validate] returned no problems.
  static FirebaseOptions get testFirebaseOptions => const FirebaseOptions(
        apiKey: _fbApiKey,
        appId: _fbAppId,
        messagingSenderId: _fbSenderId,
        projectId: _fbProjectId,
        databaseURL: _fbDatabaseUrl,
      );

  /// Test-mode PHP base URL, always with a trailing slash.
  static String get testApiBaseUrl => _apiBaseUrl.trim().endsWith('/') ? _apiBaseUrl.trim() : '${_apiBaseUrl.trim()}/';

  static final RegExp _coordinateLike = RegExp(r'-?\d{1,3}\.\d{4,}');

  /// Removes anything that looks like a precise coordinate from a log line. Installed
  /// as the `debugPrint` filter in test mode so no GPS position reaches diagnostic
  /// logs, including the app's pre-existing debug output.
  static String scrubForLogs(String? message) =>
      message == null ? '' : message.replaceAll(_coordinateLike, '<num>');

  /// Confirms the initialised Firebase app really is the configured test project.
  static bool firebaseTargetMatches(FirebaseOptions initialised) =>
      !isTestMode || (initialised.projectId == _fbProjectId && initialised.projectId != productionProjectId);
}
