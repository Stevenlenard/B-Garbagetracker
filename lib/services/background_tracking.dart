import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps a signed-in driver tracked while the app is not on screen (Android).
///
/// Closing the app (finishing the activity) stops GPS and takes the truck offline. Leaving it with Back, Home or the
/// lock screen does not, as long as the tracking service runs and Android is not allowed to put the app to sleep.
class BackgroundTracking {
  BackgroundTracking._();

  static const MethodChannel _channel = MethodChannel('gt/app');
  static const String _askedKey = 'gt_battery_exemption_asked';

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Sends the app to the background instead of closing it. False when not possible (web, iOS, error).
  static Future<bool> moveToBack() async {
    if (!supported) return false;
    try {
      return (await _channel.invokeMethod<bool>('moveToBack')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True while the trip's own foreground service runs (see TrackingService.kt). Set from the results below.
  static bool serviceRunning = false;

  /// Remote switch `admin_settings/trip_service_enabled` (default on): turning it off makes the app fall back to
  /// the GPS stream's own service without a new APK.
  static bool serviceAllowed = true;
  static StreamSubscription<DatabaseEvent>? _switchSub;

  static void watchSwitch() {
    if (!supported || _switchSub != null) return;
    try {
      _switchSub = FirebaseDatabase.instance.ref('admin_settings/trip_service_enabled').onValue.listen((DatabaseEvent e) {
        serviceAllowed = e.snapshot.value != false;
      }, onError: (_) {});
    } catch (_) {}
  }

  /// Starts the trip-long foreground service that keeps the app running while another app is in front.
  /// Must be called while the app is on screen. False when not possible (web, iOS, no location permission).
  static Future<bool> startTripService() async {
    if (!supported) return false;
    try {
      final bool requested = (await _channel.invokeMethod<bool>('startTrackingService')) ?? false;
      // Relied on only once the service has really become a foreground service (Android may refuse it).
      bool confirmed = false;
      for (int i = 0; requested && !confirmed && i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        confirmed = (await _channel.invokeMethod<bool>('isTrackingServiceRunning')) ?? false;
      }
      serviceRunning = confirmed;
    } catch (_) {
      serviceRunning = false;
    }
    return serviceRunning;
  }

  static Future<void> stopTripService() async {
    if (!supported) return;
    serviceRunning = false;
    try {
      await _channel.invokeMethod<bool>('stopTrackingService');
    } catch (_) {}
  }

  static Future<bool> isBatteryExempt() async {
    if (!supported) return true;
    try {
      return (await _channel.invokeMethod<bool>('isBatteryExempt')) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestBatteryExemption() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('requestBatteryExemption');
    } catch (_) {}
  }

  /// At most once a day while the app is still not exempt, explains why it must not be put to sleep and opens the
  /// system prompt. A driver who chose "Later" is asked again the next day: without the exemption the phone freezes
  /// the app in the background and the truck drops off every map.
  static Future<void> askOnce(BuildContext context) async {
    if (!supported) return;
    try {
      if (await isBatteryExempt()) return;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final DateTime now = DateTime.now();
      final String today = '${now.year}-${now.month}-${now.day}';
      if (prefs.get(_askedKey) == today) return;
      await prefs.setString(_askedKey, today);
      if (!context.mounted) return;
      final bool? go = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          backgroundColor: Colors.white,
          title: const Row(children: <Widget>[
            Icon(Icons.battery_charging_full_rounded, color: Color(0xFF00796B), size: 28),
            SizedBox(width: 12),
            Expanded(child: Text('Keep tracking on', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A)))),
          ]),
          content: const Text(
            'So the truck stays on the map when you press Home or lock the phone, allow this app to run in the background. '
            'Do not swipe the app away from Recent apps while collecting.',
            style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500, height: 1.4),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Later', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w800)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00796B),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              ),
              child: const Text('Allow', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      );
      if (go == true) await requestBatteryExemption();
    } catch (_) {}
  }
}
