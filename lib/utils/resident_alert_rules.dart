import '../services/service_area_service.dart';
import 'complaint_flow.dart';

/// Which `notifications` records a resident receives, as a phone notification AND in the bell.
/// One rule for both, so they can never disagree.
class ResidentAlertRules {
  ResidentAlertRules._();

  /// Truck alerts aimed at a purok: staged approach (15/10/5 min), arrival, and the driver's
  /// manual "Alert residents" button.
  static const Set<String> truckAlertTypes = <String>{'auto_approach', 'auto_arrival', 'manual_alert'};

  static bool isFor(Map val, {required Object? residentId, required String? purok}) {
    final String type = (val['type'] ?? '').toString();
    final String target = (val['purok'] ?? val['area'] ?? '').toString();
    final String id = residentId?.toString() ?? '';
    // A driver's report update names the driver by id; resident and driver ids can collide.
    if (type == ComplaintFlow.typeIssueUpdate) return false;
    // Complaint In Progress / Resolved: only the complaining resident.
    if (ComplaintFlow.residentComplaintTypes.contains(type)) return (val['resident_id'] ?? '').toString() == id;
    if (truckAlertTypes.contains(type)) return target.trim().isEmpty || samePurok(target, purok);
    final String to = (val['resident_id'] ?? val['targetUserId'] ?? '').toString();
    return id.isNotEmpty && to == id;
  }

  /// "Purok 1" and "Central (Purok 1)" are the same area (older records used short names).
  static bool samePurok(String? a, String? b) {
    if (a == null || b == null) return false;
    if (a.trim().toLowerCase() == b.trim().toLowerCase()) return true;
    final String? ca = ServiceAreaService.canonicalizeAreaName(a);
    return ca != null && ca == ServiceAreaService.canonicalizeAreaName(b);
  }
}
