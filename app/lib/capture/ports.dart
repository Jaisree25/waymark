// lib/capture/ports.dart
//
// The seams (ports) that isolate all hardware and network from the capture
// logic, so every unit is testable without a device (see person-b-mobile.md §1).
//
// Rules encoded here:
//   * Hardware (mic, IMU, GPS) and the network are reached ONLY through these
//     abstract interfaces; tests inject fakes.
//   * `IngestClient` is Person B↔C's frozen seam (Contract 2 in
//     docs/M1/Implementation/00-coordination.md §2). Its request/response
//     SHAPES are authoritative and must never be invented differently here.
//   * Time is injected via `Clock` so tests never touch wall-clock time. The
//     production clock is monotonic (Stopwatch-based) per 02-flutter-app.md §4.
//
// The payload `toJson()` serializers are intentionally NOT written yet: they are
// pinned test-first (golden + openapi schema tests) in Cycles 2/3/5. Adding them
// here without a failing test would violate the red→green rule.

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// Injectable clock. Production uses a monotonic, Stopwatch-based epoch so
/// audio/IMU/GPS channels align on one timeline (02-flutter-app.md §4). Tests
/// use a FakeClock they advance by hand.
abstract class Clock {
  DateTime now();
}

/// The default real clock (wall time). Used for persistence bookkeeping such as
/// the outbox `updated_at`; the capture pipeline injects a monotonic clock.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

// ---------------------------------------------------------------------------
// Hardware sample value-types (what the sources emit)
// ---------------------------------------------------------------------------

/// One chunk of mono PCM16 audio off the mic stream. Fed to both the KWS
/// recognizer and the audio ring buffer.
class AudioFrame {
  const AudioFrame(this.pcm, {required this.sampleRateHz});

  final Uint8List pcm;
  final int sampleRateHz;
}

/// One accelerometer + gyroscope reading.
class ImuSample {
  const ImuSample({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });

  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
}

/// One GPS fix. `horizontalAccuracyM` is stored deliberately — M1 risk #2
/// (attribution accuracy) needs it (02-flutter-app.md §5).
///
/// Named `GpsFix` rather than geolocator's `Position` so this port stays
/// decoupled from the geolocator package; the real adapter maps between them.
class GpsFix {
  const GpsFix({
    required this.lat,
    required this.lon,
    required this.horizontalAccuracyM,
    required this.speedMps,
    required this.timestamp,
  });

  final double lat;
  final double lon;
  final double horizontalAccuracyM;
  final double speedMps;
  final DateTime timestamp;
}

// ---------------------------------------------------------------------------
// Hardware source ports (faked in tests)
// ---------------------------------------------------------------------------

/// Microphone as a stream of PCM frames.
abstract class MicSource {
  Stream<AudioFrame> frames();
}

/// IMU (accelerometer + gyroscope) as a stream of samples.
abstract class SensorSource {
  Stream<ImuSample> samples();
}

/// GPS as a stream of fixes.
abstract class LocationSource {
  Stream<GpsFix> positions();
}

/// On-device keyword spotter — sherpa_onnx lives behind this seam. Given a PCM
/// frame it returns the matched keyword, or null. Tests inject a fake recognizer
/// that fires on cue; the real (non-deterministic, slow) model is exercised only
/// on-device in Cycle 7.
abstract class KeywordRecognizer {
  String? decode(AudioFrame frame);
}

/// Plays the confirmation chime when a keyword fires. Wraps `audioplayers`
/// behind this seam; tests use a fake that records play() calls, and the real
/// AudioplayersChimePlayer is injected in 8d (never touched in unit tests).
abstract class ChimePlayer {
  Future<void> play();
}

/// Requests OS runtime permissions. Real impl wraps permission_handler; tests
/// use a fake with preset grant results.
abstract class PermissionRequester {
  Future<bool> requestAudio();
  Future<bool> requestLocation();
}

/// Provides the Firebase ID token for the ingest API's `Authorization: Bearer`
/// header. Fetched PER REQUEST (tokens expire). Real impl wraps FirebaseAuth and
/// degrades to '' if Firebase isn't configured; tests use a fake.
abstract class TokenSource {
  Future<String> idToken();
}

/// Persists an event's captured audio window to local storage BEFORE upload,
/// returning a reference (file path/key) recorded in the payload so the uploader
/// knows where to find the blob for the signed-URL PUT. Faked in tests; the real
/// FileBlobStore (app documents dir) is injected in main.dart.
abstract class BlobStore {
  Future<String> writeAudio(String eventId, List<int> bytes);
}

// ---------------------------------------------------------------------------
// Ingest API port — Contract 2 (B↔C seam). Hit via a stub server until
// Checkpoint 2, then swapped for C's real API with no code change.
// ---------------------------------------------------------------------------

/// Signed GCS URLs returned by `POST /v1/events`. Blobs (audio WAV, sensor
/// track) are PUT to these — they are NOT sent in the request body.
class UploadUrls {
  const UploadUrls({required this.audioUpload, required this.sensorUpload});

  final String audioUpload;
  final String sensorUpload;
}

/// The three Contract-2 write endpoints. The uploader depends only on this;
/// tests use a FakeIngestClient, integration points it at the stub/real server.
abstract class IngestClient {
  /// `POST /v1/events` (headers: Authorization, Idempotency-Key) → signed URLs.
  Future<UploadUrls> postEvent(EventPayload e, {required String idempotencyKey});

  /// `POST /v1/breadcrumbs` (headers: Authorization, Idempotency-Key) → {ok:true}.
  Future<void> postBreadcrumb(BreadcrumbPayload b, {required String idempotencyKey});

  /// `POST /v1/trips` (header: Authorization) → {ok:true}, idempotent on id.
  Future<void> postTrip(TripPayload t);
}

// ---------------------------------------------------------------------------
// Contract-2 payloads. Fields mirror the FROZEN EventIn/BreadcrumbIn/TripIn
// shapes (00-coordination.md §2). toJson() is pinned test-first in later cycles.
// ---------------------------------------------------------------------------

/// Mirrors Contract-2 `EventIn` (contracts/openapi.yaml). Field names/types and
/// the `toJson()` shape are governed by that frozen schema — see the golden +
/// openapi validation tests in test/event_payload_contract_test.dart.
///
/// `id` doubles as the stable idempotency key: it is sent as the request body
/// `id` AND as the required `Idempotency-Key` header (02-flutter-app.md §7). It
/// is generated once and persisted in Cycle 4, so no separate key field exists.
class EventPayload {
  const EventPayload({
    required this.id,
    required this.tripId,
    required this.tTrigger,
    required this.tPreSeconds,
    required this.tPostSeconds,
    required this.triggerSource,
    this.eventType = 'incident',
    this.severity,
    this.features = const <String, dynamic>{},
    this.rawLat,
    this.rawLon,
    this.rawAccuracyM,
  });

  final String id;
  final String tripId;
  final DateTime tTrigger;
  final double tPreSeconds;
  final double tPostSeconds;
  final String triggerSource; // voice | tap | imu
  final String eventType; // incident (M1); intervention added in M2
  final int? severity; // 1..5, nullable
  final Map<String, dynamic> features; // attributes bag (nearly empty in M1)
  final double? rawLat;
  final double? rawLon;
  final double? rawAccuracyM;

  /// Reconstruct from stored Contract-2 JSON (the outbox persists `toJson()`;
  /// the uploader rebuilds the payload to POST). Lossless round-trip with
  /// [toJson] — see test/event_payload_roundtrip_test.dart.
  factory EventPayload.fromJson(Map<String, dynamic> json) => EventPayload(
        id: json['id'] as String,
        tripId: json['trip_id'] as String,
        tTrigger: DateTime.parse(json['t_trigger'] as String),
        tPreSeconds: (json['t_pre_seconds'] as num).toDouble(),
        tPostSeconds: (json['t_post_seconds'] as num).toDouble(),
        triggerSource: json['trigger_source'] as String,
        eventType: (json['event_type'] as String?) ?? 'incident',
        severity: json['severity'] as int?,
        features: (json['features'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
        rawLat: (json['raw_lat'] as num?)?.toDouble(),
        rawLon: (json['raw_lon'] as num?)?.toDouble(),
        rawAccuracyM: (json['raw_accuracy_m'] as num?)?.toDouble(),
      );

  /// The idempotency key for `POST /v1/events` — the event's own UUID.
  String get idempotencyKey => id;

  /// Serializes to Contract-2 `EventIn`. **Metadata only** — the audio/sensor
  /// blobs are never in the body; the app PUTs them to the signed URLs the API
  /// returns. Key order is fixed so the golden file is stable.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'trip_id': tripId,
        't_trigger': tTrigger.toUtc().toIso8601String(),
        't_pre_seconds': tPreSeconds,
        't_post_seconds': tPostSeconds,
        'trigger_source': triggerSource,
        'event_type': eventType,
        'severity': severity,
        'features': features,
        'raw_lat': rawLat,
        'raw_lon': rawLon,
        'raw_accuracy_m': rawAccuracyM,
      };
}

/// Mirrors Contract-2 `BreadcrumbIn`. `track` is a GeoJSON LineString with
/// coordinates in `[longitude, latitude]` order (built by the breadcrumb logger).
class BreadcrumbPayload {
  const BreadcrumbPayload({
    required this.id,
    required this.tripId,
    required this.track,
    this.motionSummary = const <String, dynamic>{},
  });

  final String id;
  final String tripId;
  final Map<String, dynamic> track; // GeoJSON LineString ([lon, lat] coords)
  final Map<String, dynamic> motionSummary;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'trip_id': tripId,
        'track': track,
        'motion_summary': motionSummary,
      };
}

/// Mirrors Contract-2 `TripIn`. Note the API carries a single
/// `app_config_version` (the config version); the app build version rides in the
/// free-form `device_info` object, which has no dedicated field in the contract.
class TripPayload {
  const TripPayload({
    required this.id,
    required this.userId,
    required this.provider,
    required this.supervision,
    required this.appConfigVersion,
    required this.startedAt,
    this.fsdVersion,
    this.vehicle,
    this.deviceInfo = const <String, dynamic>{},
    this.endedAt,
    this.metrics = const <String, dynamic>{},
  });

  final String id;
  final String userId; // Firebase uid
  final String provider;
  final bool supervision;
  final String appConfigVersion;
  final DateTime startedAt;
  final String? fsdVersion;
  final String? vehicle;
  final Map<String, dynamic> deviceInfo;
  final DateTime? endedAt;
  final Map<String, dynamic> metrics;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'user_id': userId,
        'provider': provider,
        'fsd_version': fsdVersion,
        'supervision': supervision,
        'vehicle': vehicle,
        'device_info': deviceInfo,
        'app_config_version': appConfigVersion,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt?.toUtc().toIso8601String(),
        'metrics': metrics,
      };
}
