import 'package:dio/dio.dart';
import '../config/app_config.dart';
import '../utils/session_manager.dart';

/// Adds the backend-issued token (`X-GT-Token`) to every request while one exists.
/// Sessions without a token send nothing extra, so older servers and clients are
/// unaffected.
class AuthTokenInterceptor extends Interceptor {
  AuthTokenInterceptor({Future<String?> Function()? tokenProvider})
      : _tokenProvider = tokenProvider ?? SessionManager.getAuthToken;

  final Future<String?> Function() _tokenProvider;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    try {
      final String? token = await _tokenProvider();
      if (token != null && token.isNotEmpty) {
        options.headers['X-GT-Token'] = token;
      }
    } catch (_) {
      // Never block a request because the token could not be read.
    }
    handler.next(options);
  }
}

class ApiClient {
  // Siguraduhin na walang extra spaces o hidden characters dito
  static const String _productionBaseUrl = "https://indigo-bear-885857.hostingersite.com/backend/";

  /// Production backend by default. In explicit test mode (GT_TEST_MODE) this is the
  /// local PHP stub instead; there is no fallback between the two.
  static String get baseUrl => AppConfig.isTestMode ? AppConfig.testApiBaseUrl : _productionBaseUrl;

  static final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
    // Force direct connection to avoid any accidental proxy issues
    followRedirects: true,
  ));

  static bool _interceptorInstalled = false;

  static Dio get instance {
    if (!_interceptorInstalled) {
      _dio.interceptors.add(AuthTokenInterceptor());
      _interceptorInstalled = true;
    }
    return _dio;
  }
}
