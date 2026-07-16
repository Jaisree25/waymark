// lib/metrics/capture_reliability_collector.dart
//
// Cycle 6 — Risk #1 (capture reliability) metric. Pure Dart; the real trigger
// data feeds it on a device in Cycle 7.
//
//   reliability = complete / attempted
//
// where a trigger is bucketed as empty / partial / complete. A PARTIAL pre-roll
// (< 90% of expected, i.e. an early-in-trip trigger) is its own bucket and does
// NOT count toward the numerator — the >= 90% go/no-go threshold is measured on
// complete / attempted only.

class CaptureReliabilityCollector {
  int _attempted = 0;
  int _complete = 0;
  int _partial = 0; // pre-roll shorter than 90% of expected (early-in-trip)
  int _empty = 0; // ring buffer empty at trigger time

  void recordTrigger({
    required bool hasWindow,
    required Duration actualPreRoll,
    required Duration expectedPreRoll,
  }) {
    _attempted++;
    if (!hasWindow) {
      _empty++;
      return;
    }
    if (actualPreRoll < expectedPreRoll * 0.9) {
      _partial++;
      return;
    }
    _complete++;
  }

  /// complete / attempted (partials count in the denominator, not the numerator).
  double get reliability => _attempted == 0 ? 0 : _complete / _attempted;

  Map<String, dynamic> toMetricsJson() => {
        'attempted': _attempted,
        'complete': _complete,
        'partial': _partial,
        'empty': _empty,
        'reliability': reliability,
        // In M1 the controller feeds one "complete" per assembled event; the
        // partial/empty split needs pre-assembly signals from the trigger that
        // aren't surfaced yet. This note tells the feasibility reader what the
        // number represents.
        'reliability_note': 'assembled_events_only_partials_not_counted',
      };
}
