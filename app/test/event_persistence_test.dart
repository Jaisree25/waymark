// Cycle 9a — event persistence. When a keyword fires while recording, the
// CaptureController builds a real EventPayload, writes the audio window to the
// BlobStore, and enqueues the payload in the outbox. Pure Dart (fake trigger +
// fake blob store + in-memory outbox).

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
  late CaptureController controller;
  var idSeq = 0;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    db = AppDatabase(NativeDatabase.memory(), clock: clock);
    trip = TripController(clock: clock);
    trigger = FakeTriggerPipeline();
    blobStore = FakeBlobStore();
    idSeq = 0;
    controller = CaptureController(
      trip: trip,
      trigger: trigger,
      uploader: FakeUploader(),
      db: db,
      clock: clock,
      chime: FakeChimePlayer(),
      blobStore: blobStore,
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
      generateId: () => 'gen-${idSeq++}',
    );
  });

  tearDown(() async {
    controller.dispose();
    await trigger.dispose();
    await db.close();
  });

  Event voiceEvent(String keyword, {GpsFix? location, List<AudioFrame>? audio}) =>
      Event(
        tTrigger: clock.now(),
        triggerSource: 'voice',
        eventType: 'incident',
        severity: severityForKeyword(keyword),
        keyword: keyword,
        tPreSeconds: 15,
        tPostSeconds: 8,
        audioWindow: audio ?? [audioFrame(7), audioFrame(8)],
        location: location,
      );

  Future<EventPayload> firePayload(Event event) async {
    await controller.startTrip();
    trigger.fire(event);
    await pumpEventQueue();
    final rows = await db.pendingEvents();
    return EventPayload.fromJson(
      jsonDecode(rows.single.payloadJson) as Map<String, dynamic>,
    );
  }

  test('test_keyword_enqueues_event', () async {
    await controller.startTrip();
    final tripId = trip.current!.id;

    trigger.fire(voiceEvent('mark level three'));
    await pumpEventQueue();

    final rows = await db.pendingEvents();
    expect(rows, hasLength(1));

    final payload = EventPayload.fromJson(
      jsonDecode(rows.single.payloadJson) as Map<String, dynamic>,
    );
    expect(payload.tripId, tripId);
    expect(payload.triggerSource, 'voice');
    expect(payload.severity, 3); // "mark level three"
    expect(payload.features['keyword'], 'mark level three');
    expect(payload.id, isNotEmpty);
  });

  test('test_event_id_is_stable_on_retry', () async {
    await controller.startTrip();
    trigger.fire(voiceEvent('mark level four'));
    await pumpEventQueue();

    final first = (await db.pendingEvents()).single;
    final id = first.id;

    // Re-enqueue the same payload (a retry) → insertOrIgnore keeps one row, same id.
    final payload = EventPayload.fromJson(
      jsonDecode(first.payloadJson) as Map<String, dynamic>,
    );
    await db.enqueueEvent(payload);

    final rows = await db.pendingEvents();
    expect(rows, hasLength(1));
    expect(rows.single.id, id);
  });

  test('test_audio_blob_reference_in_payload', () async {
    final payload = await firePayload(
      voiceEvent('log scary', audio: [audioFrame(7), audioFrame(8)]),
    );

    // The payload references the persisted blob...
    expect(payload.features['audio_ref'], isNotNull);
    // ...and the blob store received the ring-buffer window bytes.
    expect(blobStore.audioBytes.single, [7, 8]);
    expect(
      payload.features['audio_ref'],
      'blob://audio/${blobStore.audioIds.single}.wav',
    );
  });

  test('test_location_stamped_at_trigger_time', () async {
    final atTrigger = gpsFix(37.77, -122.41, accuracyM: 4);
    final payload = await firePayload(
      voiceEvent('mark level five', location: atTrigger),
    );

    expect(payload.rawLat, 37.77);
    expect(payload.rawLon, -122.41);
    expect(payload.rawAccuracyM, 4);
  });
}
