// lib/capture/event.dart
//
// The in-memory result of a trigger: the moment plus its [t_pre, t_post] audio
// window. This is the app's domain object; `toPayload` maps it to the frozen
// Contract-2 wire shape (EventPayload) when it's time to upload.

import 'ports.dart';

/// Emitted the INSTANT a keyword is recognized (before the post-roll window is
/// captured) so the UI can give immediate feedback — chime, flash, last-event.
/// The full [Event] follows once the window finalizes (~t_post later).
class KeywordDetection {
  const KeywordDetection({
    required this.keyword,
    required this.severity,
    required this.at,
  });

  final String keyword;
  final int? severity;
  final DateTime at;
}

/// An assembled capture event.
class Event {
  const Event({
    required this.tTrigger,
    required this.triggerSource,
    required this.eventType,
    required this.severity,
    required this.tPreSeconds,
    required this.tPostSeconds,
    required this.audioWindow,
    this.keyword,
    this.location,
  });

  /// Wall/monotonic time of the trigger (from the injected clock).
  final DateTime tTrigger;

  /// voice | tap | imu.
  final String triggerSource;

  /// incident (M1).
  final String eventType;

  /// 1..5 from the voice grammar, or null (e.g. "log it").
  final int? severity;

  /// The spoken keyword that fired this event (recorded into features), or null
  /// for non-voice triggers.
  final String? keyword;

  final double tPreSeconds;
  final double tPostSeconds;

  /// The captured `[t_trigger - t_pre, t_trigger + t_post]` audio frames.
  final List<AudioFrame> audioWindow;

  /// The last-known GPS fix **as of `t_trigger`** (stamped by the assembler at
  /// trigger time, not at flush time — the car may have moved by upload).
  final GpsFix? location;

  /// Map to the Contract-2 `EventIn` payload. The blobs (audioWindow) are NOT
  /// carried in the payload — they are persisted/uploaded separately. `raw_*`
  /// default to the fix captured at trigger time; callers may override.
  EventPayload toPayload({
    required String id,
    required String tripId,
    double? rawLat,
    double? rawLon,
    double? rawAccuracyM,
    Map<String, dynamic> features = const <String, dynamic>{},
  }) {
    // The spoken keyword rides in the features attributes bag (Contract 2's
    // features is additionalProperties: true). Explicit features win.
    final mergedFeatures = <String, dynamic>{
      if (keyword != null) 'keyword': keyword,
      ...features,
    };
    return EventPayload(
      id: id,
      tripId: tripId,
      tTrigger: tTrigger,
      tPreSeconds: tPreSeconds,
      tPostSeconds: tPostSeconds,
      triggerSource: triggerSource,
      eventType: eventType,
      severity: severity,
      features: mergedFeatures,
      rawLat: rawLat ?? location?.lat,
      rawLon: rawLon ?? location?.lon,
      rawAccuracyM: rawAccuracyM ?? location?.horizontalAccuracyM,
    );
  }
}
