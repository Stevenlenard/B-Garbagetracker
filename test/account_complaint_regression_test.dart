import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/api/api_client.dart';
import 'package:garbage_tracking_app/config/app_config.dart';
import 'package:garbage_tracking_app/models/user.dart';
import 'package:garbage_tracking_app/utils/complaint_flow.dart';

void main() {
  group('Login response contract (what login.php returns -> UserData)', () {
    test('resident login payload', () {
      final u = UserData.fromJson({
        'user_id': '12',
        'username': 'maria01',
        'name': 'Maria Santos',
        'email': 'maria@example.com',
        'phone': '09171234567',
        'purok': 'Purok 1',
        'complete_address': 'Blk 1',
        'role': 'resident',
        'is_archived': '0',
      });
      expect(u.userId, 12);
      expect(u.role, 'resident');
      expect(u.purok, 'Purok 1');
      expect(u.approvalStatus, 'approved', reason: 'residents are auto-approved');
    });

    test('driver login payload keeps truck assignment', () {
      final u = UserData.fromJson({
        'user_id': 7,
        'username': 'driver01',
        'name': 'Juan',
        'email': 'j@example.com',
        'license_number': 'N01',
        'preferred_truck': 'GT-007',
        'role': 'driver',
      });
      expect(u.userId, 7);
      expect(u.role, 'driver');
      expect(u.preferredTruck, 'GT-007');
    });

    test('a user survives a session save/restore round trip', () {
      final u = UserData.fromJson({'user_id': 7, 'username': 'd', 'name': 'D', 'email': 'e', 'role': 'driver'});
      final back = UserData.fromJson(u.toJson());
      expect(back.userId, 7);
      expect(back.role, 'driver');
    });
  });

  group('Backend target is unchanged by the GPS/lifecycle work', () {
    test('production API base URL is the default (no test mode)', () {
      expect(AppConfig.isTestMode, isFalse);
      expect(ApiClient.baseUrl, 'https://indigo-bear-885857.hostingersite.com/backend/');
    });
  });

  group('Complaint workflow rules', () {
    test('resolved notification fires only on the transition into resolved', () {
      expect(ComplaintFlow.shouldNotifyResolved(previousStatus: 'pending', newStatus: 'RESOLVED'), isTrue);
      expect(ComplaintFlow.shouldNotifyResolved(previousStatus: 'in_progress', newStatus: 'RESOLVED'), isTrue);
      expect(ComplaintFlow.shouldNotifyResolved(previousStatus: null, newStatus: 'RESOLVED'), isTrue);
    });

    test('re-resolving never notifies again (no duplicates)', () {
      expect(ComplaintFlow.shouldNotifyResolved(previousStatus: 'resolved', newStatus: 'RESOLVED'), isFalse);
      expect(ComplaintFlow.shouldNotifyResolved(previousStatus: 'Resolved', newStatus: 'resolved'), isFalse);
    });

    test('moving to in progress never sends the resolved notification', () {
      expect(ComplaintFlow.shouldNotifyResolved(previousStatus: 'pending', newStatus: 'IN_PROGRESS'), isFalse);
    });

    test('there is exactly one notification key per complaint', () {
      expect(ComplaintFlow.resolvedNotificationKey(15), ComplaintFlow.resolvedNotificationKey('15'));
    });

    test('a complaint can only be filed by a signed-in resident (never as "0")', () {
      expect(ComplaintFlow.residentIdFor(null), isNull);
      expect(ComplaintFlow.residentIdFor(UserData(userId: 0, role: 'resident')), isNull);
      expect(ComplaintFlow.residentIdFor(UserData(userId: 9, role: 'driver')), isNull);
      expect(ComplaintFlow.residentIdFor(UserData(userId: 9, role: 'Resident')), '9');
    });

    test('error messages are readable and never leak exception dumps', () {
      expect(ComplaintFlow.errorMessage('Resident account not found.'), 'Resident account not found.');
      final net = DioException(
        requestOptions: RequestOptions(path: 'file_complaint.php'),
        type: DioExceptionType.connectionError,
      );
      expect(ComplaintFlow.errorMessage(net), contains('connection'));
      expect(ComplaintFlow.errorMessage(net), isNot(contains('DioException')));
      expect(ComplaintFlow.errorMessage(StateError('x')), isNot(contains('StateError')));
    });
  });
}
