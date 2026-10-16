import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/user.dart';
import 'package:garbage_tracking_app/services/notification_service.dart';
import 'package:garbage_tracking_app/utils/resident_alert_rules.dart';

void main() {
  const String home = 'Central (Purok 1)';
  bool forArian(Map<String, Object> n) => ResidentAlertRules.isFor(n, residentId: 24, purok: home);

  test('approach, arrival and the driver\'s manual alert reach residents of that purok', () {
    expect(forArian(<String, Object>{'type': 'auto_approach', 'purok': home, 'stage': 'approach_10'}), isTrue);
    expect(forArian(<String, Object>{'type': 'auto_arrival', 'purok': home}), isTrue);
    expect(forArian(<String, Object>{'type': 'manual_alert', 'purok': home}), isTrue, reason: 'the "Alert residents" button used to reach nobody');
    expect(forArian(<String, Object>{'type': 'manual_alert', 'purok': 'Riverside'}), isFalse);
  });

  test('older short names match the registered purok ("Purok 1" = "Central (Purok 1)")', () {
    expect(forArian(<String, Object>{'type': 'auto_arrival', 'purok': 'Purok 1'}), isTrue);
    expect(forArian(<String, Object>{'type': 'auto_arrival', 'purok': 'Purok 2'}), isFalse);
  });

  test('private items stay private', () {
    expect(forArian(<String, Object>{'type': 'COMPLAINT_RESOLVED', 'resident_id': '24'}), isTrue);
    expect(forArian(<String, Object>{'type': 'COMPLAINT_RESOLVED', 'resident_id': '25'}), isFalse);
    expect(forArian(<String, Object>{'type': 'ISSUE_UPDATE', 'targetUserId': '24'}), isFalse);
    expect(forArian(<String, Object>{'type': 'NEW_REGISTRATION'}), isFalse);
    expect(forArian(<String, Object>{'type': 'TRUCK_PROXIMITY', 'purok': home}), isFalse, reason: 'legacy broadcast is not pushed');
  });

  test('the phone notification uses the same rule as the bell', () {
    final UserData arian = UserData(userId: 24, name: 'Arian', email: '', role: 'resident', purok: home);
    for (final Map<String, Object> n in <Map<String, Object>>[
      <String, Object>{'type': 'manual_alert', 'purok': home},
      <String, Object>{'type': 'auto_arrival', 'purok': 'Purok 1'},
      <String, Object>{'type': 'COMPLAINT_RESOLVED', 'resident_id': '25'},
    ]) {
      expect(NotificationService.isRelevantFor(n, arian), forArian(n), reason: '$n');
    }
  });
}
