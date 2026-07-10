# M1 · 02 — Flutter app (capture + queue + config)

The M1 app is a **data-collection instrument**, not a product. It must: listen for a spoken
trigger offline, keep a rolling audio+sensor ring buffer, persist the window around a trigger,
log a continuous GPS breadcrumb (the denominator), tag 1–5 severity by voice, store everything
durably, and upload in the background. Every tunable is read from a **config file**.

---

## 1. Create the project and pin packages

```bash
cd app
flutter create --org com.fsdbench --platforms=ios,android .
```

`pubspec.yaml` (verify newest patch versions at build time; these are floors):

```yaml
name: fsd_app
environment:
  sdk: ">=3.5.0 <4.0.0"
  flutter: ">=3.29.0"

dependencies:
  flutter:
    sdk: flutter

  # --- capture ---
  sherpa_onnx: ^1.13.0          # on-device keyword spotting (Apache-2.0), iOS+Android, offline
  record: ^5.1.0                # mic capture as a PCM stream (for ring buffer + KWS feed)
  geolocator: ^13.0.0           # GPS, with horizontalAccuracy
  sensors_plus: ^6.0.0          # accelerometer + gyroscope (IMU)
  audioplayers: ^6.1.0          # confirmation chime

  # --- storage / state ---
  drift: ^2.20.0                # typed SQLite ORM (durable local store + upload queue)
  sqlite3_flutter_libs: ^0.5.0
  path_provider: ^2.1.0
  path: ^1.9.0

  # --- upload ---
  background_downloader: ^9.0.0 # resumable background up/downloads, Wi-Fi-preferred
  connectivity_plus: ^6.0.0     # detect Wi-Fi vs cellular

  # --- config / misc ---
  yaml: ^3.1.0                  # parse the config file (or use json)
  firebase_core: ^3.6.0
  firebase_auth: ^5.3.0
  uuid: ^4.5.0
  logging: ^1.2.0

dev_dependencies:
  drift_dev: ^2.20.0
  build_runner: ^2.4.0
  flutter_lints: ^4.0.0

flutter:
  assets:
    - assets/config/config.v1.json
    - assets/models/kws/        # sherpa-onnx keyword-spotting model files
    - assets/audio/chime.wav
```

```bash
flutter pub get
dart run build_runner build     # generates drift code (after you define tables, §6)
```

### Platform permissions
- **iOS** (`ios/Runner/Info.plist`): `NSMicrophoneUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`,
  `UIBackgroundModes` → `audio`, `location`, `fetch`, `processing`.
- **Android** (`AndroidManifest.xml`): `RECORD_AUDIO`, `ACCESS_FINE_LOCATION`,
  `ACCESS_BACKGROUND_LOCATION`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`,
  `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`, `INTERNET`, `WAKE_LOCK`.

A persistent **foreground service** (Android) and the `audio`+`location` background modes (iOS)
are what keep capture alive while the phone is mounted and the screen is off.

---

## 2. The config file (load-bearing — established in M1, extended later)

`assets/config/config.v1.json`. Nothing about capture behaviour is hard-coded.

```json
{
  "config_version": "1.0.0",
  "trigger": {
    "keywords": ["log it", "log scary", "mark level one", "mark level two",
                 "mark level three", "mark level four", "mark level five"],
    "kws_model_dir": "assets/models/kws",
    "kws_score_threshold": 1.5,
    "confirm_chime": true
  },
  "ring_buffer": {
    "t_pre_seconds": 15,
    "t_post_seconds": 8,
    "audio_sample_rate_hz": 16000,
    "audio_chunk_seconds": 2,
    "max_retained_chunks": 16
  },
  "breadcrumb": {
    "gps_hz": 1.0,
    "imu_summary_seconds": 5,
    "min_horizontal_accuracy_m": 50
  },
  "scoring": {
    "min_mileage_gate_miles": 5.0,
    "severity_scale_max": 5
  },
  "upload": {
    "wifi_preferred": true,
    "allow_cellular": false,
    "max_retries": 8,
    "backoff_base_seconds": 5
  },
  "trip_defaults": {
    "provider": "tesla",
    "supervision": true
  }
}
```

A `ConfigService` loads this at startup and exposes typed getters. **Rule:** if you find yourself
typing a number into capture/upload code, it belongs here instead.

> In M2 the *same file* gains `emotion`, `intervention`, `category`, `conditions`, and provider
> modes — additive keys, no code restructuring. In M3 it gains a `video` block.

---

## 3. Voice trigger (sherpa-onnx keyword spotting, fully offline)

sherpa-onnx ships a Dart/Flutter API with a dedicated **keyword spotter**. Bundle a pre-trained
English KWS model (e.g. the `sherpa-onnx-kws-zipformer-gigaspeech` model) under
`assets/models/kws/` and list custom keywords — the model is open-vocabulary, so the command
grammar is just text you provide.

Pipeline: `record` streams 16 kHz mono PCM → feed the same stream to (a) the KWS recognizer and
(b) the audio ring buffer. When the spotter fires, bookmark the buffer and play the chime.

```dart
// lib/capture/voice_trigger.dart  (sketch)
final kws = await sherpa.KeywordSpotter.create(
  model: cfg.trigger.kwsModelDir,
  keywords: cfg.trigger.keywords,
  threshold: cfg.trigger.kwsScoreThreshold,
);

final stream = await audioRecorder.startStream(
  RecordConfig(encoder: AudioEncoder.pcm16bits,
               sampleRate: cfg.ringBuffer.audioSampleRateHz, numChannels: 1));

stream.listen((pcmChunk) {
  ringBuffer.add(pcmChunk);                 // §4
  final hit = kws.decode(pcmChunk);         // returns matched keyword or null
  if (hit != null) onTrigger(keyword: hit); // §5
});
```

`onTrigger` parses the keyword into `event_type` + severity (e.g. `"mark level four"` → severity
4) using the grammar in config — so the passenger encodes severity by voice with no screen
interaction.

**Why sherpa-onnx and not a cloud STT:** the trigger must work offline in a moving car with no
latency budget, and "every parameter in a config file" includes the keyword list. It's Apache-2.0
and runs on the A13 / mid-range Android. Measuring its hit/false-positive rate **is M1 risk #1**.

A **fallback trigger** (a full-width on-screen tap target, plus optional BLE button later) exists
during the test phase so a missed keyword never loses an event — the fallback's usage rate is
itself a measurement.

---

## 4. Audio + sensor ring buffer (no video in M1)

A ring buffer is just a bounded, time-indexed queue. Without video this is light (a few hundred
KB), so it lives in memory + short rotating files.

- **Audio:** keep the last `max_retained_chunks` PCM chunks (each `audio_chunk_seconds`),
  covering `t_pre + t_post + margin`. On trigger, concatenate the chunks spanning
  `[t_trigger − t_pre, t_trigger + t_post]` into one WAV and persist it.
- **Sensors:** GPS, accelerometer, and gyro samples are timestamped on **one monotonic clock**
  (use a single `Stopwatch`-based epoch, not wall-clock, to align channels) and held in parallel
  ring lists. On trigger, slice the same window and persist a synchronized sensor track (JSON or
  a small binary blob).

```dart
class RingBuffer<T> {
  final Duration window;
  final _items = <(_Ts, T)>[];           // (monotonic timestamp, sample)
  void add(_Ts t, T sample) {
    _items.add((t, sample));
    final cutoff = t - window;
    while (_items.isNotEmpty && _items.first.$1 < cutoff) _items.removeAt(0);
  }
  List<T> slice(_Ts from, _Ts to) =>
      [for (final e in _items) if (e.$1 >= from && e.$1 <= to) e.$2];
}
```

All sizes/durations come from config so M1 tuning is config-only.

---

## 5. Trip + breadcrumb logger (the denominator)

The breadcrumb is what turns counts into rates. It runs for the **entire trip**, independent of
triggers.

- GPS at `breadcrumb.gps_hz` (≈1 Hz) via `geolocator`'s position stream, storing
  `lat, lon, horizontalAccuracy, speed, timestamp`. **Store `horizontalAccuracy`** — M1 risk #2
  needs it.
- Periodic IMU summaries (`mean`/`var` of accel over `imu_summary_seconds`), not the raw stream,
  to keep the breadcrumb tiny.
- A 1-hour drive ≈ 3,600 GPS points ≈ a few hundred KB — negligible.

A **Trip** wraps the drive: `provider, fsd_version, supervision_flag, vehicle, device_info,
start/end, app_config_version`. Trip start/stop is a single button; defaults come from
`trip_defaults` in config.

---

## 6. Local durable store + upload queue (drift / SQLite)

Every artifact is written to SQLite **before** any upload attempt, each with a `sync_state`
(`pending → uploading → acked → done`, plus `failed/retry`). This is the offline-first guarantee.

Schema mirrors the backend **core + attributes bag** so the app and server agree:

```dart
// lib/data/tables.dart  (drift)
class Trips extends Table {
  TextColumn get id => text()();                 // uuid
  TextColumn get provider => text()();
  TextColumn get fsdVersion => text().nullable()();
  BoolColumn get supervision => boolean()();
  TextColumn get deviceInfo => text()();
  TextColumn get appConfigVersion => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  TextColumn get syncState => text().withDefault(const Constant('pending'))();
  @override Set<Column> get primaryKey => {id};
}

class Events extends Table {
  TextColumn get id => text()();
  TextColumn get tripId => text().references(Trips, #id)();
  DateTimeColumn get tTrigger => dateTime()();
  RealColumn  get tPreSeconds => real()();
  RealColumn  get tPostSeconds => real()();
  TextColumn  get triggerSource => text()();     // voice | tap | imu
  TextColumn  get eventType => text()();          // incident (M1); intervention added in M2
  IntColumn   get severity => integer().nullable()(); // 1..5 (voice)
  TextColumn  get features => text().withDefault(const Constant('{}'))(); // JSON attributes bag
  TextColumn  get audioRef => text().nullable()(); // local file path → uploaded blob key
  TextColumn  get sensorRef => text().nullable()();
  TextColumn  get syncState => text().withDefault(const Constant('pending'))();
  @override Set<Column> get primaryKey => {id};
}

class BreadcrumbSegments extends Table {
  TextColumn get id => text()();
  TextColumn get tripId => text().references(Trips, #id)();
  TextColumn get polyline => text()();           // encoded points + accuracy + ts
  TextColumn get motionSummary => text()();      // JSON: mean/var accel
  TextColumn get syncState => text().withDefault(const Constant('pending'))();
  @override Set<Column> get primaryKey => {id};
}
```

The empty-ish `features` JSON column is deliberate: M2 writes emotion/intervention/category into
it without a schema change.

---

## 7. Background, resumable, Wi-Fi-preferred upload

Use `background_downloader` for uploads of the audio clip, sensor track, breadcrumb, and trip
JSON. Apply the config policy:

```dart
final task = UploadTask(
  url: '$ingestBase/v1/events/$eventId/audio',
  filename: localWavPath,
  headers: {'Authorization': 'Bearer $idToken',
            'Idempotency-Key': eventId},        // server dedupes on this
  requiresWiFi: cfg.upload.wifiPreferred && !cfg.upload.allowCellular,
  retries: cfg.upload.maxRetries,
  updates: Updates.statusAndProgress,
);
await FileDownloader().enqueue(task);
```

- **Idempotency keys** = the event/segment UUID, so a retried upload never duplicates.
- **Wi-Fi-preferred:** `requiresWiFi` honours the config; a user toggle can allow cellular.
- On `acked`, advance `sync_state` and (optionally) delete the local blob to reclaim space.
- Structured records (event/trip/breadcrumb JSON) go to the ingest API; the audio WAV and sensor
  blob go to a signed-URL GCS upload the API hands back (see `03-backend-gcp.md §4`).

---

## 8. App structure

```
lib/
├── main.dart                 # Firebase init, config load, route to capture screen
├── config/config_service.dart
├── capture/
│   ├── voice_trigger.dart    # sherpa-onnx KWS
│   ├── ring_buffer.dart
│   ├── audio_recorder.dart   # record stream → KWS + ring
│   ├── sensors.dart          # geolocator + sensors_plus, monotonic clock
│   └── trip_controller.dart  # start/stop trip, breadcrumb logger
├── data/
│   ├── tables.dart           # drift schema (§6)
│   ├── db.dart               # drift database
│   └── repo.dart             # write events/trips/breadcrumbs, sync_state transitions
├── upload/
│   └── upload_service.dart   # background_downloader + connectivity policy
└── ui/
    ├── capture_screen.dart   # big trip start/stop, severity fallback tap, status, mileage
    └── debug_screen.dart     # local event/trip list, trigger counters (feeds §05 metrics)
```

A minimal UI is intentional: a big **Start/Stop trip** button, a large **fallback tap-to-log**
target, a live readout (mileage, last trigger, queue depth, temperature if available), and a
debug list. The passenger should almost never look at it.

---

## 9. Instrumentation the feasibility report depends on

Build these counters in from the start (they are the M1 deliverable, see `05`):
- trigger attempts vs. detections vs. fallback taps (risk #1),
- per-fix `horizontalAccuracy` distribution (risk #2),
- battery %, thermal state (`Battery`/`ProcessInfo.thermalState` on iOS via a small platform
  channel; Android `BatteryManager`), disk used per hour (risk #4),
- upload success/failure/retry counts and bytes on cellular vs Wi-Fi (risk #4).

Log them locally and ship them as a `trip_metrics` blob with each trip.

---

## 10. Acceptance checks for this file

- [ ] App installs on a real iPhone and a real Android phone and records a trip with the screen off.
- [ ] Saying a configured keyword persists a clip whose window matches `t_pre/t_post` and plays the chime.
- [ ] The breadcrumb accumulates ~1 Hz GPS with `horizontalAccuracy` for the whole trip.
- [ ] Killing the network mid-trip still produces durable local rows; reconnecting drains the queue.
- [ ] Every tunable used by capture/upload is read from `config.v1.json` (grep for magic numbers = none).

Next: [`03-backend-gcp.md`](./03-backend-gcp.md).
