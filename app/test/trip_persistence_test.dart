// Cycle 10c — trip persistence. One trip row per drive, keyed by the trip UUID:
// startTrip inserts it (ended_at null), endTrip UPDATES the same row (not a new
// one). The row id must equal the open trip's UUID — that's the FK guard for
// Person A's events.trip_id REFERENCES trips.id.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/capture_controller.dart';
import 'package:fsd_app/capture/location_tracker.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/capture/trip_controller.dart';
import 'package:fsd_app/store/app_database.dart';

import 'support/capture_fakes.dart';
import 'support/fakes.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 10, 12);

  late FakeClock clock;
  late AppDatabase db;
  late TripController trip;
  late FakeTriggerPipeline trigger;
  var idSeq = 0;

  setUp(() {
    clock = FakeClock(t0);
    db = AppDatabase(NativeDatabase.memory(), clock: clock);
    trip = TripController(clock: clock);
    trigger = FakeTriggerPipeline();
    idSeq = 0;
  });

  tearDown(() async {
    await trigger.dispose();
    await db.close();
  });

  CaptureController build({LocationTracker? tracker}) => CaptureController(
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

  test('test_trip_db_update_sets_ended_at', () async {
    await db.enqueueTrip(
      TripPayload(
        id: 'trip-1',
        userId: 'u',
        provider: 'tesla',
        supervision: true,
        appConfigVersion: '1.0.0',
        startedAt: t0,
      ),
      createdAt: t0,
    );

    final endedAt = t0.add(const Duration(minutes: 30));
    // updateTripOnEnd writes ended_at AND metrics in one atomic update.
    await db.updateTripOnEnd('trip-1', endedAt, {'k': 'v'});

    final json =
        jsonDecode((await db.allTrips()).single.payloadJson) as Map<String, dynamic>;
    expect(json['ended_at'], isNotNull);
    expect(DateTime.parse(json['ended_at'] as String), endedAt);
    expect(json['metrics'], {'k': 'v'});
  });

  test('test_trip_row_created_on_start', () async {
    final controller = build();
    addTearDown(controller.dispose);

    await controller.startTrip();
    await pumpEventQueue();

    final rows = await db.allTrips();
    expect(rows, hasLength(1));
    // FK guard: the trip row id IS the open trip's UUID (events/breadcrumbs ref it).
    expect(rows.single.id, trip.current!.id);

    final json =
        jsonDecode(rows.single.payloadJson) as Map<String, dynamic>;
    expect(json['provider'], 'tesla');
    expect(json['app_config_version'], '1.0.0');
    expect(json['started_at'], isNotNull);
    expect(json['ended_at'], isNull);
  });

  test('test_trip_row_updated_on_end', () async {
    final controller = build();
    addTearDown(controller.dispose);

    await controller.startTrip();
    await pumpEventQueue();
    final tripId = trip.current!.id;

    await controller.endTrip();

    final rows = await db.allTrips();
    expect(rows, hasLength(1)); // KEY guard: UPDATE existing, not INSERT new
    expect(rows.single.id, tripId); // same row
    final json =
        jsonDecode(rows.single.payloadJson) as Map<String, dynamic>;
    expect(json['ended_at'], isNotNull);
  });

  test('endTrip full postcondition: 1 closed trip + 1 breadcrumb', () async {
    final source = FakeLocationSource([
      gpsFix(37.77, -122.41),
      gpsFix(37.78, -122.42),
      gpsFix(37.79, -122.43),
    ]);
    final controller = build(tracker: LocationTracker(source));
    addTearDown(controller.dispose);

    await controller.startTrip();
    await pumpEventQueue();
    await controller.endTrip();

    final trips = await db.allTrips();
    expect(trips, hasLength(1));
    expect(
      (jsonDecode(trips.single.payloadJson) as Map<String, dynamic>)['ended_at'],
      isNotNull,
    );
    expect(await db.allBreadcrumbs(), hasLength(1));
    // (metrics assertion joins here at 10d to complete the combined test.)
  });
}
