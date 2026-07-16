// Cycle 8a — CaptureController: the pure-logic object that owns a trip's running
// state and wires the pipeline together. No widgets, no BuildContext. Fakes for
// the trigger and uploader; a real (in-memory) outbox and a real TripController.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/capture_controller.dart';
import 'package:fsd_app/capture/event.dart';
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
  late FakeUploader uploader;
  late CaptureController controller;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    db = AppDatabase(NativeDatabase.memory(), clock: clock);
    trip = TripController(clock: clock);
    trigger = FakeTriggerPipeline();
    uploader = FakeUploader(gated: true); // 8a observes the uploading state
    controller = CaptureController(
      trip: trip,
      trigger: trigger,
      uploader: uploader,
      db: db,
      clock: clock,
      chime: FakeChimePlayer(),
      blobStore: FakeBlobStore(),
      permissions: FakePermissionRequester(),
      locationTracker: LocationTracker(FakeLocationSource(const [])),
      thermalSource: FakeThermalSource(const []),
      tripConfig: const TripStartConfig(
        userId: 'firebase-uid-1',
        provider: 'tesla',
        supervision: true,
        appVersion: '1.0.0+1',
        configVersion: '1.0.0',
      ),
      generateId: () => 'trip-1',
    );
  });

  tearDown(() async {
    controller.dispose();
    await trigger.dispose();
    await db.close();
  });

  test('test_controller_starts_idle', () {
    expect(controller.state, CaptureState.idle);
  });

  test('test_start_trip_transitions_to_recording', () async {
    await controller.startTrip();

    expect(controller.state, CaptureState.recording);
    // TripController.start() happened exactly once → an open trip exists.
    expect(trip.current, isNotNull);
    expect(trip.current!.isOpen, isTrue);
    expect(trip.current!.id, 'trip-1');
    expect(trigger.started, isTrue);
  });

  test('test_keyword_updates_last_event', () async {
    await controller.startTrip();

    var notified = 0;
    controller.addListener(() => notified++);

    trigger.fireDetection(KeywordDetection(
      keyword: 'mark level three',
      severity: 3,
      at: clock.now(),
    ));
    await pumpEventQueue();

    expect(controller.lastEvent, isNotNull);
    expect(controller.lastEvent!.keyword, 'mark level three');
    expect(controller.lastEvent!.severity, 3);
    expect(notified, greaterThan(0)); // notifyListeners() → UI rebuilds
  });

  test('test_pending_capture_flushed_on_end_trip', () async {
    await controller.startTrip();

    // A capture is still in its post-roll when the driver ends the trip. The
    // trigger surfaces it via flush() so it isn't dropped on the way down.
    trigger.pendingToFlush = Event(
      tTrigger: clock.now(),
      triggerSource: 'voice',
      eventType: 'incident',
      severity: 4,
      keyword: 'mark level four',
      tPreSeconds: 10,
      tPostSeconds: 5,
      audioWindow: const [],
    );

    final ending = controller.endTrip();
    await pumpEventQueue();

    // The flushed capture was persisted to the outbox BEFORE the trip closed.
    expect(await db.pendingEvents(), hasLength(1));

    uploader.completeFlush();
    await ending;
  });

  test('test_end_trip_transitions_to_uploading', () async {
    await controller.startTrip();

    final ending = controller.endTrip(); // don't await — flush is gated
    await pumpEventQueue();

    expect(controller.state, CaptureState.uploading);
    expect(trip.current!.isOpen, isFalse); // TripController.stop() happened
    expect(uploader.flushCalled, isTrue);

    uploader.completeFlush();
    await ending;
  });

  test('test_uploading_to_done', () async {
    await controller.startTrip();

    final ending = controller.endTrip();
    await pumpEventQueue();
    expect(controller.state, CaptureState.uploading);

    uploader.completeFlush(); // uploader completes
    await ending;

    expect(controller.state, CaptureState.done);
  });

  test('reset() returns to idle and clears the last event', () async {
    await controller.startTrip();
    trigger.fireDetection(KeywordDetection(
      keyword: 'mark level three',
      severity: 3,
      at: clock.now(),
    ));
    await pumpEventQueue();
    expect(controller.lastEvent, isNotNull);

    controller.reset();

    expect(controller.state, CaptureState.idle);
    expect(controller.lastEvent, isNull);
  });

  test('test_pending_counts_reflect_outbox', () async {
    await db.enqueueEvent(eventPayloadFixture(id: 'e1'), createdAt: clock.now());
    await db.enqueueEvent(eventPayloadFixture(id: 'e2'), createdAt: clock.now());
    await db.enqueueBreadcrumb(
      const BreadcrumbPayload(
        id: 'bc-1',
        tripId: 'trip-1',
        track: {
          'type': 'LineString',
          'coordinates': [
            [-122.41, 37.77],
            [-122.42, 37.78],
          ],
        },
      ),
      createdAt: clock.now(),
    );

    await controller.refreshPendingCounts();

    expect(controller.pendingEvents, 2);
    expect(controller.pendingSegments, 1);
  });
}
