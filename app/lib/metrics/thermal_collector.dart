// lib/metrics/thermal_collector.dart
//
// Cycle 6 — Risk #4 (device limits / thermal) metric. Pure Dart; real thermal
// readings arrive via a platform channel in Cycle 7.
//
// Platform thermal values are normalized to [ThermalLevel] BEFORE the collector
// sees them — that mapping is the contract between platform code and this
// collector (tested exhaustively). iOS is 1:1; Android's 5 states fold to 4 so
// that shared `critical` means the same "imminent" state on both platforms,
// which is exactly what the "no critical" go/no-go threshold checks.

import '../capture/ports.dart';

/// The shared, cross-platform thermal scale (mirrors iOS's ProcessInfo states).
enum ThermalLevel { nominal, fair, serious, critical }

/// Streams the device's (already normalized) thermal state. Real impl reads the
/// Android PowerManager thermal status / iOS ProcessInfo.thermalState; tests use
/// a fake. Feed each value into a [ThermalCollector].
abstract class ThermalSource {
  Stream<ThermalLevel> states();
}

/// iOS `ProcessInfo.thermalState` → shared level (1:1).
ThermalLevel thermalFromIos(String raw) => switch (raw) {
      'nominal' => ThermalLevel.nominal,
      'fair' => ThermalLevel.fair,
      'serious' => ThermalLevel.serious,
      'critical' => ThermalLevel.critical,
      _ => throw ArgumentError('unknown iOS thermal state: $raw'),
    };

/// Android `PowerManager` thermal status → shared level (5 → 4 fold).
ThermalLevel thermalFromAndroid(String raw) => switch (raw) {
      'none' => ThermalLevel.nominal,
      'light' => ThermalLevel.fair,
      'moderate' => ThermalLevel.serious,
      'severe' => ThermalLevel.serious,
      'critical' => ThermalLevel.critical,
      _ => throw ArgumentError('unknown Android thermal status: $raw'),
    };

class ThermalCollector {
  ThermalCollector({this.clock = const SystemClock()});

  final Clock clock;

  ThermalLevel _maxSeen = ThermalLevel.nominal;
  int _droppedCaptures = 0;
  int _thermalPauses = 0;
  Duration _longestCapture = Duration.zero;
  DateTime? _captureStarted;

  ThermalLevel get maxThermalState => _maxSeen;

  /// Record a (normalized) thermal reading; tracks the max seen.
  void recordThermalState(ThermalLevel level) {
    if (level.index > _maxSeen.index) _maxSeen = level;
  }

  /// Begin a continuous capture window (no-op if one is already open).
  void recordCaptureStart() => _captureStarted ??= clock.now();

  /// A thermal gate paused capture; closes the current window and tracks the
  /// longest run.
  void recordThermalPause() {
    _thermalPauses++;
    final started = _captureStarted;
    if (started != null) {
      final run = clock.now().difference(started);
      if (run > _longestCapture) _longestCapture = run;
      _captureStarted = null;
    }
  }

  /// A trigger fired but capture was suppressed by the thermal gate.
  void recordDroppedCapture() => _droppedCaptures++;

  Map<String, dynamic> toMetricsJson() => {
        'max_thermal_state': _maxSeen.name,
        'thermal_pauses': _thermalPauses,
        'captures_dropped_thermal': _droppedCaptures,
        'longest_capture_mins': _longestCapture.inMinutes,
      };
}
