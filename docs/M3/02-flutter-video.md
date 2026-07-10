# M3 · 02 — Flutter app: forward video capture

**Additive to M1/M2.** Video is a **new capture module** (`lib/capture/video/`) plus one new
attribute key, `video_ref`, in the existing `features` bag. The voice trigger, GPS breadcrumb,
severity, rich M2 capture, and upload queue are all unchanged — when a trigger fires, the video
module simply **also** persists the buffered window and registers a `video_ref` on the same event.

> **No on-device transcode.** Capture **directly** at the target resolution and codec (720p,
> hardware HEVC). The retired `ffmpeg_kit_flutter` is not used. The phone uploads the raw triggered
> segments; the server concatenates/samples/re-encodes (see `04-backend-video-pipeline.md`).

---

## 1. Config (new keys in `config.v3.json`)

All video behaviour is config-driven from day one (the no-rework rule). Existing v2 keys are
unchanged; v3 only adds a `video` block:

```jsonc
{
  // ... all existing v2 keys (trigger, conditions, providers, grammar_map, gate, ...) ...
  "video": {
    "enabled": true,
    "resolution": "1280x720",
    "codec": "hevc",            // hardware encoder; H.264 fallback if HEVC unsupported
    "fps": 30,
    "segment_seconds": 2,        // ring-buffer granularity (small = tight T_pre/T_post)
    "t_pre_seconds": 10,         // keep this much BEFORE the trigger
    "t_post_seconds": 5,         // keep this much AFTER the trigger
    "ring_capacity_seconds": 30, // rolling window kept in the buffer
    "require_charging": true,    // do not capture video unless charging
    "thermal": {
      "pause_at": "serious",     // ThermalState at/above which video pauses
      "resume_at": "fair"
    },
    "upload": {
      "wifi_preferred": true,
      "allow_cellular": false,   // large files: default Wi-Fi only
      "max_clip_mb": 60
    },
    "blur": {                    // consumed by 03-privacy-blur.md
      "faces_on_device": true,
      "plates_on_device": true,  // best-effort
      "server_fallback": true
    }
  }
}
```

Because everything (resolution, codec, `T_pre`/`T_post`, thermal thresholds) is config, tuning
during M3 field tests is a config push, **not** an app rebuild.

---

## 2. The video ring buffer (segmented, capture-direct)

The M1 ring buffer held audio + sensors. The video buffer is the same *idea* — a rolling window —
but implemented as **short on-disk segment files**, because raw 720p frames are far too large to
hold in memory.

**Approach:** continuously record **N-second segment files** (`segment_seconds`) into a small
rotating pool on disk sized to `ring_capacity_seconds`. Keep a deque of segment paths + their
timestamps. When a trigger fires at time `t`, the persisted window is every segment overlapping
`[t - t_pre, t + t_post]`; the rest keep rotating (oldest deleted).

```dart
// lib/capture/video/video_ring_buffer.dart   (sketch)
class VideoRingBuffer {
  final Duration segment;          // config: segment_seconds
  final Duration capacity;         // config: ring_capacity_seconds
  final _segments = Queue<VideoSegment>(); // {file, startTs, endTs}

  CameraController? _controller;

  Future<void> start(VideoConfig cfg) async {
    _controller = CameraController(
      _selectBackCamera(),
      ResolutionPreset.high,        // request ~720p; verify actual via controller value
      enableAudio: false,           // exterior video; audio already captured by M1 buffer
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _controller!.initialize();
    await _setHevcIfSupported(_controller!, cfg); // platform channel; H.264 fallback
    _loopRecordSegments(cfg);
  }

  // Record fixed-length segments back-to-back; rotate out anything older than capacity.
  Future<void> _loopRecordSegments(VideoConfig cfg) async {
    while (_running) {
      if (!await _gatesPass(cfg)) { await _idle(); continue; } // charging + thermal
      final start = DateTime.now();
      await _controller!.startVideoRecording();
      await Future.delayed(cfg.segmentSeconds);
      final file = await _controller!.stopVideoRecording();
      _segments.add(VideoSegment(file.path, start, DateTime.now()));
      _evictOlderThan(DateTime.now().subtract(cfg.capacity));
    }
  }

  /// Called by the trigger handler. Returns the file paths for the persisted window.
  Future<List<String>> persistWindow(DateTime triggerTs, VideoConfig cfg) async {
    final from = triggerTs.subtract(cfg.tPre);
    final to   = triggerTs.add(cfg.tPost);
    // Segments after the trigger may not exist yet — wait briefly for t_post to elapse.
    await _waitForCoverage(to);
    final keep = _segments.where((s) => s.overlaps(from, to)).toList();
    final dir = await _persistDir(triggerTs);          // move out of the rotating pool
    return [for (final s in keep) await s.copyInto(dir)];
  }
}
```

**Why segment files, not one long recording:** it keeps each file small (cheap to upload, easy to
delete on rotation), it makes `T_pre`/`T_post` selection trivial (pick overlapping segments), and
it never requires re-encoding on device — the server stitches them.

> **HEVC selection:** `camera` exposes resolution presets but codec control is platform-specific.
> Set HEVC via a thin platform channel (iOS `AVCaptureMovieFileOutput` /
> `availableVideoCodecTypes`; Android `MediaRecorder`/`CamcorderProfile`/CameraX `Recorder`).
> If HEVC is unavailable on a device, fall back to H.264 and record that in trip metadata so the
> server knows what it received.

---

## 3. Wiring video into the existing trigger

When the voice trigger (M1) fires and the event is created (M2 rich capture), the handler now
**also** calls `persistWindow` and attaches the result to the event's `features` bag:

```dart
// in the existing trigger/event handler (additive)
final segPaths = await videoRing.persistWindow(event.triggeredAt, cfg.video);
final clipId = _newClipId();
// queue each segment for upload under this clip id; record the reference on the event
await uploadQueue.enqueueClipSegments(clipId, segPaths, event.id);
event.features['video_ref'] = {                 // the ONE new attribute key
  'clip_id': clipId,
  'segments': segPaths.length,
  'codec': cfg.video.codec,
  'resolution': cfg.video.resolution,
  'blur_on_device': cfg.video.blur.facesOnDevice || cfg.video.blur.platesOnDevice,
};
await db.events.update(event);                  // features is JSONB — schema unchanged
```

On-device blur (face/plate) runs **before** the segments are enqueued — see
`03-privacy-blur.md`. The `blur_on_device` flag tells the server whether a fallback pass is
mandatory or just a double-check.

---

## 4. Power & thermal management (mandatory)

Video is the heaviest workload in the project, so the gates are **hard requirements**, all
config-driven:

- **Charging required** (`require_charging: true`): if the phone is not charging, the video module
  stays idle and logs that video was skipped for the trip (audio/sensor capture from M1 still runs,
  so the event is still recorded — just without a clip). Use `battery_plus` to read charging state.
- **Thermal-aware:** poll thermal state; at/above `thermal.pause_at` (e.g. iOS
  `ProcessInfo.thermalState == .serious`, Android `PowerManager` thermal status) **pause** video
  recording and resume at `thermal.resume_at`. Surface a small banner so the operator knows video
  is paused.
- **Storage guard:** before persisting a window, check free space; if low, drop the oldest persisted
  (not-yet-uploaded) clips first and log it.

These gates degrade **gracefully**: losing video never loses the event. That is what keeps M3
additive — an event with no `video_ref` is exactly an M2 event.

---

## 5. Upload: large, Wi-Fi-preferred, resumable

Reuse the M2 hardened uploader (`background_downloader`), with video-specific policy:

- **Default Wi-Fi only** (`allow_cellular: false`): clips wait in the queue until Wi-Fi (e.g. when
  the car is parked at home). The M2 queue-health screen now also shows pending clip MB.
- **Per-segment upload** under a `clip_id` prefix so a partial upload resumes per segment rather
  than restarting the whole clip.
- **Idempotent**: segment object key = `raw/<event_id>/<clip_id>/<segment_index>.mov`; re-upload of
  an existing key is a no-op (matches M1 idempotency).
- Respect `max_clip_mb`: if a persisted window exceeds it (unusually long trigger storm), keep the
  window centred on the trigger and drop the outermost segments, logging the trim.

---

## 6. App structure deltas

```
app/lib/
  capture/
    video/
      video_ring_buffer.dart      # segmented rolling capture (this file)
      video_config.dart           # parses config.v3 "video" block
      hevc_channel.dart           # platform channel for codec selection
      thermal_gate.dart           # charging + thermal + storage gates
    blur/                         # see 03-privacy-blur.md
  upload/
    clip_upload.dart              # enqueueClipSegments(), Wi-Fi policy, idempotent keys
  features/
    video_ref.dart               # builds the features['video_ref'] payload
```

---

## Acceptance checks
- [ ] With `video.enabled=true` and the phone **charging**, a voice trigger persists a clip window
      covering `T_pre`+`T_post` and writes a `features.video_ref` on the event.
- [ ] With the phone **not charging**, the event is still recorded (audio/sensors) and **no** video
      is captured; the skip is logged.
- [ ] Segments are ~`segment_seconds` long, rotate at `ring_capacity_seconds`, and old segments are
      deleted from disk.
- [ ] Capture is **720p HEVC** on supported devices; on unsupported devices it falls back to H.264
      and records the actual codec in trip metadata.
- [ ] Raising device temperature past `thermal.pause_at` pauses video and it resumes at
      `thermal.resume_at`; a banner reflects the state.
- [ ] Clips upload over **Wi-Fi only** by default, per-segment, idempotently, and the queue-health
      screen shows pending clip MB.
- [ ] **No** `ffmpeg_kit_flutter` (or any on-device ffmpeg) in `pubspec.yaml`.
- [ ] An event with video and an event without video are **both valid** and look identical to M2
      except for the presence of `features.video_ref`.

---
**Next:** [`03-privacy-blur.md`](./03-privacy-blur.md) — on-device face/plate blur before clips
leave the phone, with a server-side fallback pass.
