// Cycle 6 — Risk #1 (capture reliability) collector, pure Dart.
//
// reliability = complete / attempted, where a trigger is:
//   * empty    — the ring buffer had no window at trigger time;
//   * partial  — the pre-roll was < 90% of expected (an early-in-trip trigger);
//   * complete — a full (>= 90%) pre-roll window.
// Partial rows are their OWN bucket and never count toward the numerator.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/metrics/capture_reliability_collector.dart';

void main() {
  test('test_capture_reliability_metric', () {
    final c = CaptureReliabilityCollector();
    c.recordTrigger(
      hasWindow: true,
      actualPreRoll: const Duration(seconds: 10),
      expectedPreRoll: const Duration(seconds: 10),
    ); // complete
    c.recordTrigger(
      hasWindow: true,
      actualPreRoll: const Duration(seconds: 3),
      expectedPreRoll: const Duration(seconds: 10),
    ); // partial (< 90%)
    c.recordTrigger(
      hasWindow: false,
      actualPreRoll: Duration.zero,
      expectedPreRoll: const Duration(seconds: 10),
    ); // empty

    expect(c.reliability, closeTo(1 / 3, 0.01)); // 1 complete of 3 attempted
    final m = c.toMetricsJson();
    expect(m['attempted'], 3);
    expect(m['complete'], 1);
    expect(m['partial'], 1);
    expect(m['empty'], 1);
  });

  test('test_partial_preroll_excluded_from_reliability_numerator', () {
    final c = CaptureReliabilityCollector();
    // 9 complete windows...
    for (var i = 0; i < 9; i++) {
      c.recordTrigger(
        hasWindow: true,
        actualPreRoll: const Duration(seconds: 10),
        expectedPreRoll: const Duration(seconds: 10),
      );
    }
    // ...and 1 partial pre-roll (early-in-trip trigger, < 90%).
    c.recordTrigger(
      hasWindow: true,
      actualPreRoll: const Duration(seconds: 3),
      expectedPreRoll: const Duration(seconds: 10),
    );

    final m = c.toMetricsJson();
    expect(m['attempted'], 10);
    expect(m['complete'], 9);
    expect(m['partial'], 1);
    // The partial is its own bucket and is NOT in the numerator:
    // reliability = complete / attempted = 9/10, NOT 10/10.
    expect(c.reliability, closeTo(0.9, 1e-9));
  });

  test('90% pre-roll boundary: exactly 90% is complete, just under is partial',
      () {
    final c = CaptureReliabilityCollector();
    c.recordTrigger(
      hasWindow: true,
      actualPreRoll: const Duration(seconds: 9), // exactly 90% → complete
      expectedPreRoll: const Duration(seconds: 10),
    );
    c.recordTrigger(
      hasWindow: true,
      actualPreRoll: const Duration(milliseconds: 8999), // < 90% → partial
      expectedPreRoll: const Duration(seconds: 10),
    );
    final m = c.toMetricsJson();
    expect(m['complete'], 1);
    expect(m['partial'], 1);
  });

  test('reliability is 0 with no triggers', () {
    expect(CaptureReliabilityCollector().reliability, 0);
  });
}
