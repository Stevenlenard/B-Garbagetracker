import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/user.dart';
import 'package:garbage_tracking_app/services/notification_service.dart';
import 'package:garbage_tracking_app/utils/resident_alert_rules.dart';

/// Who sees which notification. Two defects found by an expert in the Resident app:
///  * a resident who changed purok after registering suddenly had every old alert of the new purok in the notification
///    center (90 unread: approaching / arrived records from days ago);
///  * a resident who filed a complaint received "New Resident Complaint" about their own complaint (that record is for the
///    admin and carries the complainant's resident_id, which made it match the complainant).
void main() {
  const int me = 7, other = 8;
  UserData resident(int id, {String purok = 'Central (Purok 1)'}) => UserData(userId: id, role: 'resident', purok: purok);
  final UserData driver = UserData(userId: 3, role: 'driver');
  final UserData admin = UserData(userId: 1, role: 'admin');

  Map<String, Object?> complaintFiled({int by = me}) => <String, Object?>{
        'type': 'RESIDENT_COMPLAINT',
        'title': 'New Resident Complaint',
        'message': 'Resident filed a complaint in Central (Purok 1): Missed collection',
        'resident_id': by,
        'complaint_id': 55,
        'timestamp': 1000,
      };

  group('a complaint is for the admin only', () {
    test('the resident who filed it does not get it in the notification center or as a phone notification', () {
      expect(ResidentAlertRules.isFor(complaintFiled(), residentId: me, purok: 'Central (Purok 1)'), isFalse);
      expect(NotificationService.isRelevantFor(complaintFiled(), resident(me)), isFalse);
    });

    test('no other resident gets it either', () {
      expect(ResidentAlertRules.isFor(complaintFiled(), residentId: other, purok: 'Central (Purok 1)'), isFalse);
      expect(NotificationService.isRelevantFor(complaintFiled(), resident(other)), isFalse);
    });

    test('the driver does not get it', () {
      expect(NotificationService.isRelevantFor(complaintFiled(), driver), isFalse);
      final String d = File('lib/screens/driver_dashboard.dart').readAsStringSync();
      expect(RegExp(r"STRICT EXCLUSION: Admin-only types\s*if \(\['REGISTRATION', 'NEW_REGISTRATION', 'RESIDENT_COMPLAINT'\]\.contains\(type\)\) \{\s*return false;").hasMatch(d), isTrue);
    });

    test('the admin gets it', () {
      expect(NotificationService.isRelevantFor(complaintFiled(), admin), isTrue);
    });

    test('every record written for staff stays out of a resident\'s inbox, whatever resident_id it carries', () {
      for (final String type in ResidentAlertRules.staffOnlyTypes) {
        expect(ResidentAlertRules.isFor(<String, Object?>{'type': type, 'resident_id': me, 'targetUserId': me, 'timestamp': 1}, residentId: me, purok: 'Central (Purok 1)'),
            isFalse, reason: type);
      }
    });

    test('what the resident does get about their complaint is unchanged: In Progress / Resolved, only for the complainant', () {
      final Map<String, Object?> resolved = <String, Object?>{'type': 'COMPLAINT_RESOLVED', 'resident_id': me, 'complaint_id': 55, 'timestamp': 2};
      expect(ResidentAlertRules.isFor(resolved, residentId: me, purok: null), isTrue);
      expect(ResidentAlertRules.isFor(resolved, residentId: other, purok: null), isFalse);
    });
  });

  group('changing purok does not bring in the alerts that were sent before', () {
    Map<String, Object?> alert({required String purok, required int at, String type = 'auto_approach'}) =>
        <String, Object?>{'type': type, 'purok': purok, 'timestamp': at, 'truck_id': 'GT-001'};

    test('alerts of the new purok sent before the change are left out; later ones arrive', () {
      const int changedAt = 5000;
      final Map<String, Object?> old = alert(purok: 'Central (Purok 1)', at: 4000);
      final Map<String, Object?> oldArrival = alert(purok: 'Central (Purok 1)', at: 100, type: 'auto_arrival');
      final Map<String, Object?> fresh = alert(purok: 'Central (Purok 1)', at: 5001);
      expect(ResidentAlertRules.isFor(old, residentId: me, purok: 'Central (Purok 1)', purokSinceMs: changedAt), isFalse);
      expect(ResidentAlertRules.isFor(oldArrival, residentId: me, purok: 'Central (Purok 1)', purokSinceMs: changedAt), isFalse);
      expect(ResidentAlertRules.isFor(fresh, residentId: me, purok: 'Central (Purok 1)', purokSinceMs: changedAt), isTrue);
    });

    test('the manual "Alert residents" of the driver follows the same rule', () {
      expect(ResidentAlertRules.isFor(alert(purok: 'Central (Purok 1)', at: 10, type: 'manual_alert'), residentId: me, purok: 'Central (Purok 1)', purokSinceMs: 5000), isFalse);
    });

    test('still only the resident\'s own purok, with the name variants of a purok treated as one', () {
      expect(ResidentAlertRules.isFor(alert(purok: 'Riverside', at: 9000), residentId: me, purok: 'Central (Purok 1)', purokSinceMs: 5000), isFalse);
      expect(ResidentAlertRules.isFor(alert(purok: 'Purok 1', at: 9000), residentId: me, purok: 'Central (Purok 1)', purokSinceMs: 5000), isTrue);
    });

    test('a resident who never changed purok sees everything addressed to the purok as before', () {
      expect(ResidentAlertRules.isFor(alert(purok: 'Central (Purok 1)', at: 1), residentId: me, purok: 'Central (Purok 1)'), isTrue);
    });

    test('personal notifications (complaint updates) are not cut by the change of purok', () {
      final Map<String, Object?> inProgress = <String, Object?>{'type': 'COMPLAINT_IN_PROGRESS', 'resident_id': me, 'timestamp': 10};
      expect(ResidentAlertRules.isFor(inProgress, residentId: me, purok: 'Central (Purok 1)', purokSinceMs: 5000), isTrue);
    });
  });

  group('the Resident dashboard wires it', () {
    final String r = File('lib/screens/resident_dashboard.dart').readAsStringSync();

    test('a change of purok is noticed, stored with the resident and used by the inbox and the unread count', () {
      expect(r.contains("'purok_since_ms': now, 'purok_since_purok': newPurok"), isTrue);
      expect(r.contains('purokSinceMs: _purokSinceMs'), isTrue);
      expect(r.contains("data['purok_since_ms']"), isTrue);
    });

    test('the notification center and the unread count use the same rule', () {
      expect(r.contains('isRelevant: _isResidentRelevant'), isTrue);
      expect(RegExp(r'_isResidentRelevant\(value\)').hasMatch(r), isTrue);
    });
  });
}
