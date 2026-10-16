import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// Development-only timing instrumentation for the live tracking pipeline.
///
/// Active ONLY when the app runs in explicit test mode AND `GT_TELEMETRY=true`
/// (see [AppConfig]); otherwise every method returns immediately, so production
/// behaviour is unchanged.
///
/// Privacy: log lines contain only the telemetry role, truck IDs, sequence numbers
/// and millisecond durations. No coordinates, names or credentials are ever logged.
///
/// Clock handling: delivery delay is computed against the Firebase server clock
/// (`lastSeen` is a server timestamp; the local clock is corrected with
/// `.info/serverTimeOffset`), so it does not depend on devices having synchronized
/// clocks. Durations inside one process use [Stopwatch] (monotonic).
class TrackingTelemetry {
  TrackingTelemetry._();

  static bool get enabled => AppConfig.isTestMode && AppConfig.telemetryRequested;

  static int _seq = 0;
  static int _serverOffsetMs = 0;
  static StreamSubscription? _offsetSub;

  static const int _summaryEvery = 30;
  static final Map<String, List<int>> _samples = {};
  static final Map<String, int> _lastSeq = {};
  static final Map<String, String> _lastStatus = {};

  /// Sequence numbers never observed by a consumer (Firebase may coalesce rapid writes).
  static int seqGaps = 0;
  static int outOfOrder = 0;
  static int coalescedMarkerUpdates = 0;

  /// Next driver-side event number (published as `dbg_seq`, test mode only).
  static int nextSeq() => ++_seq;

  /// Starts reading the built-in server clock offset. Safe to call more than once.
  static void init() {
    if (!enabled) return;
    _offsetSub?.cancel();
    _offsetSub = FirebaseDatabase.instance.ref('.info/serverTimeOffset').onValue.listen((event) {
      final Object? v = event.snapshot.value;
      if (v is num) _serverOffsetMs = v.toInt();
    });
    _log('init');
  }

  // ---- driver side ---------------------------------------------------------

  /// T0→T1 (processing) and T1→T2 (server acknowledgement) for one published fix.
  static void driverPublished({required int seq, required int processMs, required int ackMs}) {
    if (!enabled) return;
    _record('driver_process_ms', processMs);
    _record('driver_ack_ms', ackMs);
    if (seq % 10 == 0) _log('driver seq=$seq process_ms=$processMs ack_ms=$ackMs');
  }

  // ---- consumer side -------------------------------------------------------

  /// Call with the raw `truck_locations` snapshot value as soon as it is received.
  static void onTruckLocations(Object? raw, {required String source}) {
    if (!enabled || raw is! Map) return;
    final int nowServer = DateTime.now().millisecondsSinceEpoch + _serverOffsetMs;
    raw.forEach((key, node) {
      if (node is! Map) return;
      final String id = key.toString();
      final String k = '$source|$id';
      final dynamic ls = node['lastSeen'];
      final int lastSeen = ls is num ? ls.toInt() : 0;
      final String status = (node['status'] ?? '').toString();

      final String? prevStatus = _lastStatus[k];
      if (prevStatus != null && prevStatus != status) {
        final int delivery = lastSeen > 0 ? nowServer - lastSeen : -1;
        _log('status_change source=$source truck=$id from=$prevStatus to=$status delivery_ms=$delivery');
        if (delivery >= 0) _record('status_delivery_ms:$source', delivery);
      }
      _lastStatus[k] = status;

      final dynamic s = node['dbg_seq'];
      if (s is! num) return;
      final int seq = s.toInt();
      final int? prev = _lastSeq[k];
      if (prev == seq) return; // snapshot unchanged for this truck
      if (prev != null) {
        if (seq < prev) {
          outOfOrder++;
          _log('out_of_order source=$source truck=$id seq=$seq prev=$prev');
        } else if (seq > prev + 1) {
          seqGaps += seq - prev - 1;
        }
      }
      _lastSeq[k] = seq;
      if (lastSeen > 0) _record('delivery_ms:$source', nowServer - lastSeen);
    });
  }

  /// A map marker update finished (T4/T6): milliseconds spent updating the map.
  static void onMarkersRendered({required String source, required int ms}) {
    if (!enabled) return;
    _record('marker_update_ms:$source', ms);
  }

  /// A newer truck snapshot replaced a pending one while an update was running.
  static void onCoalesced({required String source}) {
    if (!enabled) return;
    coalescedMarkerUpdates++;
    if (coalescedMarkerUpdates % 10 == 0) {
      _log('coalesced_marker_updates=$coalescedMarkerUpdates source=$source');
    }
  }

  /// Fleet/active-count cards: milliseconds from event receipt to the next frame (S4).
  static void onFleetRendered({required String source, required int ms}) {
    if (!enabled) return;
    _record('fleet_card_ms:$source', ms);
  }

  // ---- statistics ----------------------------------------------------------

  static void _record(String metric, int ms) {
    final List<int> list = _samples.putIfAbsent(metric, () => <int>[]);
    list.add(ms);
    if (list.length % _summaryEvery == 0) {
      _log('summary metric=$metric ${summarize(list)} seq_gaps=$seqGaps out_of_order=$outOfOrder');
    }
  }

  /// `n`, `min`, `median`, `p95`, `max` of the samples (milliseconds).
  static Map<String, int> stats(List<int> samples) {
    if (samples.isEmpty) return const {'n': 0, 'min': 0, 'median': 0, 'p95': 0, 'max': 0};
    final List<int> s = List<int>.from(samples)..sort();
    int pct(double p) => s[math.min(s.length - 1, math.max(0, (p * s.length).ceil() - 1))];
    return {'n': s.length, 'min': s.first, 'median': pct(0.5), 'p95': pct(0.95), 'max': s.last};
  }

  static String summarize(List<int> samples) {
    final Map<String, int> st = stats(samples);
    return 'n=${st['n']} min=${st['min']} median=${st['median']} p95=${st['p95']} max=${st['max']}';
  }

  static void _log(String message) {
    debugPrint('[GT_TELEM] role=${AppConfig.telemetryRole} $message');
  }
}
