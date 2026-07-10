# Milestone 3 — Video

**Goal:** add **exterior forward video** as evidence behind each incident, plus **AI summaries**, so
any score can be traced to a watchable clip with an auto-generated description and an
auto-assigned category. M3 builds *on* M2 with **no rework**: video is a **new capture module**
plus a single new attribute key (`video_ref`) in the same `features` bag, behind new config keys.
Nothing about M1/M2 capture, scoring, or the existing web views changes — the clip and its summary
are *additive* surfaces hung off events that already exist.

> Why video is last: it carries essentially all the hard real-world constraints — thermal,
> battery, storage, upload size, and privacy. None of them should be allowed to block proving the
> core idea, which is why M1/M2 deliberately shipped without video. Feasibility here is
> **Moderate** (every piece is doable; there are just more constraints to manage at once).

## In scope
- **App:**
  - Windshield-mounted, **forward-facing video** added to the ring buffer; persist **only the
    triggered window** (`T_pre`/`T_post`), never the whole trip.
  - **Capture directly at 720p with hardware HEVC** (no on-device transcode — see the ffmpeg note
    below); **Wi-Fi-preferred**, resumable large-file upload.
  - **Face/plate blurring** before clips leave the device (best-effort; plate blur is the item to
    validate early), with a **server-side fallback pass**.
  - Power/thermal management: **charging required**, thermal-aware capture.
- **Backend:**
  - **Object storage** (GCS) for clips; each clip linked to its event.
  - **Server-side video assembly** (concatenate the buffered segments, sample frames) with FFmpeg
    in Cloud Run Jobs.
  - **AI summarization** — an open-weights **vision-language model** over sampled frames + the
    event's severity/conditions context → human-readable description **and** auto-classification
    into the incident taxonomy.
- **Web UI:**
  - **Evidence on each incident** — clip playback + AI summary + auto-category, surfaced in
    **Segment detail**, **Route worst-stretches**, and the **Compare** view.

## Out of scope (still deferred)
Tesla Fleet API / telemetry, biometrics, learned multi-modal severity weighting. These remain
future-state in the full system design and are recomputable later from stored data.

> ⚠️ **Critical tooling correction (verified June 2026):** `ffmpeg-kit` / `ffmpeg_kit_flutter` is
> **retired** — the project was officially discontinued (announced Jan 6 2025), the repository was
> archived (June 23 2025), and prebuilt binaries were pulled from Maven Central, CocoaPods, and
> pub.dev. **Do not plan any on-device ffmpeg transcoding.** Instead: the phone **captures
> directly** at the target resolution/codec (720p, hardware HEVC) so no transcode is needed, and
> **all** concatenation, frame sampling, and any re-encoding happen **server-side** with FFmpeg in
> Cloud Run Jobs. This is reflected throughout the M3 files.

## Feasibility — **Moderate (most constraints, all manageable)**
- *Thermal / battery / storage* on long drives with continuous capture → mitigation: 720p +
  hardware encode, persist **only** triggered windows, **mandatory** car charging, thermal-aware
  throttling. (Exactly why video is M3, not M1.)
- *Upload size / cost* → mitigation: downscale at capture, keyframe-friendly segments,
  Wi-Fi-preferred, resumable chunked upload.
- *Privacy* (exterior video captures people/plates) → mitigation: on-device blur (faces are
  tractable via ML Kit; plates are harder → best-effort + **server-side fallback pass**), plus a
  retention policy and the legal review flagged in the full design. **Plate-blur reliability is the
  item to validate early in M3.**
- *AI summarization* → mitigation: **sample** frames rather than send full video, batch requests,
  keep summaries **human-verifiable** (the clip is always attached to check against).

## Exit criteria
A user viewing an SF incident can play the exterior clip and read an accurate AI summary +
category; clips upload reliably over Wi-Fi without overheating the phone on a normal drive; faces
are blurred (and plate-blur behaviour is documented). The score → clip → summary chain is intact
end-to-end for real SF incidents.

---

## Build order

```
01 Env deltas ─► 02 App video ─► 03 Privacy blur ─► 04 Backend video ─► 05 AI summary ─► 06 Evidence UI
   (GPU/Vertex,     (camera 720p     (on-device face/    pipeline (GCS,       (VLM over         (clip + summary
    vLLM, server-    HEVC ring        plate blur +        FFmpeg concat &      sampled frames    in the existing
    side ffmpeg,     buffer, persist  server fallback)    frame sampling)      → text + class)   M2 views)
    object store)    triggered win)
```

`03 Privacy blur` is sequenced **immediately after** capture because plate-blur reliability is the
designated early-validation risk — prove it (or prove the server fallback covers it) before
building the upload/AI pipeline on top. `04`→`05` is the server pipeline; `06` is purely additive
UI on top of M2's views.

## File index

| File | What it covers |
|---|---|
| [`01-environment-setup.md`](./01-environment-setup.md) | Deltas vs M1/M2: GPU compute (GCE/Vertex) + vLLM, server-side FFmpeg, on-device ML Kit/ONNX, clip bucket & lifecycle |
| [`02-flutter-video.md`](./02-flutter-video.md) | `camera` 720p HEVC capture, segmented video ring buffer, persist only `T_pre/T_post`, thermal/charging gates, large upload |
| [`03-privacy-blur.md`](./03-privacy-blur.md) | On-device face blur (ML Kit) + plate detection (ONNX, best-effort) + **server-side fallback**, retention policy |
| [`04-backend-video-pipeline.md`](./04-backend-video-pipeline.md) | GCS clip storage, clip↔event linking, server-side FFmpeg concat + frame sampling in Cloud Run Jobs |
| [`05-ai-summarization.md`](./05-ai-summarization.md) | Open-weights VLM (Qwen2.5-VL) via vLLM on GPU, prompt design, auto-classification, Gemini managed fallback |
| [`06-evidence-ui.md`](./06-evidence-ui.md) | Clip playback + AI summary + auto-category in Segment detail / Route worst-stretches / Compare |

## No-rework guarantees honoured here
- Video is a **new capture module** in the app and **one new key** (`video_ref`) in the existing
  `features` JSONB bag — M1/M2 events remain valid and unchanged.
- All new behaviour (video on/off, `T_pre`/`T_post`, target res/codec, thermal thresholds, blur
  toggles) are **new keys** in `config.v3.json` — existing capture/scoring code is structurally
  untouched.
- Scoring is **unchanged**: the milestone summary explicitly marks M3 scoring/comparison as
  "(unchanged)." Video adds *evidence*, not new math.
- Clips and summaries are stored alongside events, so re-summarizing with a better VLM later is a
  **recomputation** over stored clips, not a re-collection.
