# M3 · 03 — Privacy: face & plate blur

Exterior video captures bystanders and license plates, so **blur is a first-class requirement, not
a nice-to-have**. The design treats it as **defence in depth**: best-effort **on-device** blur
before clips leave the phone, plus a **mandatory server-side fallback pass** that re-checks every
clip before it becomes servable. Per the milestone brief, **plate-blur reliability is the item to
validate early in M3** — that is why this file is sequenced right after capture and before the
upload/AI pipeline.

> Honesty about limits: faces are tractable with on-device detection; **plates are harder**
> (small, angled, motion-blurred, varied formats). We therefore (a) do best-effort plate blur on
> device, (b) **always** run a server fallback pass, and (c) **document** measured plate-blur recall
> rather than over-claim. If neither pass is confident, the clip is held (not published) — see §4.

---

## 1. Two-stage architecture

```
 capture (02) ─► ON-DEVICE BLUR ─► upload raw/ ─► SERVER FALLBACK PASS ─► blurred/ (servable) ─► AI summary (05) ─► UI (06)
                 faces: ML Kit                     faces+plates re-detect
                 plates: ONNX (best-effort)        + apply blur to any misses
```

- **On-device** reduces the chance unblurred PII ever leaves the phone (best privacy posture).
- **Server fallback** catches on-device misses, runs heavier models than a phone can, and is the
  **authoritative gate** before a clip is servable. The `raw/` upload is deleted by lifecycle
  shortly after (see `01-environment-setup.md` §5).

---

## 2. On-device: faces (ML Kit) + plates (ONNX)

### Faces — Google ML Kit (on-device, free, no network)
`google_mlkit_face_detection` returns bounding boxes per frame. The challenge is that the captured
segments are **encoded video**, and we are **not** transcoding on device (no ffmpeg). So blur is
applied at one of two points:

- **Preferred:** run detection on the **live camera image stream** during capture (frames are
  available pre-encode via `CameraController.startImageStream`), accumulate blur regions per
  timestamp, and **bake** blur into frames as they are written. On iOS/Android this is done in the
  same platform channel that owns the encoder (apply a Gaussian/pixelate to detected regions in the
  capture pipeline before the frame is handed to the hardware encoder).
- **Fallback if live-stream blur is too costly on a given device:** mark the clip
  `blur_on_device=false` and rely on the **server pass** (which then becomes mandatory, not a
  double-check). The config flag from `02` (`blur.faces_on_device`) lets you turn this per-device.

```dart
// lib/capture/blur/face_blur.dart  (sketch — runs in the capture image-stream path)
final detector = FaceDetector(options: FaceDetectorOptions(
  performanceMode: FaceDetectorMode.fast,   // real-time during capture
  enableContours: false, enableLandmarks: false,
));

Future<List<Rect>> facesIn(CameraImage frame, InputImageRotation rot) async {
  final input = _toInputImage(frame, rot);
  final faces = await detector.processImage(input);
  return faces.map((f) => f.boundingBox.inflate(8)).toList(); // pad the box
}
// regions are passed to the native encoder-side blur (pixelate/Gaussian) before encode.
```

### Plates — ONNX best-effort (on-device)
There is no first-party on-device plate detector, so ship a small **open** license-plate detection
model exported to **ONNX** as a Flutter **asset** and run it with the `onnxruntime` Dart binding.
Treat output as **best-effort**: blur every detected region, but **do not** trust it as sufficient.

```dart
// lib/capture/blur/plate_blur.dart  (sketch)
final session = OrtSession.fromAsset('assets/models/plate_detector.onnx');

Future<List<Rect>> platesIn(Float32List chwTensor, int w, int h) async {
  final out = session.run({'images': OrtValue.tensor(chwTensor, [1,3,h,w])});
  return _decodeBoxes(out, scoreThreshold: 0.25) // low threshold: prefer over-blurring
         .map((b) => b.inflate(6)).toList();
}
```
Choose the score threshold to **favour recall over precision** — an extra blurred non-plate region
is harmless; a missed plate is a privacy failure.

### Applying the blur
Blur regions (faces ∪ plates) are applied as **pixelation or Gaussian** in the native capture
pipeline before the hardware encoder. Pixelation is cheap and irreversible, which is what we want.
Inflate boxes slightly (done above) to cover detector jitter between frames.

---

## 3. Server-side fallback pass (authoritative)

Runs in the **video job** (`backend/video/`, see `04`). It is **mandatory** for every clip,
regardless of `blur_on_device`:

1. **Decode** the uploaded segments with FFmpeg → sampled frames (it already does this for AI
   summaries, so reuse the frames).
2. **Re-detect** faces and plates with heavier server models:
   - faces: an open detector via `opencv`/`onnxruntime` (e.g. a RetinaFace/SCRFD ONNX export);
   - plates: a stronger open plate-detection ONNX model than the phone can run.
3. **Apply blur** to any regions on the **assembled** clip (server re-encode happens here anyway —
   this is the *only* transcode in the system).
4. **Confidence check:** if the server is confident the clip is clean (on-device blur present **and**
   server finds nothing new, **or** server successfully blurred everything it found), promote to
   `blurred/<event_id>/clip.mp4` and mark the event clip `servable=true`.

```python
# backend/video/blur_pass.py  (sketch)
def server_blur_pass(frames, segments_in, clip_out) -> BlurResult:
    regions = detect_faces(frames) + detect_plates(frames)   # heavier ONNX models
    # map frame-time regions onto the assembled timeline, then re-encode with blur applied
    apply_blur_and_reencode(segments_in, regions, clip_out)  # FFmpeg + opencv
    return BlurResult(
        faces=len(regions.faces), plates=len(regions.plates),
        confident=evaluate_confidence(regions),
    )
```

---

## 4. What happens when blur isn't confident

A clip is **never published** unless the privacy gate passes. If the server pass cannot be
confident (e.g. a high-speed plate it could not resolve):

- The clip is **held** (`servable=false`) and **not** shown in the UI; the event still scores
  normally (it's an M2 event with a `video_ref` that simply isn't viewable yet).
- It is flagged for **manual review** in an internal queue (a human can confirm/blur and release,
  or discard the clip).
- The decision is recorded on the event so the UI can show "clip withheld pending review" rather
  than silently dropping evidence.

This keeps the failure mode **safe** (over-withhold) and keeps scoring **unaffected** (video is
additive).

---

## 5. Retention policy (privacy)

Codified in the bucket lifecycle (`01-environment-setup.md` §5) and Terraform:

- `raw/` (as-uploaded, on-device-blurred) segments: **deleted within days** of the server pass.
- `blurred/` (final, servable) clips: retained per the legal/retention review window, then deleted.
- Only `blurred/` clips are ever served to the web UI; `raw/` is never exposed.
- The retention review flagged in the full system design must sign off the windows **before** public
  launch of video evidence.

---

## 6. Early validation (the M3 risk to retire first)

Before building `04`/`05`, run a **plate-blur validation**:

1. Record a labelled SF drive (known plates/faces in frame).
2. Measure **on-device recall**, **server-pass recall**, and **combined recall** for plates and
   faces separately.
3. Decide policy from data: if combined plate recall is below the retention review's bar, the server
   pass + held-clip workflow (§4) must cover the gap — document the measured numbers either way.

This produces a short `docs/m3-blur-validation.md` (numbers + decision) — the M3 analogue of the M1
feasibility report, scoped to privacy.

---

## Acceptance checks
- [ ] On-device face blur is baked into captured frames (or per-device-disabled with the flag set),
      verified by inspecting an as-uploaded `raw/` clip.
- [ ] On-device plate detection runs from the bundled ONNX asset and blurs detected regions
      best-effort (recall-favouring threshold).
- [ ] The **server fallback pass runs on every clip** and re-encodes the assembled clip with any
      additional blur, producing `blurred/<event_id>/clip.mp4`.
- [ ] A clip the server cannot confidently clear is **held** (`servable=false`), not shown in the
      UI, and queued for manual review — while the event still scores.
- [ ] `raw/` is never served; only `blurred/` is exposed to the web UI.
- [ ] Lifecycle deletes `raw/` within the configured window; retention windows are in Terraform.
- [ ] `docs/m3-blur-validation.md` exists with measured face/plate recall and the resulting policy.

---
**Next:** [`04-backend-video-pipeline.md`](./04-backend-video-pipeline.md) — GCS storage, clip↔event
linking, and the server-side FFmpeg concat + frame-sampling job.
