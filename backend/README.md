# backend — M1 services (Person C)

## Purpose

The Python backend for M1. It has four jobs from [docs/M1/03-backend-gcp.md](../docs/M1/03-backend-gcp.md):
**accept uploads**, **store raw artifacts**, **map-match GPS to OSM way IDs**, and feed the nightly
`severity ÷ miles` aggregation. Everything runs on GCP using open-source frameworks (FastAPI,
PostgreSQL/PostGIS, Valhalla).

This tree holds **Person C's** services. Person A's data-layer code (schema, OSM loader, exposure
attribution, nightly scoring, export queries) lands in `jobs/`, `scoring/`, and `db/` — separate
ownership, not scaffolded here.

## Modules

| Folder | What it is | README |
|---|---|---|
| [`ingest/`](./ingest/) | The FastAPI ingest API on Cloud Run — the four Contract-2 endpoints, GCS signed URLs, Firebase auth, persistence to A's schema. | [ingest/README.md](./ingest/README.md) |
| [`mapmatch/`](./mapmatch/) | `ValhallaMatcher` — the Contract-3 implementation that snaps GPS to OSM ways via Valhalla `/trace_attributes`. Person A consumes it. | [mapmatch/README.md](./mapmatch/README.md) |

```
Flutter ──HTTPS──► Cloud Run: FastAPI ingest ──► Cloud SQL (Postgres+PostGIS)
                       │                              ▲
                       ├── signed URL ──► GCS (audio/sensor blobs)
                       └── map-match ──► Valhalla (OSM, SF tiles)
```

## Intent

- **Ports/adapters everywhere the network is risky.** GCS and Firebase sit behind ports so unit tests
  fake them and never hit the network. PostGIS and Valhalla are deliberately **not** faked — they are
  the seams most likely to break, so integration tests use real local instances.
- **Test-driven, red first.** Each capability is built from a failing test. See the cycle-by-cycle
  plan in [docs/M1/Implementation/person-c-backend-infra.md](../docs/M1/Implementation/person-c-backend-infra.md).
- **Reusable across milestones.** The map-match client is a small standalone module so M2/M3 reuse it
  unchanged.

## Test steps

From the **repo root** (uses the root `pyproject.toml` for path + marker config):

```bash
# one-time: create the ingest venv and install dev deps
python -m venv backend/ingest/.venv
backend/ingest/.venv/Scripts/python -m pip install -r backend/ingest/requirements-dev.txt

# run the whole backend suite (fast unit tests + xfail'd integration tests)
backend/ingest/.venv/Scripts/python -m pytest
```

Expected today: **ingest unit tests pass**; the Valhalla integration tests **xfail** until a local
Valhalla is running (see [mapmatch/README.md](./mapmatch/README.md)). Fast-only run:

```bash
pytest -m "not integration"
```
