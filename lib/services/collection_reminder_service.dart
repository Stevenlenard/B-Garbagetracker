import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../utils/session_manager.dart';
import 'collection_schedule_service.dart';
import 'notification_service.dart';

/// One weekly reminder (pure description, testable).
class ReminderSlot {
  const ReminderSlot({required this.id, required this.weekday, required this.hour, required this.minute, required this.title, required this.body});
  final int id;
  final int weekday; // DateTime.weekday, 1 = Monday
  final int hour;
  final int minute;
  final String title;
  final String body;
}

/// Weekly collection-day reminders for the resident's purok, scheduled ON THE PHONE
/// (Android alarms), so they arrive even when the app is closed. No server, no cost.
///
/// For every collection day: the evening before at 7:00 PM, and about an hour before the
/// collection time (not earlier than 5:00 AM). Changing the schedule, the purok or turning
/// notifications off replaces / removes them.
class CollectionReminderService {
  CollectionReminderService._();

  static const int _firstId = 7000; // 7000..7013: two per weekday
  static const String _channelId = 'garbage_tracker_reminders';
  static bool _tzReady = false;
  static String? _lastSignature;

  static List<ReminderSlot> plan(CollectionSchedule s) {
    final List<ReminderSlot> out = <ReminderSlot>[];
    for (final int d in s.days.toSet().toList()..sort()) {
      final int dayBefore = d == 1 ? 7 : d - 1;
      out.add(ReminderSlot(
        id: _firstId + (d - 1) * 2,
        weekday: dayBefore,
        hour: 19,
        minute: 0,
        title: 'Garbage collection tomorrow',
        body: 'Tomorrow (${CollectionSchedule.dayNames[d - 1]}) is collection day in ${s.area}, around ${s.timeLabel}. Prepare your garbage tonight.',
      ));
      int h = s.hour - 1;
      int m = s.minute;
      if (h < 5) {
        h = 5;
        m = 0;
      }
      out.add(ReminderSlot(
        id: _firstId + (d - 1) * 2 + 1,
        weekday: d,
        hour: h,
        minute: m,
        title: 'Collection day today',
        body: 'The garbage truck is expected in ${s.area} around ${s.timeLabel}. You will get an alert when it is approaching.',
      ));
    }
    return out;
  }

  static void _ensureTz() {
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Manila')); // the service area is in the Philippines
    _tzReady = true;
  }

  static tz.TZDateTime _next(int weekday, int hour, int minute) {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime t = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    while (t.weekday != weekday || !t.isAfter(now)) {
      t = t.add(const Duration(days: 1));
    }
    return t;
  }

  /// Makes the phone's reminders match [schedule] (null = no schedule: remove them).
  static Future<void> sync(CollectionSchedule? schedule) async {
    if (kIsWeb) return; // the website cannot schedule notifications while closed
    final bool enabled = await SessionManager.isAppNotificationsEnabled();
    final CollectionSchedule? s = (enabled && schedule != null && !schedule.isEmpty) ? schedule : null;
    final String sig = s == null ? 'none' : '${s.area}|${s.days.join(',')}|${s.time}';
    if (sig == _lastSignature) return;
    final FlutterLocalNotificationsPlugin plugin = NotificationService.plugin;
    try {
      for (int i = 0; i < 14; i++) {
        await plugin.cancel(_firstId + i);
      }
      _lastSignature = sig;
      if (s == null) return;
      _ensureTz();
      const NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Collection Reminders',
          channelDescription: 'Reminders on your purok\'s garbage collection days',
          importance: Importance.high,
          priority: Priority.high,
          color: Color(0xFF1565C0),
        ),
      );
      for (final ReminderSlot r in plan(s)) {
        await plugin.zonedSchedule(
          r.id,
          r.title,
          r.body,
          _next(r.weekday, r.hour, r.minute),
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle, // no exact-alarm permission needed
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime, // repeats every week
          payload: 'collection_reminder',
        );
      }
    } catch (e) {
      _lastSignature = null;
      debugPrint('[REMINDERS] could not schedule: $e');
    }
  }

  /// Logout: no reminders for an account that is not signed in.
  static Future<void> clear() => sync(null);
}
