import 'package:flutter/foundation.dart';

import '../api/api_service.dart';

/// One AI-suggested action, based on one or more open resident complaints.
class AiAction {
  const AiAction({required this.purok, required this.priority, required this.action, required this.reason, required this.complaintIds});

  final String purok;
  final String priority; // high | medium | low
  final String action;
  final String reason;
  final List<int> complaintIds;

  static AiAction? fromJson(Object? j) {
    if (j is! Map) return null;
    final List<int> ids = <int>[
      for (final Object? id in (j['complaint_ids'] is List ? j['complaint_ids'] as List : const <Object?>[]))
        if (int.tryParse('$id') != null) int.parse('$id'),
    ];
    final String action = (j['action'] ?? '').toString().trim();
    if (ids.isEmpty || action.isEmpty) return null;
    return AiAction(
      purok: (j['purok'] ?? '').toString().trim(),
      priority: (j['priority'] ?? 'medium').toString(),
      action: action,
      reason: (j['reason'] ?? '').toString().trim(),
      complaintIds: ids,
    );
  }
}

class AiActionsResult {
  const AiActionsResult({required this.actions, required this.openCount});

  final List<AiAction> actions;
  final int openCount;

  /// The suggestion for one resident complaint (its id as shown in the Complaint Center), if any.
  AiAction? forComplaint(String id) {
    final int? n = int.tryParse(id.replaceAll(RegExp(r'\D'), ''));
    if (n == null) return null;
    for (final AiAction a in actions) {
      if (a.complaintIds.contains(n)) return a;
    }
    return null;
  }
}

/// Loads the AI-suggested actions once and shares them between the Analytics "Actions" tab and the
/// Complaint Center, so opening both pages costs a single request. The server caches the AI answer too.
class AiActionsService {
  AiActionsService._();

  static const Duration _fresh = Duration(minutes: 10);
  static Future<AiActionsResult?>? _pending;
  static DateTime? _loadedAt;

  /// Null when there is no AI answer (not configured, limit reached, offline): the pages then show
  /// only their rule-based recommendations.
  static Future<AiActionsResult?> load({bool refresh = false, ApiService? api}) {
    final DateTime? at = _loadedAt;
    if (!refresh && _pending != null && (at == null || DateTime.now().difference(at) < _fresh)) return _pending!;
    _loadedAt = null;
    return _pending = _fetch(api ?? ApiService()).then((AiActionsResult? r) {
      _loadedAt = DateTime.now();
      return r;
    });
  }

  /// After a complaint changes status, the next load asks the server again.
  static void invalidate() {
    _pending = null;
    _loadedAt = null;
  }

  static Future<AiActionsResult?> _fetch(ApiService api) async {
    try {
      final Object? data = (await api.getAiActions()).data;
      if (data is! Map || data['success'] != true || data['ai'] != true) return null;
      final List<AiAction> actions = <AiAction>[
        for (final Object? a in (data['actions'] is List ? data['actions'] as List : const <Object?>[]))
          if (AiAction.fromJson(a) != null) AiAction.fromJson(a)!,
      ];
      if (actions.isEmpty) return null;
      return AiActionsResult(actions: actions, openCount: int.tryParse('${data['open_count']}') ?? 0);
    } catch (e) {
      debugPrint('AI actions unavailable: $e');
      return null;
    }
  }
}
