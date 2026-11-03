import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// A text that follows a [ValueListenable] (the clock, a countdown) and rebuilds ONLY itself when it changes.
///
/// The dashboards used to call `setState` on the whole screen twice a second for the clock (and every second for the ETA
/// countdown): every card, list and map widget of a 3000-line screen was rebuilt for a few characters of text.
class ClockText extends StatelessWidget {
  const ClockText(this.time, {super.key, this.style});

  final ValueListenable<String> time;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: time,
        builder: (BuildContext _, String t, Widget? __) => Text(t, style: style),
      );
}
