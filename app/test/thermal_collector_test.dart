// Cycle 6 — Risk #4 (device limits / thermal) collector, pure Dart.
//
// Platform thermal values are normalized to the shared ThermalLevel enum BEFORE
// the collector sees them — that normalization is the contract between the
// (Cycle 7) platform channel and this collector, so it's tested exhaustively.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/metrics/thermal_collector.dart';

import 'support/fakes.dart';

void main() {
  group('thermal level normalization (platform → shared enum)', () {
    test('every iOS thermal state maps to the expected shared level', () {
      expect(thermalFromIos('nominal'), ThermalLevel.nominal);
      expect(thermalFromIos('fair'), ThermalLevel.fair);
      expect(thermalFromIos('serious'), ThermalLevel.serious);
      expect(thermalFromIos('critical'), ThermalLevel.critical);
    });

    test('every Android thermal status maps to the expected shared level', () {
      expect(thermalFromAndroid('none'), ThermalLevel.nominal);
      expect(thermalFromAndroid('light'), ThermalLevel.fair);
      expect(thermalFromAndroid('moderate'), ThermalLevel.serious);
      expect(thermalFromAndroid('severe'), ThermalLevel.serious);
      expect(thermalFromAndroid('critical'), ThermalLevel.critical);
    });

    test('an unknown platform value throws (fail loud, not silent)', () {
      expect(() => thermalFromIos('molten'), throwsArgumentError);
      expect(() => thermalFromAndroid('emergency'), throwsArgumentError);
    });
  });

  test('test_thermal_sampling', () {
    final t = ThermalCollector(clock: FakeClock(DateTime.utc(2026, 7, 10, 12)));
    t.recordCaptureStart();
    t.recordThermalState(ThermalLevel.fair);
    t.recordThermalState(ThermalLevel.serious);
    t.recordThermalState(ThermalLevel.fair); // max is monotonic, stays serious
    t.recordThermalPause();
    t.recordDroppedCapture();

    final m = t.toMetricsJson();
    expect(m['max_thermal_state'], 'serious');
    expect(m['thermal_pauses'], 1);
    expect(m['captures_dropped_thermal'], 1);
  });

  test('tracks the longest continuous capture via the injected clock', () {
    final clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    final t = ThermalCollector(clock: clock);

    // First run: 16 minutes, then a thermal pause.
    t.recordCaptureStart();
    clock.advance(const Duration(minutes: 16));
    t.recordThermalPause();

    // Second run: only 5 minutes.
    t.recordCaptureStart();
    clock.advance(const Duration(minutes: 5));
    t.recordThermalPause();

    expect(t.toMetricsJson()['longest_capture_mins'], 16);
  });
}
