# FSD Benchmark — Implementation Plans (V1, three milestones)

This folder turns the **FSD-Benchmark-v1-Milestones** document into concrete, build-ready
implementation plans. There is one folder per milestone, and each milestone is split into
focused sub-files so no single file becomes unreadable.

| Folder | Milestone | One-line goal |
|---|---|---|
| [`milestone-1/`](./milestone-1/README.md) | **M1 — Feasibility / core slice (no video)** | Prove capture → ingest → attribution → inspection end to end. |
| [`milestone-2/`](./milestone-2/README.md) | **M2 — Required features (no video)** | The complete, public-usable non-video benchmark + 3-view web UI. |
| [`milestone-3/`](./milestone-3/README.md) | **M3 — Video** | Exterior clips, evidence playback, and AI summaries. |

Start at each milestone's own `README.md` — it is the index for that milestone's sub-files
and explains the build order.

---

## Stack decisions (apply to all three milestones)

The source design assumed native iOS (Swift / AVFoundation / Core ML). The two hard constraints
from the brief reshape that:

1. **Data-collection app → Flutter** (single codebase, iOS + Android).
2. **Backend → Google Cloud**, using **open-source frameworks wherever possible**.

Everything below honours "open-source wherever possible": the only non-OSS pieces are the
*managed GCP runtimes* that host the OSS (Cloud Run runs your container, Cloud SQL runs stock
PostgreSQL, etc.). Where a managed Google product competes with an OSS one, the OSS one is named
first and the managed one is offered as a fallback.

| Concern | Choice (open source) | Runs on (GCP) | Notes |
|---|---|---|---|
| Mobile app | **Flutter / Dart** | — | iOS + Android from one codebase, **both first-class from M1**. No Mac needed — iOS is built/signed in cloud CI (see below) |
| On-device voice trigger | **sherpa-onnx** (`sherpa_onnx`, Apache-2.0) keyword spotting | on device | Fully offline KWS, iOS+Android, custom keywords |
| GPS / IMU | `geolocator`, `sensors_plus` (MIT/BSD) | on device | |
| Local store | **SQLite via `drift`** (MIT) | on device | Durable queue + typed schema |
| Background upload | `background_downloader` (resumable) | on device | Wi-Fi-preferred policy |
| Ingest / scoring API | **FastAPI** (Python, MIT) in a container | **Cloud Run** | Autoscaling, scale-to-zero |
| Relational + geo DB | **PostgreSQL + PostGIS** (OSS) | **Cloud SQL for PostgreSQL** | PostGIS is a supported extension |
| Object storage | (standard) | **Google Cloud Storage** | Audio (M1/M2), video (M3) |
| Map-matching / routing | **Valhalla** (OSS) | **Cloud Run / GCE** container | OSM-based; Meili map-matching + route engine |
| Road network data | **OpenStreetMap** (ODbL) | — | SF extract from Geofabrik |
| Batch / nightly jobs | FastAPI/Python job image | **Cloud Run Jobs** + Cloud Scheduler | Airflow (Cloud Composer) only if orchestration grows |
| Stats | **statsmodels / numpy / scipy** (BSD) | Cloud Run Jobs | NB GLM etc. are *post-V1*; M2 uses simple rates |
| Web UI (M2) | **React + Vite + MapLibre GL JS** (OSS) | **Firebase Hosting / Cloud Storage+CDN** | MapLibre line layers for roads |
| Basemap tiles (M2) | **Protomaps / OpenFreeMap** (OSS) | self-host PMTiles on GCS, or OpenFreeMap | Avoids proprietary tile keys |
| On-device blur (M3) | **Google ML Kit face detection** + **ONNX** plate model | on device | Best-effort; server-side fallback pass |
| Video processing (M3) | **FFmpeg** (server-side only) | Cloud Run Jobs / GCE | `ffmpeg-kit` on-device is **retired** — do NOT use it |
| AI summaries (M3) | **open-weights VLM (e.g. Qwen2.5-VL)** via **vLLM** (OSS) | **GCE GPU VM / Vertex AI** | Vertex/Gemini offered only as managed fallback |
| Auth | **Firebase Auth** | GCP | Cheap, first-class Flutter SDK |
| Infra as code | **Terraform** (OSS) | GCP | All cloud resources reproducible |
| Containers | **Docker** (OSS) | Artifact Registry | |
| CI/CD | **GitHub Actions** (or Cloud Build) | GitHub → GCP | |
| iOS builds (no Mac) | **Codemagic** cloud CI (hosted Mac) → **TestFlight** | — | Set up **in M1** so iOS is first-class from day one; a local Mac is needed only for interactive iOS debugging. See `milestone-1/01` §1b |

### Why these are safe choices, not lock-in
- The phone is the *instrument*; nothing about Flutter vs. native changes the science.
- Cloud Run / Cloud SQL run **unmodified OSS** (your FastAPI container, stock Postgres). If you
  ever leave GCP, the container and the SQL move with you.
- Valhalla, PostGIS, MapLibre, FFmpeg, statsmodels, and the VLM weights are all portable.

### One thing the brief forces us to correct
`ffmpeg-kit` / `ffmpeg_kit_flutter` was **officially retired in Jan 2025 and the repo archived in
June 2025** (binaries pulled from Maven/CocoaPods/pub). So M3 deliberately avoids on-device
FFmpeg: the phone **captures directly at the target resolution/codec** (no transcode needed) and
all concatenation / frame-sampling / re-encoding happens **server-side** with FFmpeg in a Cloud
Run Job. See `milestone-3/02-flutter-video.md` and `milestone-3/04-backend-video-pipeline.md`.

---

## The three rules that prevent rework (carried from the brief)

Every plan is written so that M1 → M2 → M3 add capability **without reworking earlier data**:

1. **Config-driven behaviour.** Timing windows, thresholds, keyword grammar, gates, upload
   policy — all live in a versioned config file (bundled in the app, mirrored server-side), from
   day one. Tuning M1 never means a code change.
2. **Core + attributes-bag schema.** Events have a small fixed core (id, trip, time, location,
   severity, type, sync state) plus a typed, open **attributes bag** (`features` JSONB). M2 adds
   emotion/intervention/category/conditions as *bag keys*; M3 adds `video_ref`. No migrations
   that destroy old rows.
3. **Store raw events + full trips.** Raw events and the complete breadcrumb (the denominator)
   are stored verbatim. Every later upgrade — confidence tiers, condition stratification,
   empirical-Bayes shrinkage, learned severity weights — becomes a **recomputation**, never a
   re-collection.

---

## Suggested mono-repo layout

```
fsd-benchmark/
├── app/                      # Flutter app (all milestones; feature-flagged by config)
│   ├── lib/
│   ├── assets/config/        # versioned config files
│   ├── assets/models/        # sherpa-onnx KWS model (+ ONNX plate model in M3)
│   └── pubspec.yaml
├── backend/
│   ├── ingest/               # FastAPI ingest service (Cloud Run)
│   ├── jobs/                 # nightly aggregation / scoring (Cloud Run Jobs)
│   ├── scoring/              # Python scoring package (shared lib)
│   ├── mapmatch/             # Valhalla container + SF tile build
│   └── video/                # M3: ffmpeg sampling + VLM summary worker
├── web/                      # M2: React + Vite + MapLibre viewer
├── infra/                    # Terraform for all GCP resources
│   ├── modules/
│   └── envs/{dev,prod}/
├── db/                       # SQL migrations (sqitch or alembic)
└── docs/                     # this folder + methodology page
```

Each milestone plan references paths inside this layout so the three milestones share one repo.

---

## How to read a milestone plan

Each `milestone-N/` folder contains:
- `README.md` — objective, scope, exit criteria, **build order**, and the file index.
- numbered sub-files (`01-…`, `02-…`) — environment setup first, then app, backend, UI, and
  (M1) the feasibility test protocol.

Sub-files are written to be followed top-to-bottom by an engineer with a fresh machine: install
commands, version pins (as caret ranges — verify the newest patch at build time), config
snippets, Dockerfiles, `gcloud`/Terraform commands, and acceptance checks.
