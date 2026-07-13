// lib/metrics/feasibility_metrics.dart
//
// Cycle 6 — bundle the two Person-B feasibility collectors into the map that
// rides in TripPayload.metrics (Contract 2 TripIn.metrics is additionalProperties,
// so this persists into Person A's trips.metrics jsonb with no schema change).

import 'capture_reliability_collector.dart';
import 'thermal_collector.dart';

Map<String, dynamic> feasibilityMetrics({
  required CaptureReliabilityCollector reliability,
  required ThermalCollector thermal,
}) =>
    {
      'capture_reliability': reliability.toMetricsJson(),
      'thermal': thermal.toMetricsJson(),
    };
