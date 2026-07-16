// Cycle 8c — the "it worked" feedback: chime + visual flash, plus the live trip
// timer tick (same fakeAsync + injected-Clock + Timer mechanism as the flash
// reset). All controller-level; the screen reads flashActive/elapsed as
// snapshots. No Future.delayed anywhere — time is driven by fakeAsync + Clock.

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/capture_controller.dart';
import 'package:fsd_app/capture/event.dart';
import 'package:fsd_app/capture/location_tracker.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/capture/trip_controller.dart';
import 'package:fsd_app/store/app_database.dart';

import 'support/capture_fakes.dart';
import 'support/fakes.dart';

/// A Clock whose time tracks a FakeAsync zone's elapsed, so `elapsed` (which
/// reads the injected clock) advances in lockstep with fakeAsync's timers.
class _FakeAsyncClock implements Clock {
  _FakeAsyncClock(this._start, this._async);
  final DateTime _start;
  final FakeAsync _async;
  @override
  DateTime now() => _start.add(_async.elapsed);
}

const _tripConfig = TripStartConfig(
  userId: 'firebase-uid-1',
  provider: 'tesla',
  supervision: true,
  appVersion: '1.0.0+1',
  configVersion: '1.0.0',
);
const _flashDuration = Duration(milliseconds: 800);

Event _voiceEvent(Clock clock) => Event(
      tTrigger: clock.now(),
      triggerSource: 'voice',
      eventType: 'incident',
      severity: 3,
      keyword: 'mark level three',
      tPreSeconds: 15,
      tPostSeconds: 8,
      audioWindow: const [],
    );

KeywordDetection _detection(Clock clock) => KeywordDetection(
      keyword: 'mark level three',
      severity: 3,
      at: clock.now(),
    );

CaptureController _build({
  required Clock clock,
  required AppDatabase db,
  required FakeTriggerPipeline trigger,
  required FakeChimePlayer chime,
}) =>
    CaptureController(
      trip: TripController(clock: clock),
      trigger: trigger,
      uploader: FakeUploader(),
      db: db,
      clock: clock,
      chime: chime,
      blobStore: FakeBlobStore(),
      permissions: FakePermissionRequester(),
      locationTracker: LocationTracker(FakeLocationSource(const [])),
      thermalSource: FakeThermalSource(const []),
      flashDuration: _flashDuration,
      tripConfig: _tripConfig,
      generateId: () => 'trip-1',
    );

void main() {
  test('test_chime_plays_on_keyword', () async {
    final clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    final db = AppDatabase(NativeDatabase.memory(), clock: clock);
    final trigger = FakeTriggerPipeline();
    final chime = FakeChimePlayer();
    final controller = _build(clock: clock, db: db, trigger: trigger, chime: chime);
    addTearDown(() async {
      controller.dispose();
      await trigger.dispose();
      await db.close();
    });

    await controller.startTrip();
    trigger.fireDetection(_detection(clock));
    await pumpEventQueue();

    expect(chime.playCalls, 1);
  });

  test('test_no_chime_when_not_recording', () async {
    final clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    final db = AppDatabase(NativeDatabase.memory(), clock: clock);
    final trigger = FakeTriggerPipeline();
    final chime = FakeChimePlayer();
    final controller = _build(clock: clock, db: db, trigger: trigger, chime: chime);
    addTearDown(() async {
      controller.dispose();
      await trigger.dispose();
      await db.close();
    });

    // Never started → idle. A spurious pre-trip trigger must not chime.
    trigger.fireDetection(_detection(clock));
    await pumpEventQueue();

    expect(chime.playCalls, 0);
    expect(controller.state, CaptureState.idle);
  });

  test('detection chimes immediately; the finalized event does not re-chime',
      () async {
    final clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    final db = AppDatabase(NativeDatabase.memory(), clock: clock);
    final trigger = FakeTriggerPipeline();
    final chime = FakeChimePlayer();
    final controller = _build(clock: clock, db: db, trigger: trigger, chime: chime);
    addTearDown(() async {
      controller.dispose();
      await trigger.dispose();
      await db.close();
    });

    await controller.startTrip();

    // Detection → immediate chime + last-event, but NOTHING persisted yet.
    trigger.fireDetection(_detection(clock));
    await pumpEventQueue();
    expect(chime.playCalls, 1);
    expect(controller.lastEvent!.keyword, 'mark level three');
    expect(await db.pendingEvents(), isEmpty);

    // Finalized event → persists, no second chime.
    trigger.fire(_voiceEvent(clock));
    await pumpEventQueue();
    expect(chime.playCalls, 1); // still 1
    expect(await db.pendingEvents(), hasLength(1));
  });

  test('test_flash_resets_after_duration', () {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    fakeAsync((async) {
      final clock = _FakeAsyncClock(DateTime.utc(2026, 7, 10, 12), async);
      final trigger = FakeTriggerPipeline();
      final controller =
          _build(clock: clock, db: db, trigger: trigger, chime: FakeChimePlayer());

      controller.startTrip();
      async.flushMicrotasks();

      trigger.fireDetection(_detection(clock));
      async.flushMicrotasks();
      expect(controller.flashActive, isTrue);

      var notified = 0;
      controller.addListener(() => notified++);

      async.elapse(_flashDuration); // advance past the flash window (< 1s tick)
      expect(controller.flashActive, isFalse);
      expect(notified, greaterThan(0)); // notifyListeners() on reset

      controller.dispose();
    });
  });

  test('test_timer_ticks_per_second', () {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    fakeAsync((async) {
      final clock = _FakeAsyncClock(DateTime.utc(2026, 7, 10, 12), async);
      final trigger = FakeTriggerPipeline();
      final controller =
          _build(clock: clock, db: db, trigger: trigger, chime: FakeChimePlayer());

      controller.startTrip();
      async.flushMicrotasks();

      var ticks = 0;
      controller.addListener(() => ticks++);

      async.elapse(const Duration(seconds: 3));

      expect(ticks, 3); // one notifyListeners() per second
      expect(controller.elapsed, const Duration(seconds: 3));

      controller.dispose();
    });
  });
}
