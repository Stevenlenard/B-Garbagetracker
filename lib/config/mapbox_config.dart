import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;

/// Single source of the Mapbox account configuration and of the Mapbox feature switches.
///
/// Values are compile-time `--dart-define`s, one file PER PLATFORM so that each build only
/// contains its own token (see `config/mapbox.*.example.json`, `scripts/build_release.ps1`):
///
///   flutter build web --release --dart-define-from-file=config/mapbox.web.local.json
///   flutter build apk --release --dart-define-from-file=config/mapbox.android.local.json
///
/// * `MAPBOX_ACCESS_TOKEN` - a PUBLIC (`pk.`) runtime token of the destination account. It is
///   embedded in the build and readable by anyone who has the APK or opens the website; it is
///   not a secret. There is deliberately NO built-in fallback token: a build without it shows
///   "map not configured" instead of silently using another account. Secret (`sk.`) tokens
///   are refused.
///   - Web: a token with URL restrictions for the hosted domain.
///   - Android: a token WITHOUT URL restrictions (Mapbox does not support URL-restricted
///     tokens in apps built with the Maps/Navigation SDKs; this app uses the Maps SDK).
///   - Card-free trial (one default token, no URL restrictions possible): the same token for
///     both, `MAPBOX_TOKEN_PLATFORM` = `shared`.
/// * `MAPBOX_TOKEN_PLATFORM` - `web`, `android` or `shared`. A token labelled for the other
///   platform is refused (a URL-restricted web token would fail in the APK, and an
///   unrestricted Android token should not be published on the website).
/// * `MAPBOX_MATRIX_ENABLED` - Matrix API (directions-matrix/v1). Default OFF. While off, no
///   code path may send a Matrix request (see [MapboxRequestGuard]). Keep it off for the
///   defense build unless a controlled re-enable has been explicitly authorized.
/// * `MAPBOX_DIRECTIONS_ENABLED` - Directions API used by route optimization. Default OFF.
///   Route optimization only calls Directions after a Matrix result, so it is unused while
///   Matrix is off; kept as its own switch so it can never become an automatic substitute.
/// * `MAPBOX_MAP_MATCHING_ENABLED` - Map Matching API (matching/v5): snaps a finished trip's line
///   to the roads in Route History. Default OFF. Display only; when off or failing, the
///   smoothed GPS line is drawn.
class MapboxConfig {
  MapboxConfig._();

  static const String _token = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  static const String tokenPlatform = String.fromEnvironment('MAPBOX_TOKEN_PLATFORM');
  static const bool matrixEnabled = bool.fromEnvironment('MAPBOX_MATRIX_ENABLED');
  static const bool directionsEnabled = bool.fromEnvironment('MAPBOX_DIRECTIONS_ENABLED');
  static const bool mapMatchingEnabled = bool.fromEnvironment('MAPBOX_MAP_MATCHING_ENABLED');

  /// Upper bounds applied even when a service is enabled (per running app instance; this is
  /// NOT an account-wide spending cap).
  static const int maxMatrixRequestsPerSession =
      int.fromEnvironment('MAPBOX_MATRIX_MAX_REQUESTS', defaultValue: 10);
  static const int maxMatrixCoordinates = 25; // Mapbox limit for the driving profile
  /// Elements = sources x destinations. A first optimization of 13 stops needs 14 x 14 = 196;
  /// later ones need only the truck row (13).
  static const int maxMatrixElementsPerRequest = 200;
  static const int maxMatrixElementsPerSession =
      int.fromEnvironment('MAPBOX_MATRIX_MAX_ELEMENTS', defaultValue: 1000);
  static const int maxDirectionsRequestsPerSession =
      int.fromEnvironment('MAPBOX_DIRECTIONS_MAX_REQUESTS', defaultValue: 10);
  /// Map Matching: one request per 100 route points, made once per finished trip (the result is
  /// cached with the trip), so a session that opens many old trips still stays small.
  static const int maxMapMatchingRequestsPerSession =
      int.fromEnvironment('MAPBOX_MAP_MATCHING_MAX_REQUESTS', defaultValue: 60);
  static const int maxMapMatchingCoordinates = 100; // Mapbox limit per request

  /// Mapbox account names whose tokens are refused even when passed explicitly (the account
  /// whose token was hard-coded in earlier builds and is to be invalidated). Account names
  /// are not secrets; no token value is stored here.
  static const List<String> blockedAccounts = <String>['prince6703'];

  /// Only a public token of a non-blocked account is accepted; anything else counts as
  /// "not configured".
  static String get accessToken =>
      isUsableToken(_token) && platformMatches(tokenPlatform, isWeb: kIsWeb) ? _token.trim() : '';

  /// `shared` fits both platforms; `web` only the web build; `android` only the app.
  @visibleForTesting
  static bool platformMatches(String label, {required bool isWeb}) {
    switch (label.trim().toLowerCase()) {
      case 'shared':
        return true;
      case 'web':
        return isWeb;
      case 'android':
        return !isWeb;
      default:
        return false;
    }
  }

  static bool get isConfigured => accessToken.isNotEmpty;

  @visibleForTesting
  static bool isUsableToken(String raw) {
    final String t = raw.trim();
    if (!t.startsWith('pk.') || t.length <= 20) return false;
    final String? account = accountOf(t);
    return account == null || !blockedAccounts.contains(account);
  }

  /// The account name inside a Mapbox token (its middle part is base64url JSON {"u": ...}).
  @visibleForTesting
  static String? accountOf(String token) {
    final List<String> parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final Object? payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final Object? u = payload is Map ? payload['u'] : null;
      return u?.toString();
    } catch (_) {
      return null;
    }
  }

  static bool _applied = false;

  /// Hands the token to the Mapbox SDK once per app run. Without a configured token
  /// nothing is set: map views show [isConfigured] == false instead of loading.
  static void applyAccessToken() {
    if (_applied) return;
    _applied = true;
    debugPrint('[MAPBOX CONFIG] $diagnostics');
    if (isConfigured) MapboxOptions.setAccessToken(accessToken);
  }

  /// Short, non-reversible description for logs (never the token itself).
  static String get diagnostics =>
      'mapbox token: ${isConfigured ? 'configured ($tokenPlatform)' : (_token.isEmpty ? 'missing' : (!isUsableToken(_token) ? 'rejected (not a usable pk. token)' : 'rejected (MAPBOX_TOKEN_PLATFORM "$tokenPlatform" does not fit this build)'))}, '
      'matrix: ${matrixEnabled ? 'ON' : 'OFF'}, directions: ${directionsEnabled ? 'ON' : 'OFF'}, '
      'map matching: ${mapMatchingEnabled ? 'ON' : 'OFF'}';
}

enum MapboxService { matrix, directions, mapMatching }

/// Gate every Mapbox REST call must pass before touching the network. A refused call is
/// counted (diagnostics / tests) and never retried by the caller.
class MapboxRequestGuard {
  MapboxRequestGuard._();

  static final Map<MapboxService, int> _sent = <MapboxService, int>{};
  static final Map<MapboxService, int> _blocked = <MapboxService, int>{};
  static int _matrixElements = 0;

  /// Test hook: overrides the compile-time switches. Never set in app code.
  @visibleForTesting
  static bool? debugMatrixEnabled;
  @visibleForTesting
  static bool? debugDirectionsEnabled;
  @visibleForTesting
  static bool? debugMapMatchingEnabled;
  @visibleForTesting
  static String? debugAccessToken;

  static bool get _matrixOn => debugMatrixEnabled ?? MapboxConfig.matrixEnabled;
  static bool get _directionsOn => debugDirectionsEnabled ?? MapboxConfig.directionsEnabled;
  static bool get _mapMatchingOn => debugMapMatchingEnabled ?? MapboxConfig.mapMatchingEnabled;

  /// Matrix switch on its own, so release compilers fold it to a constant and drop the whole Matrix
  /// code path while MAPBOX_MATRIX_ENABLED is false (the release build script checks this).
  static bool get matrixOn => _matrixOn;

  static String get accessToken => debugAccessToken ?? MapboxConfig.accessToken;

  // Kept as one small expression so the compiler inlines it and drops the Matrix code path while
  // MAPBOX_MATRIX_ENABLED is false (the release build script checks that the endpoint is absent).
  static bool isEnabled(MapboxService s) =>
      s == MapboxService.matrix ? _matrixOn : (s == MapboxService.directions ? _directionsOn : _mapMatchingOn);

  static int _limit(MapboxService s) {
    switch (s) {
      case MapboxService.matrix:
        return MapboxConfig.maxMatrixRequestsPerSession;
      case MapboxService.directions:
        return MapboxConfig.maxDirectionsRequestsPerSession;
      case MapboxService.mapMatching:
        return MapboxConfig.maxMapMatchingRequestsPerSession;
    }
  }

  /// Returns null when the request may be sent (and counts it), otherwise the reason.
  /// [elements] (Matrix): sources x destinations of this request.
  static String? acquire(MapboxService s, {int coordinates = 0, int elements = 0}) {
    String? reason;
    if (!isEnabled(s)) {
      reason = 'disabled';
    } else if (accessToken.isEmpty) {
      reason = 'no token';
    } else if (s == MapboxService.mapMatching && coordinates > MapboxConfig.maxMapMatchingCoordinates) {
      reason = 'too many coordinates ($coordinates > ${MapboxConfig.maxMapMatchingCoordinates})';
    } else if (s == MapboxService.matrix && coordinates > MapboxConfig.maxMatrixCoordinates) {
      reason = 'too many coordinates ($coordinates > ${MapboxConfig.maxMatrixCoordinates})';
    } else if (s == MapboxService.matrix && elements > MapboxConfig.maxMatrixElementsPerRequest) {
      reason = 'too many elements ($elements > ${MapboxConfig.maxMatrixElementsPerRequest})';
    } else if (s == MapboxService.matrix &&
        _matrixElements + elements > MapboxConfig.maxMatrixElementsPerSession) {
      reason = 'session element limit reached (${MapboxConfig.maxMatrixElementsPerSession})';
    } else if ((_sent[s] ?? 0) >= _limit(s)) {
      reason = 'session limit reached (${_limit(s)})';
    }
    if (reason != null) {
      _blocked[s] = (_blocked[s] ?? 0) + 1;
      debugPrint('[MAPBOX GUARD] ${s.name} request blocked: $reason');
      return reason;
    }
    _sent[s] = (_sent[s] ?? 0) + 1;
    if (s == MapboxService.matrix) _matrixElements += elements;
    debugPrint('[MAPBOX GUARD] ${s.name} request ${_sent[s]}/${_limit(s)}'
        '${s == MapboxService.matrix ? ' ($elements elements, $_matrixElements/${MapboxConfig.maxMatrixElementsPerSession} this session)' : ''}');
    return null;
  }

  static int get matrixElementsSent => _matrixElements;

  static int sent(MapboxService s) => _sent[s] ?? 0;
  static int blocked(MapboxService s) => _blocked[s] ?? 0;

  @visibleForTesting
  static void debugReset() {
    _sent.clear();
    _blocked.clear();
    _matrixElements = 0;
    debugMatrixEnabled = null;
    debugDirectionsEnabled = null;
    debugMapMatchingEnabled = null;
    debugAccessToken = null;
  }
}
