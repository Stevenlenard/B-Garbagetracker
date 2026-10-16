import 'package:intl/intl.dart';

/// "Just now", "3 minutes ago", "1 hour ago", "Yesterday", "2 days ago", ...
///
/// Always computed from the PERSISTED notification timestamp (server milliseconds), so
/// the label is the same after a refresh or an app restart.
class RelativeTime {
  RelativeTime._();

  static String format(Object? timestampMs, {int? nowMs}) {
    final int? ts = timestampMs is num ? timestampMs.toInt() : int.tryParse('${timestampMs ?? ''}');
    if (ts == null || ts <= 0) return '';
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final int diff = now - ts;

    // Future stamps (device clock behind the server) are shown as "Just now".
    if (diff < 60 * 1000) return 'Just now';

    final int minutes = diff ~/ (60 * 1000);
    if (minutes < 60) return minutes == 1 ? '1 minute ago' : '$minutes minutes ago';

    final DateTime then = DateTime.fromMillisecondsSinceEpoch(ts);
    final DateTime nowDt = DateTime.fromMillisecondsSinceEpoch(now);
    final int hours = diff ~/ (60 * 60 * 1000);
    final DateTime today = DateTime(nowDt.year, nowDt.month, nowDt.day);
    final DateTime thenDay = DateTime(then.year, then.month, then.day);
    final int dayDiff = today.difference(thenDay).inDays;

    if (dayDiff == 0 && hours < 24) return hours == 1 ? '1 hour ago' : '$hours hours ago';
    if (dayDiff <= 1) return 'Yesterday';
    if (dayDiff < 7) return '$dayDiff days ago';
    return DateFormat('MMM d, yyyy').format(then);
  }
}
