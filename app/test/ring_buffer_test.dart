// Cycle 1 — the ring buffer (person-b-mobile.md §2, Cycle 1).
//
// A fixed-duration rolling window of audio/sensor frames. On a trigger it emits
// the [t_trigger - t_pre, t_trigger + t_post] slice. Pure logic, Clock-injected,
// no real time. These tests are written RED first; RingBuffer<T> does not exist
// yet.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/ring_buffer.dart';

import 'support/fakes.dart';

void main() {
  group('RingBuffer', () {
    test('keeps only the last N seconds', () {
      final clock = FakeClock();
      final rb = RingBuffer<int>(
        capacity: const Duration(seconds: 30),
        clock: clock,
      );

      // 100 one-second samples; only the last 30 seconds should survive.
      for (var i = 0; i < 100; i++) {
        clock.advance(const Duration(seconds: 1));
        rb.add(i);
      }

      final window = rb.window(
        from: clock.now().subtract(const Duration(seconds: 30)),
        to: clock.now(),
      );

      expect(window.length, 30);
      // The 30 most recent values, in order (70..99).
      expect(window.first, 70);
      expect(window.last, 99);
    });

    test('evicts the oldest samples beyond capacity', () {
      final clock = FakeClock();
      final rb = RingBuffer<int>(
        capacity: const Duration(seconds: 5),
        clock: clock,
      );

      for (var i = 0; i < 10; i++) {
        clock.advance(const Duration(seconds: 1));
        rb.add(i);
      }

      // After 10s with a 5s capacity, values 0..4 are evicted; 5..9 remain.
      final remaining = rb.window(
        from: clock.now().subtract(const Duration(seconds: 5)),
        to: clock.now(),
      );

      expect(remaining, [5, 6, 7, 8, 9]);
    });

    test('window() honours t_pre / t_post around a trigger', () {
      final clock = FakeClock();
      // Generous capacity so nothing in the window is evicted first.
      final rb = RingBuffer<int>(
        capacity: const Duration(seconds: 60),
        clock: clock,
      );

      // value i lands at ts = t0 + (i + 1) seconds.
      for (var i = 0; i < 40; i++) {
        clock.advance(const Duration(seconds: 1));
        rb.add(i);
      }

      const tPre = Duration(seconds: 15);
      const tPost = Duration(seconds: 8);
      final trigger = clock.now().subtract(tPost); // 8s before "now"

      final slice = rb.window(
        from: trigger.subtract(tPre),
        to: trigger.add(tPost),
      );

      // t_pre (15) + the trigger sample (1) + t_post (8) = 24 samples.
      expect(slice.length, 15 + 1 + 8);
      expect(slice.first, 16);
      expect(slice.last, 39);
    });
  });
}
