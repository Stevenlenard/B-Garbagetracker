import 'package:dio/dio.dart';

import '../api/api_guard.dart';
import '../models/user.dart';

/// The three lifecycle states every screen shows (Android and Web, Admin, Resident, Driver).
enum ComplaintStatus { pending, inProgress, resolved }

/// Small, testable rules for the complaint workflow screens.
class ComplaintFlow {
  ComplaintFlow._();

  /// Notification types written for the complainant (server side for resident complaints).
  static const String typeInProgress = 'COMPLAINT_IN_PROGRESS';
  static const String typeResolved = 'COMPLAINT_RESOLVED';

  /// Driver truck-issue status updates (Firebase `truck_issues`).
  static const String typeIssueUpdate = 'ISSUE_UPDATE';

  /// Resident-private complaint notifications: never shown to drivers or admins.
  static const List<String> residentComplaintTypes = <String>[typeInProgress, typeResolved];

  static const int resolutionNoteMinLength = 10;
  static const int resolutionNoteMaxLength = 2000;

  /// Same mapping as backend/complaint_lib.php (older spellings included).
  static ComplaintStatus statusOf(Object? raw) {
    final String s = (raw ?? '').toString().trim().toLowerCase().replaceAll('-', '_');
    if (s == 'resolved' || s == 'completed' || s == 'closed' || s == '2') return ComplaintStatus.resolved;
    if (s.contains('progress') || s == 'under review' || s == 'under_review' || s == 'processing' || s == 'ongoing' || s == '1') {
      return ComplaintStatus.inProgress;
    }
    return ComplaintStatus.pending;
  }

  static bool isResolved(Object? status) => statusOf(status) == ComplaintStatus.resolved;

  /// Active Complaints = Pending + In Progress.
  static bool isActive(Object? status) => !isResolved(status);

  static String label(ComplaintStatus s) => switch (s) {
        ComplaintStatus.pending => 'Pending',
        ComplaintStatus.inProgress => 'In Progress',
        ComplaintStatus.resolved => 'Resolved',
      };

  /// The value the PHP API expects.
  static String apiValue(ComplaintStatus s) => switch (s) {
        ComplaintStatus.pending => 'pending',
        ComplaintStatus.inProgress => 'in_progress',
        ComplaintStatus.resolved => 'resolved',
      };

  /// Value stored in Firebase `truck_issues/*/status` (driver reports).
  static String driverIssueValue(ComplaintStatus s) => switch (s) {
        ComplaintStatus.pending => 'PENDING',
        ComplaintStatus.inProgress => 'IN_PROGRESS',
        ComplaintStatus.resolved => 'RESOLVED',
      };

  /// Allowed Admin transitions: Pending -> In Progress, Pending/In Progress -> Resolved.
  static bool canTransition(ComplaintStatus from, ComplaintStatus to) {
    if (from == ComplaintStatus.resolved || to == ComplaintStatus.pending) return false;
    if (to == ComplaintStatus.inProgress) return from == ComplaintStatus.pending;
    return true;
  }

  /// A resolution note must describe the action taken (null = valid).
  static String? validateResolutionNote(String? note) {
    final String n = (note ?? '').trim();
    if (n.length < resolutionNoteMinLength) {
      return 'Please describe the action taken (at least $resolutionNoteMinLength characters).';
    }
    if (n.length > resolutionNoteMaxLength) return 'The note is too long (maximum $resolutionNoteMaxLength characters).';
    return null;
  }

  /// "#043" — the complaint number shown to admins and in notifications.
  static String displayId(Object? id) {
    final String s = (id ?? '').toString();
    final int? n = int.tryParse(s);
    return n == null ? '#$s' : '#${n.toString().padLeft(3, '0')}';
  }

  /// The resident is notified only on the transition INTO resolved. Re-resolving an
  /// already resolved complaint (double tap, second admin) never notifies again.
  static bool shouldNotifyResolved({required String? previousStatus, required String newStatus}) {
    if (!isResolved(newStatus)) return false;
    return !isResolved(previousStatus);
  }

  /// Firebase key of the single "complaint resolved" notification of a complaint
  /// (the same key backend/complaint_lib.php writes).
  static String resolvedNotificationKey(Object complaintId) => 'complaint_resolved_$complaintId';

  static String inProgressNotificationKey(Object complaintId) => 'complaint_in_progress_$complaintId';

  /// One notification per driver report and state (a retry overwrites the same record).
  static String driverIssueNotificationKey(Object issueId, ComplaintStatus s) => 'truck_issue_${issueId}_${apiValue(s)}';

  /// Payload of the private status notification for the driver who filed [issueId]. It names
  /// the driver by id only (no `targetRole`/`truck_id`), so no other driver's app shows it.
  static Map<String, Object?> driverIssueNotification({
    required Object issueId,
    required Object driverId,
    required String issueType,
    required ComplaintStatus status,
    required Object timestamp,
  }) {
    final bool resolved = status == ComplaintStatus.resolved;
    return <String, Object?>{
      'type': typeIssueUpdate,
      'title': resolved ? 'Report Resolved' : 'Report In Progress',
      'message': resolved
          ? 'Your $issueType report has been marked as resolved. Tap to view the resolution details.'
          : 'Your $issueType report is now being reviewed by the barangay administrator.',
      'targetUserId': driverId.toString(),
      'relatedId': issueId.toString(),
      'status': apiValue(status),
      'timestamp': timestamp,
      'isRead': false,
    };
  }

  /// The complaint a notification refers to (resident complaint id or driver report id).
  static String? notificationComplaintId(Map<dynamic, dynamic> n) {
    final Object? id = n['complaint_id'] ?? n['relatedId'];
    final String s = (id ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  /// The id a complaint is filed under: only a signed-in resident has one. A missing
  /// session must never be sent as resident "0".
  static String? residentIdFor(UserData? user) {
    if (user == null) return null;
    if (user.role.toLowerCase() != 'resident') return null;
    if (user.userId <= 0) return null;
    return user.userId.toString();
  }

  /// Checks a file_complaint.php reply and returns the saved complaint id (0 if the server did
  /// not send one). Throws with a readable message for a server refusal, an HTML fallback page
  /// or invalid JSON, so a failed submission can never be shown as a success.
  static int submissionResult(Response<dynamic> response) {
    final Map<String, dynamic> body =
        ApiGuard.requireSuccess(ApiGuard.jsonMap(response), fallback: 'The complaint could not be submitted.');
    return int.tryParse('${body['complaint_id'] ?? ''}') ?? 0;
  }

  /// A message that is safe and useful to show to a resident/admin.
  static String errorMessage(Object error) => ApiGuard.messageFor(error);
}
