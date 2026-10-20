import 'services/server_clock.dart';
import 'screens/route_history_entry.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint, DebugPrintCallback;
import 'package:flutter/material.dart';
import 'utils/app_navigator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'config/mapbox_config.dart';
import 'config/app_config.dart';
import 'utils/app_localizations.dart';
import 'utils/tracking_telemetry.dart';
import 'services/notification_service.dart';
import 'screens/login_screen.dart';
import 'screens/admin_dashboard.dart';
import 'screens/resident_dashboard.dart';
import 'screens/driver_dashboard.dart';
import 'widgets/role_gate.dart';
import 'screens/register_choice_screen.dart';
import 'screens/resident_register.dart';
import 'screens/driver_register.dart';
import 'screens/complaints_screen.dart';
import 'screens/analytics_screen.dart';
import 'screens/user_management_screen.dart';
import 'screens/file_complaint_screen.dart';
import 'screens/resident_track_truck_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/verify_2fa_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/standalone_gis_web_screen.dart';
import 'screens/route_history_screen.dart';

void main() async {
  // Trigger Rebuild
  WidgetsFlutterBinding.ensureInitialized();

  // Explicit test mode (--dart-define=GT_TEST_MODE=true) must be fully configured,
  // and test overrides are never accepted without it. Otherwise the app refuses to
  // start: it never silently falls back to production Firebase or Hostinger.
  final List<String> configProblems = AppConfig.validate();
  if (configProblems.isNotEmpty) {
    runApp(_ConfigErrorApp(problems: configProblems));
    return;
  }

  if (AppConfig.isTestMode) {
    // Test sessions never log precise GPS positions, including the app's existing debug output.
    final DebugPrintCallback original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        original(AppConfig.scrubForLogs(message), wrapWidth: wrapWidth);
  }

  // Initialize Localizations
  await AppLocalizations.init();

  // Mapbox: the destination account's public token from --dart-define (no built-in fallback).
  MapboxConfig.applyAccessToken();

  // Initialize Firebase with the config from google-services.json
  try {
  await Firebase.initializeApp(
    // Production options by default (unchanged);
    // the isolated test project only in explicit test mode.
    options: AppConfig.isTestMode ? AppConfig.testFirebaseOptions : const FirebaseOptions(
      apiKey: "AIzaSyAMvvefK0z-cpBLdWQaNpRvDfGtqv0GFe4",
      appId: "1:410975851749:android:56415852013793e1b2300c", // Using Android App ID for compatibility
      messagingSenderId: "410975851749",
      projectId: "garbagesis-78d39",
      databaseURL: "https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app",
    ),
  );
  ServerClock.instance.start(); // freshness checks use server time, so a wrong phone clock cannot hide live trucks
  } catch (e) {
    if (!AppConfig.isTestMode) rethrow; // production behaviour unchanged
    runApp(const _ConfigErrorApp(problems: ['Firebase initialisation failed. Check the GT_FIREBASE_* values.']));
    return;
  }

  // In test mode, confirm the initialised app really is the configured test project.
  if (!AppConfig.firebaseTargetMatches(Firebase.app().options)) {
    runApp(const _ConfigErrorApp(problems: ['Initialised Firebase project does not match the configured test project.']));
    return;
  }

  // Notifications read the Realtime Database, so they start only after Firebase is configured.
  await NotificationService.init();
  NotificationService.startPersistentListening();
  TrackingTelemetry.init(); // no-op unless test mode + GT_TELEMETRY=true

  runApp(const MyApp());
}

/// Shown instead of the app when the build-time configuration is unsafe or incomplete.
/// Lists the names of the offending keys only, never their values.
class _ConfigErrorApp extends StatelessWidget {
  final List<String> problems;
  const _ConfigErrorApp({required this.problems});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Test configuration error', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text('The app did not start, so no production Firebase or backend was contacted.'),
                const SizedBox(height: 12),
                for (final String p in problems) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $p')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  String _getInitialRoute() {
    if (kIsWeb) {
      final String fragment = Uri.base.fragment.toLowerCase();
      final String path = Uri.base.path.toLowerCase();

      // Honor explicit web requests for authentication or app screens
      if (fragment.contains('login_new')) return '/login_new'; // fresh sign-in (no saved accounts)
      if (fragment.contains('login') || path.endsWith('/login')) {
        return '/login';
      }
      if (fragment.contains('splash') || path.endsWith('/splash')) {
        return '/splash';
      }
      if (fragment.contains('admin_dashboard') || path.endsWith('/admin_dashboard')) {
        return '/admin_dashboard';
      }
      if (fragment.contains('route_history') || path.endsWith('/route_history')) {
        return '/route_history';
      }
      if (fragment.contains('resident_dashboard') || path.endsWith('/resident_dashboard')) {
        return '/resident_dashboard';
      }
      if (fragment.contains('driver_dashboard') || path.endsWith('/driver_dashboard')) {
        return '/driver_dashboard';
      }
      if (fragment.contains('register') || path.endsWith('/register')) {
        return '/register';
      }
      if (fragment.contains('forgot_password') || path.endsWith('/forgot_password')) {
        return '/forgot_password';
      }
      if (fragment.contains('complaints') || path.endsWith('/complaints')) {
        return '/complaints';
      }
      if (fragment.contains('analytics') || path.endsWith('/analytics')) {
        return '/analytics';
      }
      if (fragment.contains('user_management') || path.endsWith('/user_management')) {
        return '/user_management';
      }
      if (fragment.contains('file_complaint') || path.endsWith('/file_complaint')) {
        return '/file_complaint';
      }
      if (fragment.contains('track_trucks') || path.endsWith('/track_trucks')) {
        return '/track_trucks';
      }

      // Default web entry route is the public tracking map (/tracking)
      return '/tracking';
    }
    return '/splash';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Garbage Truck Tracker',
      debugShowCheckedModeBanner: false,
      // Visible ribbon in explicit test mode so a test session is never mistaken for production.
      builder: (context, child) => AppConfig.isTestMode
          ? Banner(message: 'TEST', location: BannerLocation.topEnd, child: child ?? const SizedBox.shrink())
          : (child ?? const SizedBox.shrink()),
      restorationScopeId: 'app',
      theme: ThemeData(
        primarySwatch: Colors.green,
        useMaterial3: true,
      ),
      navigatorKey: appNavigatorKey, // lets a tapped notification open the dashboard
      initialRoute: _getInitialRoute(),
      onGenerateRoute: (settings) {
        if (settings.name == '/tracking' || settings.name == '/gis' || settings.name == '/web_tracking') {
          return MaterialPageRoute(
            builder: (context) => const StandaloneGisWebScreen(),
            settings: settings,
          );
        }
        return null;
      },
      routes: {
        '/splash': (context) => const SplashScreen(),
        '/': (context) => kIsWeb ? const StandaloneGisWebScreen() : const LoginScreen(),
        '/login': (context) => const LoginScreen(),
        '/login_new': (context) => const LoginScreen(startFresh: true),
        '/tracking': (context) => const StandaloneGisWebScreen(),
        '/gis': (context) => const StandaloneGisWebScreen(),
        '/web_tracking': (context) => const StandaloneGisWebScreen(),
        '/admin_dashboard': (context) => const RoleGate(roles: {'admin'}, child: AdminDashboard()),
        '/resident_dashboard': (context) => const RoleGate(roles: {'resident'}, child: ResidentDashboard()),
        '/driver_dashboard': (context) => const RoleGate(roles: {'driver'}, child: DriverDashboard()),
        '/register': (context) => const RegisterChoiceScreen(),
        '/register_resident': (context) => const ResidentRegisterScreen(),
        '/register_driver': (context) => const DriverRegisterScreen(),
        '/complaints': (context) => const RoleGate(roles: {'admin'}, child: ComplaintsScreen()),
        '/analytics': (context) => const RoleGate(roles: {'admin'}, child: AnalyticsScreen()),
        '/user_management': (context) => const RoleGate(roles: {'admin'}, child: UserManagementScreen()),
        '/route_history': (context) => const RoleGate(roles: {'admin', 'driver', 'resident'}, child: RouteHistoryEntry()),
        '/file_complaint': (context) => const RoleGate(roles: {'resident'}, child: FileComplaintScreen()),
        '/track_trucks': (context) => const RoleGate(roles: {'admin', 'driver', 'resident'}, child: ResidentTrackTruckScreen()),
        '/forgot_password': (context) => const ForgotPasswordScreen(),
        '/verify_2fa': (context) {
          final args = ModalRoute.of(context)!.settings.arguments;
          if (args is Map<String, dynamic>) {
            return Verify2FAScreen(userData: args);
          }
          return const LoginScreen(); // Fallback if arguments are missing
        },
      },
    );
  }
}
