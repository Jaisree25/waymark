// lib/metrics/platform_thermal_source.dart
//
// Cycle 10d — the real ThermalSource. Device only; tests use FakeThermalSource.
//
// TODO(device): read the platform thermal state via a MethodChannel — Android
// PowerManager.getCurrentThermalStatus(), iOS ProcessInfo.thermalState — and map
// each reading with thermalFromAndroid/thermalFromIos before emitting. Until that
// native channel exists this emits a single `nominal` reading so the collector
// runs; the risk-#4 "no critical" go/no-go needs the real channel to be meaningful.

import 'thermal_collector.dart';

class PlatformThermalSource implements ThermalSource {
  const PlatformThermalSource();

  @override
  Stream<ThermalLevel> states() => Stream<ThermalLevel>.value(ThermalLevel.nominal);
}
