// Cycle 6 — the feasibility collectors surface in TripPayload.metrics (Contract 2
// TripIn.metrics is additionalProperties: true, so no schema change), and the
// resulting trip still validates against the contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/metrics/capture_reliability_collector.dart';
import 'package:fsd_app/metrics/feasibility_metrics.dart';
import 'package:fsd_app/metrics/thermal_collector.dart';

import 'support/fakes.dart';
import 'support/openapi.dart';

void main() {
  test('feasibilityMetrics bundles both collectors under the agreed keys', () {
    final reliability = CaptureReliabilityCollector()
      ..recordTrigger(
        hasWindow: true,
        actualPreRoll: const Duration(seconds: 10),
        expectedPreRoll: const Duration(seconds: 10),
      );
    final thermal = ThermalCollector(clock: FakeClock(DateTime.utc(2026, 7, 10)))
      ..recordThermalState(ThermalLevel.fair);

    final metrics =
        feasibilityMetrics(reliability: reliability, thermal: thermal);

    expect(metrics['capture_reliability'], reliability.toMetricsJson());
    expect(metrics['thermal'], thermal.toMetricsJson());
  });

  test('metrics ride in TripPayload.metrics and still satisfy TripIn', () {
    final reliability = CaptureReliabilityCollector()
      ..recordTrigger(
        hasWindow: true,
        actualPreRoll: const Duration(seconds: 10),
        expectedPreRoll: const Duration(seconds: 10),
      );
    final thermal = ThermalCollector(clock: FakeClock(DateTime.utc(2026, 7, 10)))
      ..recordThermalState(ThermalLevel.serious);

    final trip = TripPayload(
      id: '55555555-5555-4555-8555-555555555555',
      userId: 'firebase-uid-1',
      provider: 'tesla',
      supervision: true,
      appConfigVersion: '1.0.0',
      startedAt: DateTime.utc(2026, 7, 10, 9),
      endedAt: DateTime.utc(2026, 7, 10, 9, 30),
      metrics: feasibilityMetrics(reliability: reliability, thermal: thermal),
    );

    final jsonMap = trip.toJson();
    final m = jsonMap['metrics'] as Map<String, dynamic>;
    expect(m['capture_reliability']['reliability'], 1.0);
    expect(m['thermal']['max_thermal_state'], 'serious');

    final result = contractValidator('TripIn').validate(jsonMap);
    expect(result.isValid, isTrue, reason: result.errors.join('\n'));
  });
}
