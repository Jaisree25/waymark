// Test-only fakes for the hardware/network seams in lib/capture/ports.dart.
// No production code imports this; only tests do.

import 'dart:typed_data';

import 'package:fsd_app/capture/ports.dart';

/// A hand-advanced [Clock] so tests never depend on wall-clock time.
class FakeClock implements Clock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 1, 1);

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Move the clock forward by [d].
  void advance(Duration d) => _now = _now.add(d);
}

/// A [KeywordRecognizer] that fires on cue: call [fire] and the NEXT [decode]
/// returns that keyword exactly once. All other frames decode to null. This
/// keeps the trigger tests deterministic — the real sherpa_onnx model is only
/// exercised on-device in Cycle 7.
class FakeKeywordRecognizer implements KeywordRecognizer {
  String? _armed;

  /// Arm the recognizer so the next [decode] call returns [keyword] once.
  void fire(String keyword) => _armed = keyword;

  @override
  String? decode(AudioFrame frame) {
    final keyword = _armed;
    _armed = null;
    return keyword;
  }
}

/// Builds a distinguishable PCM frame for tests. Content is irrelevant to the
/// ring-buffer/trigger logic; [seed] just makes frames identifiable.
AudioFrame audioFrame(int seed, {int sampleRateHz = 16000}) =>
    AudioFrame(Uint8List.fromList(<int>[seed & 0xff]), sampleRateHz: sampleRateHz);

/// A deterministic Contract-2 event payload for store/upload tests.
EventPayload eventPayloadFixture({
  required String id,
  String tripId = '22222222-2222-4222-8222-222222222222',
  int? severity = 4,
  double? rawLat = 37.77,
  double? rawLon = -122.41,
  double? rawAccuracyM = 5,
  Map<String, dynamic> features = const <String, dynamic>{},
}) =>
    EventPayload(
      id: id,
      tripId: tripId,
      tTrigger: DateTime.utc(2026, 7, 10, 17, 30, 0),
      tPreSeconds: 15,
      tPostSeconds: 8,
      triggerSource: 'voice',
      severity: severity,
      features: features,
      rawLat: rawLat,
      rawLon: rawLon,
      rawAccuracyM: rawAccuracyM,
    );

/// A [LocationSource] that replays a fixed list of fixes as a stream.
class FakeLocationSource implements LocationSource {
  FakeLocationSource(this._fixes);

  final List<GpsFix> _fixes;

  @override
  Stream<GpsFix> positions() => Stream<GpsFix>.fromIterable(_fixes);
}

/// Builds a [GpsFix] with sensible defaults. Note the human order (lat, lon) —
/// the GeoJSON `[lon, lat]` swap happens in the breadcrumb builder, not here.
GpsFix gpsFix(
  double lat,
  double lon, {
  double accuracyM = 5,
  double speedMps = 0,
  DateTime? at,
}) =>
    GpsFix(
      lat: lat,
      lon: lon,
      horizontalAccuracyM: accuracyM,
      speedMps: speedMps,
      timestamp: at ?? DateTime.utc(2026, 1, 1),
    );
