// Cycle 2 — voice trigger → event assembly (person-b-mobile.md §2, Cycle 2).
//
// The KWS model stays behind a KeywordRecognizer seam; here a FakeKeywordRecognizer
// fires on cue so the tests are deterministic (the real sherpa_onnx model is
// validated on-device in Cycle 7). Time is faked so post-roll timing is exact.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/event.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/capture/ring_buffer.dart';
import 'package:fsd_app/capture/voice_trigger.dart';

import 'support/fakes.dart';

void main() {
  group('VoiceTrigger', () {
    test('test_keyword_fires_event: one voice Event with a captured window', () {
      final clock = FakeClock(DateTime.utc(2026, 7, 10, 12, 0, 0));
      final recognizer = FakeKeywordRecognizer();
      final ring = RingBuffer<AudioFrame>(
        capacity: const Duration(seconds: 40),
        clock: clock,
      );
      final events = <Event>[];

      const tPre = Duration(seconds: 15);
      const tPost = Duration(seconds: 8);
      final trigger = VoiceTrigger(
        recognizer: recognizer,
        audioBuffer: ring,
        clock: clock,
        tPre: tPre,
        tPost: tPost,
        debounce: const Duration(seconds: 5),
        onEvent: events.add,
      );

      // Pre-roll: 19s of frames (one per second), no keyword.
      for (var i = 1; i <= 19; i++) {
        clock.advance(const Duration(seconds: 1));
        trigger.onFrame(audioFrame(i));
      }

      // Trigger frame at t = start + 20s.
      clock.advance(const Duration(seconds: 1));
      recognizer.fire('mark level four');
      trigger.onFrame(audioFrame(20));

      // No event yet: t_post is in the future, so the window isn't complete.
      expect(events, isEmpty);

      // Post-roll: advance PAST t + t_post (+28s) feeding frames, so the
      // post-roll is actually captured rather than assumed.
      for (var i = 21; i <= 29; i++) {
        clock.advance(const Duration(seconds: 1));
        trigger.onFrame(audioFrame(i));
      }

      expect(events, hasLength(1));
      final event = events.single;
      expect(event.triggerSource, 'voice');
      expect(event.severity, 4); // "mark level four" → severity 4
      expect(event.audioWindow, isNotEmpty);
      // Inclusive window [t-15 .. t+8] = 15 + 1 (trigger) + 8 = 24 frames.
      expect(event.audioWindow, hasLength(24));
    });

    test(
        'test_debounce: half-open — suppress when Δt < debounce, allow when '
        'Δt >= debounce', () {
      final clock = FakeClock(DateTime.utc(2026, 7, 10, 12, 0, 0));
      final recognizer = FakeKeywordRecognizer();
      final ring = RingBuffer<AudioFrame>(
        capacity: const Duration(seconds: 30),
        clock: clock,
      );
      final events = <Event>[];

      const debounce = Duration(seconds: 10);
      final trigger = VoiceTrigger(
        recognizer: recognizer,
        audioBuffer: ring,
        clock: clock,
        tPre: const Duration(seconds: 1),
        tPost: const Duration(seconds: 1),
        debounce: debounce,
        onEvent: events.add,
      );

      // One frame per second for 13s. Fire keywords at chosen ticks; Δt is
      // measured from the first ACCEPTED trigger (i == 1).
      for (var i = 1; i <= 13; i++) {
        clock.advance(const Duration(seconds: 1));
        if (i == 1 || i == 10 || i == 11) {
          // i=1  → first trigger              → ACCEPTED
          // i=10 → Δt = 9s  <  10s (debounce) → SUPPRESSED (half-open)
          // i=11 → Δt = 10s >= 10s (debounce) → ACCEPTED   (boundary allows)
          recognizer.fire('log it');
        }
        trigger.onFrame(audioFrame(i));
      }

      // Only the i=1 and i=11 triggers survive → two events.
      expect(events, hasLength(2));
    });

    test('test_event_stamps_position_at_trigger_time: last fix at t_trigger, '
        'not at flush', () {
      final clock = FakeClock(DateTime.utc(2026, 7, 10, 12, 0, 0));
      final recognizer = FakeKeywordRecognizer();
      final ring = RingBuffer<AudioFrame>(
        capacity: const Duration(seconds: 40),
        clock: clock,
      );
      final events = <Event>[];
      GpsFix? lastFix; // the location layer's last-known value

      final trigger = VoiceTrigger(
        recognizer: recognizer,
        audioBuffer: ring,
        clock: clock,
        tPre: const Duration(seconds: 2),
        tPost: const Duration(seconds: 3),
        debounce: const Duration(seconds: 5),
        onEvent: events.add,
        currentFix: () => lastFix,
      );

      // Position at trigger time: San Francisco.
      lastFix = gpsFix(37.77, -122.41, accuracyM: 4);
      for (var i = 1; i <= 4; i++) {
        clock.advance(const Duration(seconds: 1));
        trigger.onFrame(audioFrame(i));
      }

      clock.advance(const Duration(seconds: 1));
      recognizer.fire('mark level three');
      trigger.onFrame(audioFrame(5)); // trigger at t = start + 5s

      // Car moves AFTER the trigger but before the event finalizes/uploads.
      lastFix = gpsFix(40.00, -70.00, accuracyM: 9);
      for (var i = 6; i <= 10; i++) {
        clock.advance(const Duration(seconds: 1));
        trigger.onFrame(audioFrame(i));
      }

      expect(events, hasLength(1));
      final event = events.single;
      // Stamped at t_trigger (SF), NOT the later position.
      expect(event.location?.lat, 37.77);
      expect(event.location?.lon, -122.41);
      expect(event.location?.horizontalAccuracyM, 4);

      // And that flows into the payload's raw_* fields.
      final payload = event.toPayload(
        id: '66666666-6666-4666-8666-666666666666',
        tripId: '22222222-2222-4222-8222-222222222222',
      );
      expect(payload.rawLat, 37.77);
      expect(payload.rawLon, -122.41);
      expect(payload.rawAccuracyM, 4);
    });

    test('test_flush_returns_pending_capture: flush finalizes a capture still '
        'in its post-roll (partial window) and is null when idle', () {
      final clock = FakeClock(DateTime.utc(2026, 7, 10, 12, 0, 0));
      final recognizer = FakeKeywordRecognizer();
      final ring = RingBuffer<AudioFrame>(
        capacity: const Duration(seconds: 40),
        clock: clock,
      );
      final events = <Event>[];

      const tPre = Duration(seconds: 5);
      const tPost = Duration(seconds: 8);
      final trigger = VoiceTrigger(
        recognizer: recognizer,
        audioBuffer: ring,
        clock: clock,
        tPre: tPre,
        tPost: tPost,
        debounce: const Duration(seconds: 5),
        onEvent: events.add,
      );

      // Nothing pending → flush is a no-op returning null.
      expect(trigger.flushPending(), isNull);

      // Pre-roll, then a trigger at t = start + 6s (deadline = +14s).
      for (var i = 1; i <= 5; i++) {
        clock.advance(const Duration(seconds: 1));
        trigger.onFrame(audioFrame(i));
      }
      clock.advance(const Duration(seconds: 1));
      recognizer.fire('mark level four');
      trigger.onFrame(audioFrame(6));

      // Only 2s of post-roll elapses — t_post (8s) NOT reached, so nothing
      // has emitted normally. A naive stop here would DROP this capture.
      for (var i = 7; i <= 8; i++) {
        clock.advance(const Duration(seconds: 1));
        trigger.onFrame(audioFrame(i));
      }
      expect(events, isEmpty);

      // Flush finalizes it with whatever audio is buffered (full pre-roll,
      // truncated post-roll) and returns it for persistence.
      final flushed = trigger.flushPending();
      expect(flushed, isNotNull);
      expect(flushed!.severity, 4); // "mark level four"
      expect(flushed.audioWindow, isNotEmpty);

      // Idempotent: the pending capture is cleared, so a second flush is null.
      expect(trigger.flushPending(), isNull);
    });
  });
}
