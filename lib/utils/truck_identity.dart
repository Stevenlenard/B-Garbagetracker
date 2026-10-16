import 'package:flutter/material.dart';

/// Stable visual identity of a truck on every map (Admin live, Resident live, Route
/// History, dashboard map).
///
/// Identity colour comes ONLY from the truck id - never from list position, status or
/// who is online - so GT-007 has the same colour everywhere, always. Operational status
/// is a separate channel (marker ring + label text), see [statusHex].
class TruckIdentity {
  TruckIdentity._();

  /// 16 well separated colours. Consecutive truck numbers (GT-007, GT-008, ...) always
  /// map to different entries, so neighbouring units never share a colour.
  static const List<String> palette = <String>[
    '#1E88E5', // blue
    '#8E24AA', // purple
    '#F4511E', // deep orange
    '#00897B', // teal
    '#D81B60', // pink
    '#3949AB', // indigo
    '#6D4C41', // brown
    '#7CB342', // light green
    '#FB8C00', // orange
    '#00ACC1', // cyan
    '#5E35B1', // deep purple
    '#C0CA33', // lime
    '#546E7A', // blue grey
    '#E53935', // red
    '#43A047', // green
    '#FDD835', // yellow
  ];

  static String normalize(String truckId) => truckId.trim().toUpperCase();

  static int _fnv(String text) {
    int h = 0x811C9DC5;
    for (final int c in text.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }

  /// Palette slot for [truckId]: hash of the id prefix + its trailing number.
  static int index(String truckId) {
    final String id = normalize(truckId);
    final RegExpMatch? m = RegExp(r'^(.*?)(\d+)$').firstMatch(id);
    if (m == null) return _fnv(id) % palette.length;
    final int number = int.tryParse(m.group(2)!) ?? 0;
    return (_fnv(m.group(1)!) + number) % palette.length;
  }

  static String hex(String truckId) => palette[index(truckId)];

  static int argb(String truckId) => 0xFF000000 | int.parse(hex(truckId).substring(1), radix: 16);

  static Color color(String truckId) => Color(argb(truckId));

  /// Ring / text colour for an operational status (kept apart from identity colour).
  static String statusHex(String status) {
    switch (status.trim().toUpperCase()) {
      case 'ACTIVE':
      case 'COLLECTING':
        return '#2E7D32';
      case 'IDLE':
      case 'PAUSED':
        return '#EF6C00';
      case 'FULL':
        return '#C62828';
      case 'COMPLETED':
      case 'FINISHED':
        return '#1565C0';
      default:
        return '#455A64';
    }
  }

  /// Feature properties every truck marker carries (all strings: GeoJSON property maps
  /// are often inferred as Map<String, String>; map expressions use `to-number`).
  static Map<String, String> markerProps(String truckId, String status) => <String, String>{
        'truckColor': hex(truckId),
        'statusColor': statusHex(status),
        'radius': '10',
        'sortKey': '90',
      };

  /// Is [id] black/white text friendlier on this identity colour? (legend chips)
  static bool isLight(String truckId) {
    final Color c = color(truckId);
    return c.computeLuminance() > 0.6;
  }
}
