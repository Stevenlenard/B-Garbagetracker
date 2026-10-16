import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import 'service_area_service.dart';

/// Weekly collection schedule of one purok, set by the administrator. This is the ONLY source
/// of "usual collection days": nothing is guessed when an area has no schedule.
class CollectionSchedule {
  const CollectionSchedule({required this.area, required this.days, required this.time, this.note = ''});

  final String area;

  /// ISO weekdays, 1 = Monday ... 7 = Sunday (DateTime.weekday).
  final List<int> days;

  /// "HH:mm", 24-hour, Philippine time.
  final String time;
  final String note;

  static const List<String> dayNames = <String>['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const List<String> dayShort = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  bool get isEmpty => days.isEmpty;

  int get hour => int.tryParse(time.split(':').first) ?? 7;
  int get minute => time.contains(':') ? (int.tryParse(time.split(':')[1]) ?? 0) : 0;

  /// "7:00 AM"
  String get timeLabel {
    final int h = hour % 12 == 0 ? 12 : hour % 12;
    return '$h:${minute.toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
  }

  /// "Monday and Thursday", "every day"
  String get daysLabel {
    final List<int> d = (days.toSet().toList()..sort());
    if (d.length == 7) return 'every day';
    final List<String> n = d.map((int x) => dayNames[x - 1]).toList();
    if (n.length <= 1) return n.join();
    return '${n.sublist(0, n.length - 1).join(', ')} and ${n.last}';
  }

  /// "every Monday and Thursday, around 7:00 AM"
  String get summary => isEmpty ? 'no fixed schedule' : '${days.length == 7 ? 'every day' : 'every $daysLabel'}, around $timeLabel';

  /// Next collection at or after [from] (Philippine local time as given), or null.
  DateTime? nextAfter(DateTime from) {
    if (isEmpty) return null;
    for (int i = 0; i < 8; i++) {
      final DateTime day = DateTime(from.year, from.month, from.day + i, hour, minute);
      if (days.contains(day.weekday) && !day.isBefore(from)) return day;
    }
    return null;
  }

  Map<String, Object> toJson() => <String, Object>{
        'area': area,
        'days': (days.toSet().toList()..sort()),
        'time': time,
        'note': note,
        'updated_at': ServerValue.timestamp,
      };

  static CollectionSchedule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String area = (raw['area'] ?? '').toString().trim();
    if (area.isEmpty) return null;
    final Object? d = raw['days'];
    final List<int> days = <int>[
      if (d is List)
        for (final Object? x in d)
          if (int.tryParse('$x') case final int v when v >= 1 && v <= 7) v,
    ];
    final String time = (raw['time'] ?? '07:00').toString();
    return CollectionSchedule(area: area, days: days, time: RegExp(r'^\d{1,2}:\d{2}$').hasMatch(time) ? time : '07:00', note: (raw['note'] ?? '').toString());
  }
}

/// `collection_schedule/<key>` in Firebase. Admin writes; everyone (also the public page) reads.
class CollectionScheduleService {
  CollectionScheduleService._();

  static DatabaseReference get _ref => FirebaseDatabase.instance.ref('collection_schedule');

  /// Firebase keys cannot contain . # $ [ ] /
  static String keyFor(String area) => area.trim().replaceAll(RegExp(r'[.#$\[\]/]'), '_');

  /// Area name -> schedule (areas without a schedule are absent).
  static Stream<Map<String, CollectionSchedule>> watch() => _ref.onValue.map((DatabaseEvent e) => parse(e.snapshot.value));

  static Map<String, CollectionSchedule> parse(Object? raw) {
    final Map<String, CollectionSchedule> out = <String, CollectionSchedule>{};
    if (raw is Map) {
      for (final Object? v in raw.values) {
        final CollectionSchedule? s = CollectionSchedule.fromJson(v);
        if (s != null && !s.isEmpty) out[s.area] = s;
      }
    }
    return out;
  }

  /// The schedule for [purok], matching older short names ("Purok 1" = "Central (Purok 1)").
  static CollectionSchedule? forPurok(Map<String, CollectionSchedule> all, String? purok) {
    if (purok == null || purok.trim().isEmpty) return null;
    if (all[purok] != null) return all[purok];
    final String? c = ServiceAreaService.canonicalizeAreaName(purok);
    for (final CollectionSchedule s in all.values) {
      if (s.area.toLowerCase() == purok.toLowerCase() || (c != null && ServiceAreaService.canonicalizeAreaName(s.area) == c)) return s;
    }
    return null;
  }

  static Future<void> save(CollectionSchedule s) => _ref.child(keyFor(s.area)).set(s.toJson());

  static Future<void> remove(String area) => _ref.child(keyFor(area)).remove();
}
