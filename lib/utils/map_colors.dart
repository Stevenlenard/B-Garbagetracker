import 'package:flutter/painting.dart';

/// A colour for use INSIDE Mapbox style expressions (e.g. `["match", ...]`).
///
/// The Android Maps SDK accepts ARGB integers there, but Mapbox GL JS (web) requires a CSS
/// colour string and rejects numbers ("Expected color but found number"), which aborts the
/// layer setup and hides the markers on web. A CSS `rgba()` string works on both.
String mapColor(Color c) {
  final int argb = c.toARGB32();
  final int a = (argb >> 24) & 0xFF;
  final int r = (argb >> 16) & 0xFF;
  final int g = (argb >> 8) & 0xFF;
  final int b = argb & 0xFF;
  final String alpha = (a / 255).toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  return 'rgba($r, $g, $b, ${alpha.isEmpty ? '0' : alpha})';
}
