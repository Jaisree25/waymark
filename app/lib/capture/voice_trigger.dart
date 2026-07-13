// lib/capture/voice_trigger.dart
//
// Cycle 2 — voice trigger → event assembly. Wires the (faked) mic frames through
// the audio ring buffer and a KeywordRecognizer. On a keyword hit it opens a
// capture, and once the post-roll (t_post) has elapsed it slices the
// [t_trigger - t_pre, t_trigger + t_post] window into an Event.
//
// sherpa_onnx stays behind the KeywordRecognizer seam (ports.dart); this logic
// is fully deterministic and unit-testable with a fake recognizer + fake clock.

import 'event.dart';
import 'keyword_config.dart';
import 'ports.dart';
import 'ring_buffer.dart';

/// Parses a spoken keyword into (event_type, severity) using the keyword grammar
/// (keyword_config.dart): "mark level four" → 4, "log scary" → 5, "log it" → no
/// severity. Every M1 event is an `incident`.
({String eventType, int? severity}) parseKeyword(String keyword) {
  return (eventType: 'incident', severity: severityForKeyword(keyword));
}

/// Consumes audio frames, detects keywords, and emits assembled [Event]s.
///
/// Push one frame at a time via [onFrame] (the real mic stream drives this; the
/// tests feed frames by hand). Assembled events are delivered to [onEvent].
class VoiceTrigger {
  VoiceTrigger({
    required this.recognizer,
    required this.audioBuffer,
    required this.clock,
    required this.tPre,
    required this.tPost,
    required this.debounce,
    required this.onEvent,
    this.onDetected,
    this.currentFix,
  });

  final KeywordRecognizer recognizer;
  final RingBuffer<AudioFrame> audioBuffer;
  final Clock clock;
  final Duration tPre;
  final Duration tPost;
  final Duration debounce;
  final void Function(Event event) onEvent;

  /// Fired the instant a keyword is accepted (before the post-roll), for
  /// immediate UI feedback. The full [onEvent] follows at finalize.
  final void Function(KeywordDetection detection)? onDetected;

  /// Reads the location layer's last-known GPS fix. Sampled at trigger time so
  /// the event is stamped with where the car was at `t_trigger`.
  final GpsFix? Function()? currentFix;

  DateTime? _lastTrigger;
  _Pending? _pending;

  /// Feed one PCM frame.
  void onFrame(AudioFrame frame) {
    final now = clock.now();
    audioBuffer.add(frame);

    // Finalize a pending capture once its post-roll window has fully elapsed
    // (now >= t_trigger + t_post). This is why callers must advance the clock
    // past t_post before the window is complete.
    final pending = _pending;
    if (pending != null && !now.isBefore(pending.deadline)) {
      _emit(pending);
      _pending = null;
    }

    final keyword = recognizer.decode(frame);
    if (keyword == null) return;

    // Ignore new keywords while a capture is mid-flight.
    if (_pending != null) return;

    // Debounce is HALF-OPEN: suppress a second trigger when Δt < debounce, allow
    // it when Δt >= debounce (same boundary convention as the ring buffer).
    final last = _lastTrigger;
    if (last != null && now.difference(last) < debounce) return;

    _lastTrigger = now;
    final parsed = parseKeyword(keyword);
    // Immediate feedback signal (the full event finalizes ~t_post later).
    onDetected?.call(KeywordDetection(
      keyword: keyword,
      severity: parsed.severity,
      at: now,
    ));
    _pending = _Pending(
      tTrigger: now,
      deadline: now.add(tPost),
      keyword: keyword,
      eventType: parsed.eventType,
      severity: parsed.severity,
      // Sample the last-known fix NOW (at t_trigger), not when we finalize.
      location: currentFix?.call(),
    );
  }

  /// Finalize any in-flight capture immediately, returning it (with whatever
  /// audio is buffered — full pre-roll, possibly truncated post-roll) so the
  /// caller can persist it. Returns null if nothing is pending. Called on trip
  /// end so a capture still inside its post-roll window isn't dropped.
  Event? flushPending() {
    final pending = _pending;
    if (pending == null) return null;
    _pending = null;
    return _buildEvent(pending);
  }

  void _emit(_Pending pending) => onEvent(_buildEvent(pending));

  Event _buildEvent(_Pending pending) {
    final window = audioBuffer.window(
      from: pending.tTrigger.subtract(tPre),
      to: pending.tTrigger.add(tPost),
    );
    return Event(
      tTrigger: pending.tTrigger,
      triggerSource: 'voice',
      eventType: pending.eventType,
      severity: pending.severity,
      keyword: pending.keyword,
      tPreSeconds: tPre.inMilliseconds / 1000.0,
      tPostSeconds: tPost.inMilliseconds / 1000.0,
      audioWindow: window,
      location: pending.location,
    );
  }
}

class _Pending {
  _Pending({
    required this.tTrigger,
    required this.deadline,
    required this.keyword,
    required this.eventType,
    required this.severity,
    required this.location,
  });

  final DateTime tTrigger;
  final DateTime deadline;
  final String keyword;
  final String eventType;
  final int? severity;
  final GpsFix? location;
}
