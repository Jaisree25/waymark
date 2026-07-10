# M3 · 01 — Environment setup (deltas vs M1 & M2)

This file lists **only what M3 adds** on top of the M1 (`milestone-1/01-environment-setup.md`) and
M2 (`milestone-2/01-environment-setup.md`) environments. Everything there — Flutter toolchain,
Python 3.12 backend venv, Docker, Terraform, gcloud, Cloud Run / Cloud SQL / GCS, Firebase Auth,
the React/Vite web stack — still applies unchanged. M3 introduces three new capability areas:

1. **GPU compute** to run an open-weights vision-language model (VLM) for AI summaries.
2. **Server-side FFmpeg** for clip assembly + frame sampling (the *only* place transcoding happens).
3. **On-device CV libraries** for face/plate blur in the Flutter app.

> Reminder (see the milestone README): **no on-device ffmpeg.** `ffmpeg_kit_flutter` is retired and
> its binaries are gone. The phone captures directly at 720p/HEVC; FFmpeg lives **only** on the
> server.

---

## 1. New version floors (verify latest at install time)

| Tool / library | Floor used here | Where | Notes |
|---|---|---|---|
| FFmpeg | `>= 6.1` | server (Docker) | static build in the video-job image; **not** on device |
| vLLM | `>= 0.6.x` | GPU host | OpenAI-compatible server for the VLM |
| Qwen2.5-VL (open weights) | 7B (start) / 32B (if budget) | GPU host | served by vLLM; verify current best open VLM at build time |
| NVIDIA driver + CUDA | driver `>= 550`, CUDA `12.x` | GPU host | match the vLLM/torch wheel you install |
| `google_mlkit_face_detection` | `^0.13.x` | Flutter app | on-device face detection for blur |
| `onnxruntime` (Dart/Flutter binding) | `^1.x` | Flutter app | runs the best-effort plate-detection ONNX model |
| `camera` (Flutter) | `^0.11.x` | Flutter app | 720p HEVC capture; see `02-flutter-video.md` |
| `video_player` (Flutter) | `^2.x` | Flutter app | local clip preview before upload (optional) |
| `onnxruntime` (Python) | `^1.x` | server (fallback blur) | server-side plate/face fallback pass |
| `opencv-python-headless` | `^4.x` | server | draw/apply blur regions server-side |

All caret/`>=` pins are **floors**; check pub.dev / PyPI for the current patch and prefer the
latest stable. Pin exact versions in lockfiles once chosen.

---

## 2. GPU compute for the VLM

You have two open/standard options. **Pick one; both keep the model open-weights.**

### Option A — Self-managed GCE GPU VM (most control, cheapest at steady load)
```bash
# An L4 is a good cost/perf fit for a 7B VLM; A10G/A100 for larger. Check current GPU availability
# per zone before committing.
gcloud compute instances create vlm-host \
  --project="$PROJECT_ID" \
  --zone=us-west1-a \
  --machine-type=g2-standard-8 \
  --accelerator=type=nvidia-l4,count=1 \
  --maintenance-policy=TERMINATE \
  --image-family=common-cu124-debian-12 \
  --image-project=deeplearning-platform-release \
  --boot-disk-size=200GB \
  --metadata="install-nvidia-driver=True"
```
Then on the VM:
```bash
# Install vLLM into a dedicated venv (matches the M1 backend Python discipline)
python3.12 -m venv ~/vllm-venv && source ~/vllm-venv/bin/activate
pip install --upgrade pip
pip install "vllm>=0.6"            # pulls a compatible torch+CUDA wheel; verify CUDA match
# Serve an OpenAI-compatible endpoint (model name is illustrative — confirm current weights)
vllm serve Qwen/Qwen2.5-VL-7B-Instruct \
  --port 8000 --gpu-memory-utilization 0.90 --max-model-len 8192
```

### Option B — Vertex AI (managed)
Deploy the same open-weights VLM to a **Vertex AI endpoint** (custom container running vLLM, or
Vertex Model Garden if the model is listed). More expensive per hour but no driver/VM babysitting
and it autoscales to zero between nightly batches. Good if summaries run as an infrequent batch.

> **Cost control:** AI summaries are **batched** (nightly, like the other jobs), so the GPU does
> **not** need to run 24/7. With Option A, **stop the VM** when idle (`gcloud compute instances
> stop vlm-host`) and start it for the batch; with Option B, the endpoint scales to zero.

### Managed fallback
Keep a **Gemini** (managed, multimodal) path behind the same internal interface as a fallback for
when the self-hosted VLM is down or a clip is unusually hard. This is a *fallback*, not the
default — the open-weights model is the primary per the open-source-wherever-possible constraint.
See `05-ai-summarization.md`.

---

## 3. Server-side FFmpeg (clip assembly + frame sampling)

FFmpeg runs **only** in the backend video job container — never on device. Add it to the
`backend/video/` job image:

```dockerfile
# backend/video/Dockerfile  (excerpt — full image in 04-backend-video-pipeline.md)
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg ca-certificates && rm -rf /var/lib/apt/lists/*
# python deps for the pipeline + fallback blur
RUN pip install --no-cache-dir \
        google-cloud-storage psycopg[binary] opencv-python-headless onnxruntime numpy pillow
```

Verify it: `ffmpeg -version` should report `>= 6.1`. Confirm the build includes the decoders you
need (HEVC in, H.264 out for broad browser playback — see `04`).

---

## 4. On-device CV libraries (Flutter)

Add to the app's `pubspec.yaml` (additive to M1/M2):
```yaml
dependencies:
  camera: ^0.11.0                      # 720p HEVC capture
  google_mlkit_face_detection: ^0.13.0 # on-device face boxes for blur
  onnxruntime: ^1.16.0                 # best-effort plate detection (ONNX model bundled as asset)
  video_player: ^2.9.0                 # optional local preview
```
iOS: ML Kit needs a CocoaPods install (`cd ios && pod install`) and a minimum iOS deployment
target bump if prompted. Android: ML Kit raises `minSdkVersion` (commonly 21+); confirm against
the M1 floor. The plate-detection ONNX model is shipped as a Flutter **asset** — declare it under
`flutter: assets:`. Details and the blur pipeline are in `03-privacy-blur.md`.

---

## 5. Object storage for clips (GCS) + lifecycle

Clips are larger and more sensitive than the audio/sensor blobs from M1, so they get their own
bucket with an explicit **retention/lifecycle** policy (privacy requirement).

```bash
# Dedicated bucket for triggered video clips (region-matched to the rest of the stack)
gcloud storage buckets create gs://${PROJECT_ID}-clips \
  --location=us-west1 --uniform-bucket-level-access

# Lifecycle: delete raw (pre-blur) uploads quickly; keep blurred clips per retention policy.
cat > /tmp/lifecycle.json <<'JSON'
{
  "rule": [
    { "action": {"type": "Delete"},
      "condition": {"age": 7, "matchesPrefix": ["raw/"]} },
    { "action": {"type": "Delete"},
      "condition": {"age": 365, "matchesPrefix": ["blurred/"]} }
  ]
}
JSON
gcloud storage buckets update gs://${PROJECT_ID}-clips --lifecycle-file=/tmp/lifecycle.json
```
Prefix convention: `raw/<event_id>/...` for the as-uploaded (already on-device-blurred) segments
that the server pass re-checks, and `blurred/<event_id>/clip.mp4` for the final servable clip.
The `raw/` deletion window gives the server fallback pass time to run, then removes the
pre-final material. Tune ages to the legal/retention review.

> Add the clips bucket and lifecycle to **Terraform** (`infra/`) alongside the M1 buckets so the
> retention policy is code-reviewed and reproducible — privacy posture should not be a console
> click.

---

## 6. New IAM / service accounts
- The **video job** SA needs: read app uploads bucket, read/write `${PROJECT_ID}-clips`, read DB
  (Cloud SQL connector), and call the VLM endpoint (or Vertex / Gemini).
- The **VLM host** (Option A) SA needs: read `${PROJECT_ID}-clips` (to pull sampled frames if you
  push frame extraction to it) — though by default frames are sampled in the video job and sent
  inline, so this can stay minimal.
- Grant least privilege; reuse the M1 pattern of one SA per job.

---

## Acceptance checks
- [ ] GPU host serves the open-weights VLM: a `curl` to the OpenAI-compatible `/v1/chat/completions`
      with a test image returns a description.
- [ ] GPU host can be **stopped/started** (Option A) or **scales to zero** (Option B) — verified the
      batch model, not 24/7.
- [ ] `backend/video` image builds and `ffmpeg -version` ≥ 6.1 inside it, with HEVC decode + H.264
      encode available.
- [ ] Flutter app builds on iOS **and** Android with `camera`, `google_mlkit_face_detection`,
      `onnxruntime` added; ML Kit pod/Gradle constraints resolved.
- [ ] `${PROJECT_ID}-clips` bucket exists with uniform access + the lifecycle policy applied, and
      both are defined in Terraform.
- [ ] Video-job SA has least-privilege access to uploads, clips bucket, DB, and the VLM endpoint.
- [ ] Confirmed (again, in writing) that **no** on-device ffmpeg dependency is present in
      `pubspec.yaml`.

---
**Next:** [`02-flutter-video.md`](./02-flutter-video.md) — capturing 720p HEVC into a video ring
buffer and persisting only the triggered window.
