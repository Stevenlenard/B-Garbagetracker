import 'package:flutter/material.dart';

import '../services/ai_actions_service.dart';
import '../utils/complaint_flow.dart';

const Color _teal = Color(0xFF00897B);
const Color _ink = Color(0xFF1A1A1A);

Color _priorityColor(String p) {
  switch (p) {
    case 'high':
      return const Color(0xFFE53935);
    case 'low':
      return const Color(0xFF43A047);
    default:
      return const Color(0xFFF57C00);
  }
}

String _ids(List<int> ids) => ids.map((int i) => ComplaintFlow.displayId('$i')).join(', ');

Widget _part(String label, String text) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text.rich(TextSpan(children: <InlineSpan>[
        TextSpan(text: '$label  ', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _teal)),
        TextSpan(text: text, style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.4)),
      ])),
    );

/// AI-suggested actions from the open resident complaints (Analytics, "Actions" tab).
/// Shows nothing when no AI answer is available, so only the rule-based recommendations remain.
class AiSuggestedActionsPanel extends StatefulWidget {
  const AiSuggestedActionsPanel({super.key, this.area});

  /// "All Areas" or one area name; other areas' actions are left out.
  final String? area;

  @override
  State<AiSuggestedActionsPanel> createState() => _AiSuggestedActionsPanelState();
}

class _AiSuggestedActionsPanelState extends State<AiSuggestedActionsPanel> {
  late Future<AiActionsResult?> _future = AiActionsService.load();

  bool _inArea(AiAction a) {
    final String? area = widget.area;
    if (area == null || area == 'All Areas') return true;
    final String p = a.purok.toLowerCase(), s = area.toLowerCase();
    return p.contains(s) || s.contains(p);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AiActionsResult?>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<AiActionsResult?> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Row(children: <Widget>[
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _teal)),
              SizedBox(width: 10),
              Text('Reading the open complaints…', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
            ]),
          );
        }
        final List<AiAction> actions = (snap.data?.actions ?? const <AiAction>[]).where(_inArea).toList();
        if (actions.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(children: <Widget>[
                const Icon(Icons.auto_awesome_rounded, size: 18, color: _teal),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('AI-suggested actions', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: _ink)),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: _teal),
                  onPressed: () => setState(() => _future = AiActionsService.load(refresh: true)),
                ),
              ]),
              Text('From the open resident complaints and the last 60 days of resolved ones. Review before acting.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
              const SizedBox(height: 12),
              if ((snap.data?.summary ?? '').isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(14)),
                  child: Text.rich(TextSpan(children: <InlineSpan>[
                    const TextSpan(text: 'SITUATION  ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _teal)),
                    TextSpan(text: snap.data!.summary, style: const TextStyle(fontSize: 12.5, color: _ink, height: 1.45)),
                  ])),
                ),
              for (final AiAction a in actions) _ActionCard(a),
            ],
          ),
        );
      },
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard(this.a);

  final AiAction a;

  @override
  Widget build(BuildContext context) {
    final Color pc = _priorityColor(a.priority);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FBFA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFB2DFDB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(children: <Widget>[
            Expanded(
              child: Text(a.purok.isEmpty ? 'Area not specified' : a.purok,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _teal)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: pc.withAlpha(25), borderRadius: BorderRadius.circular(6)),
              child: Text(a.priority.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: pc)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(a.action, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink, height: 1.35)),
          if (a.reason.isNotEmpty) _part('WHY', a.reason),
          if (a.steps.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            const Text('STEPS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _teal)),
            for (int i = 0; i < a.steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  SizedBox(width: 18, child: Text('${i + 1}.', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _teal))),
                  Expanded(child: Text(a.steps[i], style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.4))),
                ]),
              ),
          ],
          if (a.outcome.isNotEmpty) _part('EXPECTED RESULT', a.outcome),
          const SizedBox(height: 8),
          Text('Based on complaint ${_ids(a.complaintIds)}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// The AI-suggested action for one open resident complaint (Complaint Center details), if there is one.
class AiComplaintSuggestion extends StatelessWidget {
  const AiComplaintSuggestion({super.key, required this.complaintId});

  final String complaintId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AiActionsResult?>(
      future: AiActionsService.load(),
      builder: (BuildContext context, AsyncSnapshot<AiActionsResult?> snap) {
        final AiAction? a = snap.data?.forComplaint(complaintId);
        if (a == null) return const SizedBox.shrink();
        final Color pc = _priorityColor(a.priority);
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF4FBFA),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFB2DFDB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(children: <Widget>[
                const Icon(Icons.auto_awesome_rounded, size: 16, color: _teal),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('AI-SUGGESTED ACTION', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _teal, letterSpacing: 1)),
                ),
                Text(a.priority.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: pc)),
              ]),
              const SizedBox(height: 6),
              Text(a.action, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink, height: 1.35)),
              if (a.reason.isNotEmpty) _part('WHY', a.reason),
              for (int i = 0; i < a.steps.length; i++) _part(i == 0 ? 'STEPS  1.' : '${i + 1}.', a.steps[i]),
              if (a.outcome.isNotEmpty) _part('EXPECTED RESULT', a.outcome),
              if (a.complaintIds.length > 1) ...<Widget>[
                const SizedBox(height: 6),
                Text('Also covers ${_ids(a.complaintIds.where((int i) => '$i' != complaintId).toList())}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 4),
              Text('Review before acting.', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ),
        );
      },
    );
  }
}
