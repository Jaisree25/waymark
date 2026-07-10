# M3 · 04 — Backend: video pipeline

The backend gains a **new service area**, `backend/video/`, that turns uploaded raw segments into a
single servable, blurred clip plus a set of sampled frames for the AI summarizer. It runs as a
**Cloud Run Job** triggered after upload (or on the nightly schedule, like the other jobs). This is
the **only** place transcoding happens — FFmpeg lives here, never on device.

> Pipeline at a glance:
> `raw/ segments` → **concat** (FFmpeg) → **sample frames** (FFmpeg) → **server blur pass** (03) →
> **re-encode to H.264** → `blurred/clip.mp4` + frames → hand frames to **AI summary** (05).

---

## 1. Schema additions (additive, no rework)

Video metadata gets a small dedicated table keyed to the existing `events`; the event itself only
ever carried the `features.video_ref` pointer from `02`, so M1/M2 rows are untouched.

```sql
-- db/migrations/m3_video.sql
CREATE TABLE clips (
  clip_id        text PRIMARY KEY,            -- matches features.video_ref.clip_id
  event_id       uuid NOT NULL REFERENCES events(event_id),
  codec_in       text,                        -- 'hevc' | 'h264' (what the phone sent)
  segments_in    int,
  blur_on_device boolean,
  status         text NOT NULL DEFAULT 'uploaded',
                 -- uploaded → assembling → blurred → summarized → servable | held | failed
  servable       boolean NOT NULL DEFAULT false,
  clip_uri       text,                         -- gs://.../blurred/<event_id>/clip.mp4
  duration_s     numeric,
  blur_faces     int,                          -- counts from the server pass (03)
  blur_plates    int,
  blur_confident boolean,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX clips_event_idx  ON clips(event_id);
CREATE INDEX clips_status_idx ON clips(status);

-- AI summary lands in its own table (see 05) so re-summarizing is a recomputation:
CREATE TABLE clip_summaries (
  clip_id      text PRIMARY KEY REFERENCES clips(clip_id),
  model        text NOT NULL,                  -- e.g. 'qwen2.5-vl-7b' | 'gemini-fallback'
  summary      text NOT NULL,
  auto_category text,                          -- mapped into the SAME incident taxonomy as M2
  raw_json     jsonb,                          -- full model output for audit
  created_at   timestamptz NOT NULL DEFAULT now()
);
```

`auto_category` reuses the **same incident taxonomy** as the M2 manual `category` — so the UI can
show "operator said X / AI said Y" with no new vocabulary.

---

## 2. The video job (Cloud Run Job)

```python
# backend/video/run_job.py  (sketch — orchestration)
def process_clip(clip_id: str):
    clip = db.get_clip(clip_id); db.set_status(clip_id, "assembling")
    seg_paths = gcs.download_segments(clip.event_id, clip_id)        # raw/<event>/<clip>/*.mov

    # 1) concat segments into a single working file (no re-encode yet, stream copy if same codec)
    working = ffmpeg_concat(seg_paths)                               # -f concat -c copy when possible

    # 2) sample frames for blur re-check AND for the VLM (one extraction, reused)
    frames = ffmpeg_sample_frames(working, fps=cfg.sample_fps)       # e.g. 1–2 fps

    # 3) authoritative server blur pass (03) → regions, then re-encode with blur to H.264
    db.set_status(clip_id, "blurred")
    blur = server_blur_pass(frames, working)                        # returns regions + confidence
    if not blur.confident:
        db.hold_clip(clip_id, blur); return                         # status='held', servable=false
    clip_out = ffmpeg_apply_blur_h264(working, blur.regions)        # ONLY transcode in the system

    # 4) store the servable clip; raw/ will be lifecycle-deleted
    uri = gcs.upload_blurred(clip.event_id, clip_out)               # blurred/<event>/clip.mp4
    db.set_clip_servable(clip_id, uri, duration_of(working), blur)

    # 5) hand sampled frames to the AI summarizer (05)
    db.set_status(clip_id, "summarized" if summarize_clip(clip_id, frames) else "servable")
```

### FFmpeg specifics
- **Concat:** write a concat list of the ordered segments; use `-c copy` when all segments share a
  codec (fast, lossless). Only fall back to decode+encode if segments are mixed (e.g. HEVC + an
  H.264 fallback segment).
- **Frame sampling:** `ffmpeg -i working.mp4 -vf fps=<sample_fps> frame_%04d.jpg`. One extraction
  serves **both** the blur re-check and the VLM, so we never decode twice.
- **Output codec = H.264** for the servable clip: broadest browser `<video>` compatibility. (HEVC in
  the browser is inconsistent.) This re-encode is also where the server blur is burned in.
- **Faststart:** add `-movflags +faststart` so the clip streams without a full download.

### Why a Cloud Run Job (not a request handler)
Assembly + blur + re-encode + frame sampling is **CPU-heavy and bursty**. A Job:
- scales to zero between batches (cost),
- has a long timeout (clips can take a while),
- matches the M1/M2 nightly-job pattern (Cloud Run Jobs + Cloud Scheduler),
- is independently retryable per `clip_id` (idempotent — re-running re-derives `blurred/` from
  `raw/`).

Trigger options: (a) **nightly batch** over `clips WHERE status='uploaded'` (simplest, matches
existing schedule); or (b) **event-driven** via a GCS "object finalize" notification → Pub/Sub →
Job, if you want clips ready sooner. Start with (a); (b) is a later optimization with no schema
change.

---

## 3. Container & deploy

```dockerfile
# backend/video/Dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg ca-certificates && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
        google-cloud-storage "psycopg[binary]" opencv-python-headless \
        onnxruntime numpy pillow requests
COPY backend/video /app/video
WORKDIR /app
ENTRYPOINT ["python", "-m", "video.run_job"]
```

```bash
# build, push, deploy as a Job (region us-west1, matching the stack)
gcloud builds submit --tag us-west1-docker.pkg.dev/$PROJECT_ID/fsd/video-job backend/video
gcloud run jobs create video-job \
  --image us-west1-docker.pkg.dev/$PROJECT_ID/fsd/video-job \
  --region us-west1 --cpu 4 --memory 8Gi --task-timeout 3600 \
  --set-cloudsql-instances "$PROJECT_ID:us-west1:fsd-pg" \
  --service-account video-job@$PROJECT_ID.iam.gserviceaccount.com
# nightly, after the M2 aggregation job
gcloud scheduler jobs create http video-job-nightly \
  --schedule "30 3 * * *" --uri "<run-jobs-execute-url>" --http-method POST \
  --oauth-service-account-email scheduler@$PROJECT_ID.iam.gserviceaccount.com
```

(Add all of this to Terraform in `infra/` alongside the M1/M2 jobs.)

---

## 4. Read API additions

The existing M2 read API (`backend/ingest` read endpoints) gains clip fields. **No new top-level
views** — evidence is attached to the event objects the UI already fetches:

- `GET /v1/segment/{way_id}` — each incident in the list now includes, when present and servable:
  `clip_url` (a **signed**, time-limited GCS URL to `blurred/clip.mp4`), `clip_status`,
  `ai_summary`, `auto_category`.
- `GET /v1/route` worst-stretches and `GET /v1/compare` matched-segment incidents: same additive
  fields.
- Clips are served via **short-lived signed URLs** only; the bucket is private. Held/non-servable
  clips return `clip_status` but **no** URL.

```python
# additive serializer
def event_with_evidence(ev):
    base = event_to_json(ev)                       # unchanged M2 shape
    clip = db.get_clip_for_event(ev.event_id)
    if clip and clip.servable:
        base["clip_url"] = gcs.signed_url(clip.clip_uri, ttl=600)
        base["clip_status"] = clip.status
        base["ai_summary"] = clip.summary
        base["auto_category"] = clip.auto_category
    elif clip:
        base["clip_status"] = clip.status          # 'held' / 'assembling' / etc., no URL
    return base
```

Because these are **added fields** on existing objects, the M2 web views keep working untouched;
`06-evidence-ui.md` just renders them when present.

---

## Acceptance checks
- [ ] Uploaded raw segments for a `clip_id` are concatenated (stream-copy when same codec) into one
      working file.
- [ ] Frames are sampled **once** and reused for both blur re-check and AI summary.
- [ ] The servable output is **H.264 + faststart** with the server blur burned in, stored at
      `blurred/<event_id>/clip.mp4`.
- [ ] `clips` row transitions uploaded → assembling → blurred → (summarized) → servable, or → held
      when blur isn't confident; the job is **idempotent** per `clip_id`.
- [ ] The job runs as a Cloud Run Job (scales to zero), wired to Cloud Scheduler after the M2
      aggregation, defined in Terraform.
- [ ] `GET /v1/segment/{way_id}` returns `clip_url` (signed, short TTL) + `ai_summary` +
      `auto_category` **only** for servable clips; held clips return status without a URL.
- [ ] M2 views still function with the added fields absent (events with no clip).

---
**Next:** [`05-ai-summarization.md`](./05-ai-summarization.md) — running the open-weights VLM over
sampled frames to produce the description + auto-category.
