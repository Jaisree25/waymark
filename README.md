# Waymark — FSD Benchmark

An open benchmark for **self-driving quality on real roads**. A phone rides shotgun in a car running
FSD; a passenger logs discomfort/intervention events by voice; the backend map-matches each event to
the road it happened on and scores every road segment by `severity ÷ miles`. The result is a
road-level risk map built from real supervised drives.

The full design lives in [`docs/`](docs/README.md). This README is the map of the **code**.

## Milestones

| Milestone | Goal | Status |
|---|---|---|
| **M1** — feasibility / core slice (no video) | Prove capture → ingest → attribution → inspection end to end on real SF drives. | 🚧 in progress |
| **M2** — required features (no video) | The complete public non-video benchmark + 3-view web UI. | planned |
| **M3** — video | Exterior clips, evidence playback, AI summaries. | planned |

## Stack (M1)

Open source wherever possible; the only non-OSS pieces are the managed GCP runtimes that host it.

- **Mobile:** Flutter (iOS + Android), on-device voice trigger (sherpa-onnx), local SQLite queue.
- **Backend:** FastAPI on Cloud Run, PostgreSQL + PostGIS on Cloud SQL, GCS for blobs.
- **Map-matching:** Valhalla (OSS) over OpenStreetMap SF tiles.
- **Infra:** Terraform for every GCP resource; Docker → Artifact Registry.

## Repository layout

M1 is built by three people in parallel, each owning a workstream (see
[docs/M1/Implementation/00-coordination.md](docs/M1/Implementation/00-coordination.md)). Folder
ownership and current status:

| Path | What | Owner | Status |
|---|---|---|---|
| [`contracts/`](contracts/README.md) | Frozen seams: ingest API (OpenAPI) + map-match interface | shared | ✅ scaffolded |
| [`backend/ingest/`](backend/ingest/README.md) | FastAPI ingest API — trips/events/breadcrumbs, signed URLs, auth | Person C | ✅ scaffolded |
| [`backend/mapmatch/`](backend/mapmatch/README.md) | Valhalla client — snaps GPS to OSM way IDs | Person C | ✅ scaffolded |
| [`infra/`](infra/README.md) | Terraform for all GCP resources | Person C | ✅ scaffolded |
| [`inspector/`](inspector/README.md) | Static MapLibre data-quality inspector | Person C | ✅ scaffolded |
| `app/` | Flutter capture app | Person B | planned |
| `db/`, `backend/jobs/`, `backend/scoring/` | Schema, OSM loader, exposure, nightly scoring, exports | Person A | planned |
| `web/` | M2 public web UI | — | M2 |
| [`docs/`](docs/README.md) | Design + milestone implementation plans | — | ✅ |

> Each module folder has its own README with the problem it solves, how it works, and test steps.
> Start there for anything under `backend/`, `contracts/`, `infra/`, or `inspector/`.

## Data flow (M1)

```
Flutter app ──HTTPS──► Cloud Run: FastAPI ingest ──► Cloud SQL (Postgres + PostGIS)
                           │                              ▲
                           ├── signed URL ──► GCS (audio/sensor blobs)
                           └── map-match ──► Valhalla (OSM, SF tiles)

Cloud Scheduler ──nightly──► Cloud Run Job: aggregate ──► scores (severity ÷ miles per road)
                                                              │
                                                    inspector (MapLibre) reads it back
```

## Quick start (backend)

Requires Python 3.12. From the repo root:

```bash
python -m venv backend/ingest/.venv
backend/ingest/.venv/Scripts/python -m pip install -r backend/ingest/requirements-dev.txt
backend/ingest/.venv/Scripts/python -m pytest        # ingest unit tests + mapmatch contract test
```

Expected: ingest unit tests pass; the Valhalla integration tests **xfail** until a local Valhalla is
running (see [backend/mapmatch/README.md](backend/mapmatch/README.md)). Infra is validated with
`terraform validate` in [infra/envs/dev](infra/envs/dev).

## Design rules that prevent rework

Carried from the brief so M1 → M2 → M3 add capability without reworking earlier data:

1. **Config-driven behaviour** — thresholds, windows, gates, and map regions live in versioned config,
   not code.
2. **Core + attributes-bag schema** — events have a small fixed core plus an open `features` JSON bag;
   later milestones add keys, never destructive migrations.
3. **Store raw events + full trips** — every later upgrade is a *recomputation*, never a re-collection.
