// Cycle 10d — feasibility metrics wiring. Reliability (one complete per assembled
// event) + thermal (from a ThermalSource) are collected during a trip and written
// into the trip payload's metrics on endTrip.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/capture_controller.dart';
import 'package:fsd_app/capture/event.dart';
import 'package:fsd_app/capture/keyword_config.dart';
import 'package:fsd_app/capture/location_tracker.dart';
import 'package:fsd_app/capture/trip_controller.dart';
import 'package:fsd_app/metrics/thermal_collector.dart';
import 'package:fsd_app/store/app_database.dart';

import 'support/capture_fakes.dart';
import 'support/fakes.dart';

void main() {
  late FakeClock clock;
  late AppDatabase db;
  late TripController trip;
  late FakeTriggerPipeline trigger;
  var idSeq = 0;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    db = AppDatabase(NativeDatabase.memory(), clock: clock);
    trip = TripController(clock: clock);
    trigger = FakeTriggerPipeline();
    idSeq = 0;
  });

  tearDown(() async {
    await trigger.dispose();
    await db.close();
  });

  CaptureController build({
    LocationTracker? tracker,
    ThermalSource? thermal,
  }) =>
      CaptureController(
        trip: trip,
        trigger: trigger,
        uploader: FakeUploader(),
        db: db,
        clock: clock,
        chime: FakeChimePlayer(),
        blobStore: FakeBlobStore(),
        permissions: FakePermissionRequester(),
        locationTracker:
            tracker ?? LocationTracker(FakeLocationSource(const [])),
        thermalSource: thermal ?? FakeThermalSource(const [ThermalLevel.fair]),
        tripConfig: const TripStartConfig(
          userId: 'firebase-uid-1',
          provider: 'tesla',
          supervision: true,
          appVersion: '1.0.0+1',
          configVersion: '1.0.0',
        ),
        generateId: () => 'gen-${idSeq++}',
      );

  Event voiceEvent(String keyword) => Event(
        tTrigger: clock.now(),
        triggerSource: 'voice',
        eventType: 'incident',
        severity: severityForKeyword(keyword),
        keyword: keyword,
        tPreSeconds: 15,
        tPostSeconds: 8,
        audioWindow: [audioFrame(1), audioFrame(2)],
      );

  Map<String, dynamic> tripMetrics(Map<String, dynamic> tripJson) =>
      tripJson['metrics'] as Map<String, dynamic>;

  test('test_thermal_source_feeds_collector', () async {
    final collector = ThermalCollector();
    await FakeThermalSource(const [ThermalLevel.serious])
        .states()
        .forEach(collector.recordThermalState);
    expect(collector.maxThermalState, ThermalLevel.serious);
  });

  test('test_no_thermal_critical_guard', () async {
    final collector = ThermalCollector();
    await FakeThermalSource(
      const [ThermalLevel.fair, ThermalLevel.critical, ThermalLevel.serious],
    ).states().forEach(collector.recordThermalState);
    // max is monotonic → critical is retained (device go/no-go threshold testable).
    expect(collector.maxThermalState, ThermalLevel.critical);
  });

  test('test_metrics_in_trip_payload', () async {
    final controller = build(thermal: FakeThermalSource(const [ThermalLevel.fair]));
    addTearDown(controller.dispose);

    await controller.startTrip();
    trigger.fire(voiceEvent('mark level three'));
    trigger.fire(voiceEvent('mark level four'));
    await pumpEventQueue();
    await controller.endTrip();

    final tripJson =
        jsonDecode((await db.allTrips()).single.payloadJson) as Map<String, dynamic>;
    final metrics = tripMetrics(tripJson);

    final reliability = metrics['capture_reliability'] as Map<String, dynamic>;
    expect(reliability['reliability'], 1.0); // 2 complete / 2 attempted
    expect(
      reliability['reliability_note'],
      'assembled_events_only_partials_not_counted',
    );
    expect((metrics['thermal'] as Map)['max_thermal_state'], isNotNull);
  });

  test('test_combined_endtrip_postcondition', () async {
    final source = FakeLocationSource([
      gpsFix(37.77, -122.41),
      gpsFix(37.78, -122.42),
      gpsFix(37.79, -122.43),
    ]);
    final controller = build(tracker: LocationTracker(source));
    addTearDown(controller.dispose);

    await controller.startTrip();
    await pumpEventQueue(); // 3 fixes
    trigger.fire(voiceEvent('mark level three'));
    trigger.fire(voiceEvent('mark level four'));
    await pumpEventQueue();
    await controller.endTrip();

    // 1 closed trip row with metrics
    final trips = await db.allTrips();
    expect(trips, hasLength(1));
    final tripJson = jsonDecode(trips.single.payloadJson) as Map<String, dynamic>;
    expect(tripJson['ended_at'], isNotNull);
    expect(
      (tripMetrics(tripJson)['capture_reliability'] as Map)['reliability'],
      1.0,
    );

    // 1 breadcrumb row with 3 [lon,lat] coordinate pairs
    final breadcrumbs = await db.allBreadcrumbs();
    expect(breadcrumbs, hasLength(1));
    final track = (jsonDecode(breadcrumbs.single.payloadJson)
        as Map<String, dynamic>)['track'] as Map<String, dynamic>;
    final coords = track['coordinates'] as List;
    expect(coords.length, 3);
    expect(coords[0], [-122.41, 37.77]);
  });
}
