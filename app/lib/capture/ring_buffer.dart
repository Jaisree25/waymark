// lib/capture/ring_buffer.dart
//
// Cycle 1 — a fixed-duration, time-indexed rolling buffer (02-flutter-app.md §4).
// Generic over the sample type so the same buffer serves audio frames and IMU
// samples. Timestamps come from an injected [Clock] (monotonic in production),
// never wall-clock, so the logic is fully unit-testable.

import 'ports.dart';

/// A bounded rolling window of the most recent [capacity] worth of samples.
///
/// On every [add] the buffer stamps the sample with `clock.now()` and evicts
/// everything older than the capacity window. [window] returns the samples
/// whose timestamps fall in an inclusive `[from, to]` range — used on a trigger
/// to slice the `[t_trigger - t_pre, t_trigger + t_post]` window.
class RingBuffer<T> {
  RingBuffer({required this.capacity, required this.clock});

  /// How much history to retain.
  final Duration capacity;

  /// Injected time source (monotonic in production, faked in tests).
  final Clock clock;

  final List<_Stamped<T>> _items = <_Stamped<T>>[];

  /// Append [sample], stamping it with the current time, then drop anything
  /// that has aged out of the capacity window.
  void add(T sample) {
    final now = clock.now();
    _items.add(_Stamped<T>(now, sample));

    // Retain samples strictly younger than `capacity`; the sample exactly at
    // the boundary (age == capacity) has aged out.
    final cutoff = now.subtract(capacity);
    while (_items.isNotEmpty && !_items.first.ts.isAfter(cutoff)) {
      _items.removeAt(0);
    }
  }

  /// The retained samples whose timestamps are within `[from, to]`, inclusive,
  /// in insertion order.
  List<T> window({required DateTime from, required DateTime to}) {
    return [
      for (final item in _items)
        if (!item.ts.isBefore(from) && !item.ts.isAfter(to)) item.sample,
    ];
  }

  /// Number of samples currently retained.
  int get length => _items.length;
}

class _Stamped<T> {
  const _Stamped(this.ts, this.sample);

  final DateTime ts;
  final T sample;
}
