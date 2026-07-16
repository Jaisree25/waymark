// Cycle 10b — breadcrumb logging. One shared LocationTracker feeds both the
// trigger's currentFix (10a) and the BreadcrumbLogger; startTrip starts logging,
// endTrip stops and enqueues the segment. The [lon,lat] GeoJSON order is
// re-asserted here — the first time the breadcrumb reaches the DB.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/capture_controller.dart';
import 'package:fsd_app/capture/location_tracker.dart';
import 'package:fsd_app/capture/trip_controller.dart';
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

  CaptureController build(LocationTracker tracker) => CaptureController(
        trip: trip,
        trigger: trigger,
        uploader: FakeUploader(),
        db: db,
        clock: clock,
        chime: FakeChimePlayer(),
        blobStore: FakeBlobStore(),
        permissions: FakePermissionRequester(),
        locationTracker: tracker,
        thermalSource: FakeThermalSource(const []),
        tripConfig: const TripStartConfig(
          userId: 'firebase-uid-1',
          provider: 'tesla',
          supervision: true,
          appVersion: '1.0.0+1',
          configVersion: '1.0.0',
        ),
        generateId: () => 'gen-${idSeq++}',
      );

  test('test_breadcrumb_enqueued_on_end_trip', () async {
    final source = FakeLocationSource([
      gpsFix(37.77, -122.41),
      gpsFix(37.78, -122.42),
      gpsFix(37.79, -122.43),
    ]);
    final controller = build(LocationTracker(source));
    addTearDown(controller.dispose);

    await controller.startTrip();
    await pumpEventQueue(); // 3 fixes flow through the shared tracker
    await controller.endTrip();

    final rows = await db.allBreadcrumbs();
    expect(rows, hasLength(1));

    final payload = jsonDecode(rows.single.payloadJson) as Map<String, dynamic>;
    final track = payload['track'] as Map<String, dynamic>;
    expect(track['type'], 'LineString');
    final coords = track['coordinates'] as List;
    expect(coords.length, 3);
    // [lon, lat] order — the non-negotiable GeoJSON invariant, now pinned at the DB.
    expect(coords[0], [-122.41, 37.77]);
  });

  test('test_breadcrumb_not_enqueued_if_fewer_than_2_fixes', () async {
    final source = FakeLocationSource([gpsFix(37.77, -122.41)]);
    final controller = build(LocationTracker(source));
    addTearDown(controller.dispose);

    await controller.startTrip();
    await pumpEventQueue();
    await controller.endTrip();

    // hasValidSegment == false (Cycle 3 boundary) → no breadcrumb row.
    expect(await db.allBreadcrumbs(), isEmpty);
  });
}
