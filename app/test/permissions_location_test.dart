// Cycle 10a — permissions gate + GPS→event. Capture must not start without the
// mic permission (and must not crash), and a running LocationTracker's fix must
// reach the enqueued event payload's raw_lat/raw_lon.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/capture_controller.dart';
import 'package:fsd_app/capture/event.dart';
import 'package:fsd_app/capture/keyword_config.dart';
import 'package:fsd_app/capture/location_tracker.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/capture/trip_controller.dart';
import 'package:fsd_app/store/app_database.dart';

import 'support/capture_fakes.dart';
import 'support/fakes.dart';

void main() {
  late FakeClock clock;
  late AppDatabase db;
  late TripController trip;
  late FakeTriggerPipeline trigger;
  late FakeBlobStore blobStore;
  var idSeq = 0;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    db = AppDatabase(NativeDatabase.memory(), clock: clock);
    trip = TripController(clock: clock);
    trigger = FakeTriggerPipeline();
    blobStore = FakeBlobStore();
    idSeq = 0;
  });

  tearDown(() async {
    await trigger.dispose();
    await db.close();
  });

  CaptureController build({
    PermissionRequester? permissions,
    LocationTracker? tracker,
  }) =>
      CaptureController(
        trip: trip,
        trigger: trigger,
        uploader: FakeUploader(),
        db: db,
        clock: clock,
        chime: FakeChimePlayer(),
        blobStore: blobStore,
        permissions: permissions ?? FakePermissionRequester(),
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

  Event voiceEvent(String keyword, {GpsFix? location}) => Event(
        tTrigger: clock.now(),
        triggerSource: 'voice',
        eventType: 'incident',
        severity: severityForKeyword(keyword),
        keyword: keyword,
        tPreSeconds: 15,
        tPostSeconds: 8,
        audioWindow: [audioFrame(1), audioFrame(2)],
        location: location,
      );

  test('LocationTracker caches the latest fix', () async {
    final tracker =
        LocationTracker(FakeLocationSource([gpsFix(1, 2), gpsFix(3, 4)]));
    tracker.start();
    await pumpEventQueue();

    expect(tracker.current!.lat, 3);
    expect(tracker.current!.lon, 4);
    await tracker.stop();
  });

  test('test_capture_blocked_without_audio_permission', () async {
    final controller =
        build(permissions: FakePermissionRequester(audioGranted: false));
    addTearDown(controller.dispose);

    await controller.startTrip();

    expect(controller.state, CaptureState.idle); // stays idle, no crash
    expect(controller.permissionDenied, isTrue);
    expect(trip.current, isNull); // trip not started
    expect(trigger.started, isFalse); // capture not started
  });

  test('test_event_has_gps_coordinates', () async {
    final tracker = LocationTracker(
      FakeLocationSource([gpsFix(37.77, -122.41, accuracyM: 4)]),
    );
    final controller = build(tracker: tracker);
    addTearDown(controller.dispose);

    await controller.startTrip(); // starts the tracker
    await pumpEventQueue(); // tracker receives the fix

    // The trigger stamps the current fix at trigger time (as MicTriggerPipeline
    // does via currentFix); here we fire with the tracker's current value.
    trigger.fire(voiceEvent('mark level three', location: tracker.current));
    await pumpEventQueue();

    final payload = EventPayload.fromJson(
      jsonDecode((await db.pendingEvents()).single.payloadJson)
          as Map<String, dynamic>,
    );
    expect(payload.rawLat, 37.77);
    expect(payload.rawLon, -122.41);
    expect(payload.rawAccuracyM, 4);
  });
}
