import 'package:flutter/material.dart';

import '../api/api_service.dart';

/// "Explain with AI" card of the Predictive Models dialog: the server's AI reads the evaluation numbers shown below it
/// (only numbers are sent) and explains, in English or Tagalog, what they mean, why, what to do next and how far the
/// models can be trusted. The predictions themselves stay statistical; the AI only interprets them. Runs on request.
class AiModelExplanation extends StatefulWidget {
  const AiModelExplanation({super.key, required this.arrival, required this.load, this.api});

  final Map<String, num> arrival;
  final Map<String, num> load;
  final ApiService? api;

  @override
  State<AiModelExplanation> createState() => _AiModelExplanationState();
}

class _AiModelExplanationState extends State<AiModelExplanation> {
  static const Color _violet = Color(0xFF6D28D9);
  static const Color _ink = Color(0xFF0F172A);
  static const Color _muted = Color(0xFF64748B);

  String _lang = 'en';
  bool _loading = false;
  Map<String, dynamic>? _result;
  String? _error;

  bool get _tl => _lang == 'tl';

  Future<void> _explain() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Object? data = (await (widget.api ?? ApiService())
              .explainPredictiveModels(<String, dynamic>{'lang': _lang, 'arrival': widget.arrival, 'load': widget.load}))
          .data;
      if (!mounted) return;
      if (data is Map && data['success'] == true && data['ai'] == true) {
        setState(() => _result = Map<String, dynamic>.from(data));
      } else {
        setState(() => _error = _tl
            ? 'Hindi available ang AI ngayon. Subukan ulit pagkalipas ng ilang minuto.'
            : 'The AI is not available right now. Try again in a few minutes.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = _tl ? 'Hindi makakonekta sa server. Subukan ulit.' : 'Could not reach the server. Try again.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF7FF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFDDD6FE)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          const Icon(Icons.auto_awesome_rounded, color: _violet, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_tl ? 'Ipaliwanag gamit ang AI' : 'Explain with AI',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: _ink)),
          ),
          _langChip('English', 'en'),
          const SizedBox(width: 6),
          _langChip('Tagalog', 'tl'),
        ]),
        const SizedBox(height: 4),
        Text(
          _tl
              ? 'Simpleng paliwanag ng mga numero sa ibaba. Ang mga prediction mismo ay kinompyut ng mga model, hindi ng AI.'
              : 'A plain-language reading of the numbers below. The predictions themselves are computed by the models, not by the AI.',
          style: const TextStyle(fontSize: 12, color: _muted, height: 1.4),
        ),
        const SizedBox(height: 12),
        if (_result == null || _loading)
          ElevatedButton.icon(
            onPressed: _loading ? null : _explain,
            style: ElevatedButton.styleFrom(
              backgroundColor: _violet,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: _loading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_awesome_rounded, size: 18),
            label: Text(_loading ? (_tl ? 'Nagpapaliwanag…' : 'Explaining…') : (_tl ? 'Ipaliwanag' : 'Explain')),
          ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C))),
        ],
        if (_result != null && !_loading) ...<Widget>[
          if (_result!['arrival'] is Map) _model(_tl ? 'Oras ng pagdating ng truck' : 'Arrival time', _result!['arrival'] as Map),
          if (_result!['load'] is Map) _model(_tl ? 'Dami ng nakolektang basura' : 'Collected load', _result!['load'] as Map),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _explain,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(_tl ? 'Ipaliwanag ulit' : 'Explain again'),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _langChip(String label, String code) {
    final bool on = _lang == code;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _loading || on
          ? null
          : () => setState(() {
                _lang = code;
                _result = null; // the next explanation is written in the chosen language
                _error = null;
              }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: on ? _violet : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on ? _violet : const Color(0xFFDDD6FE)),
        ),
        child: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: on ? Colors.white : _violet)),
      ),
    );
  }

  Widget _model(String title, Map m) {
    final String rel = (m['reliability'] ?? 'low').toString();
    final (String relLabel, Color relColor) = switch (rel) {
      'high' => (_tl ? 'Mataas' : 'High', const Color(0xFF15803D)),
      'medium' => (_tl ? 'Katamtaman' : 'Medium', const Color(0xFFD97706)),
      _ => (_tl ? 'Mababa' : 'Low', const Color(0xFFB91C1C)),
    };
    final List<String> next = <String>[for (final Object? s in (m['next'] is List ? m['next'] as List : const <Object?>[])) '$s'];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFEDE9FE))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: _ink)),
        _part(_tl ? 'ANO ANG IBIG SABIHIN' : 'WHAT IT MEANS', '${m['meaning'] ?? ''}'),
        if ('${m['why'] ?? ''}'.isNotEmpty) _part(_tl ? 'BAKIT GANITO' : 'WHY', '${m['why']}'),
        if (next.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(_tl ? 'ANO ANG DAPAT GAWIN' : 'WHAT TO DO NEXT', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _violet)),
          for (int i = 0; i < next.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                SizedBox(width: 18, child: Text('${i + 1}.', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _violet))),
                Expanded(child: Text(next[i], style: const TextStyle(fontSize: 12.5, color: _ink, height: 1.45))),
              ]),
            ),
        ],
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(_tl ? 'GAANO KAASAHAN NGAYON  ' : 'HOW RELIABLE NOW  ',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _violet)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(color: relColor.withAlpha(25), borderRadius: BorderRadius.circular(6)),
            child: Text(relLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: relColor)),
          ),
        ]),
        if ('${m['reliability_note'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${m['reliability_note']}', style: const TextStyle(fontSize: 12.5, color: _muted, height: 1.45)),
          ),
      ]),
    );
  }

  Widget _part(String label, String text) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _violet)),
          const SizedBox(height: 2),
          Text(text, style: const TextStyle(fontSize: 12.5, color: _ink, height: 1.45)),
        ]),
      );
}
