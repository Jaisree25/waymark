# M1 · 3-person TDD split — coordination & shared contracts

This folder splits **Milestone 1** into **three parallel workstreams**, one per person, each driven
by **test-driven development (TDD)**. It assumes:

- **Person A** — *databases only*. Owns everything data-layer: schema, PostGIS, OSM loading,
  exposure attribution, the nightly scoring aggregation, and all export queries. No Flutter, no
  cloud deploys, no HTTP framework required.
- **Person B** — *mobile/Flutter generalist*. Owns the app end-to-end: capture, voice trigger, ring
  buffers, local store, and the resumable upload client.
- **Person C** — *backend + infra/UI generalist*. Owns the environment/GCP bootstrap, the FastAPI
  ingest API, GCS, Valhalla + the map-match client, Cloud Run deploy, and the inspection UI.

The three plans:
- [`person-a-database.md`](./person-a-database.md)
- [`person-b-mobile.md`](./person-b-mobile.md)
- [`person-c-backend-infra.md`](./person-c-backend-infra.md)

> Why a coordination file exists: parallel TDD only works if the **seams between people are frozen
> as testable contracts on day 1**. Each person then writes tests against the *contract* (using a
> fake/mock for the other side) and stays unblocked until the real integration checkpoints. This
> file is the single source of truth for those contracts; the three plans reference it.

---

## 0. The golden rule of this split

**Contracts before code. Tests before implementation.** Day 1, the whole team agrees the three
contracts below and commits them as files (`db/schema.sql`, `contracts/openapi.yaml`,
`contracts/mapmatch.py`/`.pyi`). Nobody edits a contract unilaterally — a contract change is a
team decision because it invalidates other people's mocks. Everything else is owned solo.

---

## 1. Contract 1 — the database schema (owned by A, depended on by B & C)

The M1 schema from `../03-backend-gcp.md` §1 is the contract. The load-bearing shapes everyone codes
against:

- `trips(id uuid PK, user_id, provider='tesla', started_at, ended_at, app_version, config_version, …)`
- `events(id uuid PK, trip_id FK, t_trigger, t_pre_seconds, t_post_seconds, trigger_source,
  event_type='incident', severity int 1..5, features jsonb, geom geography(Point), raw_lat, raw_lon,
  raw_accuracy_m, way_id bigint NULL, audio_uri, sensor_uri, idempotency_key UNIQUE, created_at)`
- `breadcrumb_segments(id uuid PK, trip_id FK, track geography(LineString), matched_track,
  motion_summary jsonb, idempotency_key UNIQUE, created_at)`
- `segment_exposure(way_id bigint, trip_id uuid, miles double, PK(way_id, trip_id))`
- `road_segments(way_id bigint PK, geom geography(LineString), length_mi, road_class, name)`
- `scores(way_id, provider, version, severity_per_mile, total_severity, total_miles, incident_count,
  gated bool, calibration_version='m1', as_of, PK(way_id, provider, version, as_of))`

**A owns the DDL and migrations.** B and C never write to these tables directly except through the
API layer (C) — but they need the shapes to build payloads and endpoints, so the DDL is shared.

---

## 2. Contract 2 — the ingest API (owned by C, produced by B, lands in A's tables)

Frozen as an **OpenAPI file** (`contracts/openapi.yaml`) on day 1. Endpoints from
`../03-backend-gcp.md` §2:

| Method + path | Body | Headers | Response |
|---|---|---|---|
| `POST /v1/trips` | `TripIn` | `Authorization: Bearer <firebase>` | `{ "ok": true }` (idempotent on `id`) |
| `POST /v1/events` | `EventIn` | `Authorization`, `Idempotency-Key` | `{ "audio_upload": <signed_url>, "sensor_upload": <signed_url> }` |
| `POST /v1/breadcrumbs` | `BreadcrumbIn` | `Authorization`, `Idempotency-Key` | `{ "ok": true }` |
| `GET /healthz` | — | — | `{ "status": "ok" }` |

`EventIn` (the important one) carries: `id`, `trip_id`, `t_trigger`, `t_pre_seconds`,
`t_post_seconds`, `trigger_source`, `severity`, `features`, `raw_lat`, `raw_lon`, `raw_accuracy_m`.
`BreadcrumbIn` carries: `id`, `trip_id`, `track` (GeoJSON LineString), `motion_summary`.
Blobs are **not** in the body — the app PUTs them to the returned signed GCS URLs.

**This contract is B↔C's seam.** B builds/tests its uploader against a stub server returning this
shape; C builds/tests the real server. They integrate at Checkpoint 2.

---

## 3. Contract 3 — the map-match client (owned by C, consumed by A)

A pure interface so A can persist matched output without depending on Valhalla being up:

```python
# contracts/mapmatch.py  (the frozen interface; C implements, A mocks)
from dataclasses import dataclass

@dataclass
class MatchedEdge:
    way_id: int
    length_mi: float
    snapped_geojson: dict          # LineString for breadcrumbs, Point for events

class MapMatcher:
    def match_event(self, lat: float, lon: float) -> MatchedEdge | None: ...
    def match_track(self, track_geojson: dict) -> list[MatchedEdge]: ...
```

- **C** implements `MapMatcher` against Valhalla `/trace_attributes`.
- **A** consumes it to fill `events.way_id`/`geom` and to build `segment_exposure` from breadcrumbs —
  and **tests against a fake `MapMatcher`** returning canned edges, so A's exposure/attribution
  logic is fully testable with no Valhalla. They integrate at Checkpoint 2.

---

## 4. Integration checkpoints (the only places people block on each other)

```
Day 1        Checkpoint 0 — Contracts frozen. schema.sql + openapi.yaml + mapmatch.py committed.
             Everyone can now TDD solo against mocks.
   │
   ▼
~⅓ in       Checkpoint 1 — "Vertical slice on fakes."
             A: schema migrates on a real PostGIS; aggregation passes on seeded fixtures.
             B: app captures + queues an event/breadcrumb against a STUB server.
             C: API accepts EventIn/BreadcrumbIn and writes rows (local PostGIS); healthz green.
   │
   ▼
~⅔ in       Checkpoint 2 — "Real seams."
             B → C: app uploads to the REAL ingest API; rows land in A's tables.
             C → A: real MapMatcher fills way_id + segment_exposure; A's nightly job runs on it.
   │
   ▼
End         Checkpoint 3 — "End-to-end on real SF drive data."
             Trip → events/breadcrumbs → map-match → exposure → nightly scores → inspection UI.
             The M1 feasibility campaign (../05-feasibility-testing.md) runs on this.
```

Between checkpoints, **red-green-refactor solo**. At a checkpoint, run the **cross-person contract
tests** (below) and fix mismatches together.

---

## 5. Shared contract tests (owned jointly, run at checkpoints)

A tiny `contracts/tests/` suite that neither mocks — it asserts the seams line up:

- **`test_openapi_roundtrip`** — a golden `EventIn` JSON validates against `openapi.yaml` **and**,
  when POSTed to C's real app, produces a row matching A's `events` schema (all NOT NULLs satisfied,
  `idempotency_key` respected).
- **`test_mapmatch_contract`** — C's real `MapMatcher.match_event` returns a `MatchedEdge` whose
  fields satisfy the types A's persistence code expects.
- **`test_idempotency_end_to_end`** — POST the same event twice → exactly one row (B's retry policy,
  C's UNIQUE handling, A's constraint all agree).

These are the regression net that keeps three parallel streams honest.

---

## 6. Ownership vs the original M1 files

| Original M1 file | Person A (DB) | Person B (mobile) | Person C (backend/infra/UI) |
|---|---|---|---|
| `01-environment-setup` | local PostGIS + test DB | Flutter toolchain + device | GCP bootstrap, Terraform, CI |
| `02-flutter-app` | — | **all** | — |
| `03-backend-gcp` | **schema, OSM loader, exposure, nightly scoring, export queries** | — | **ingest API, GCS, Valhalla + map-match client, Cloud Run deploy, Terraform** |
| `04-inspection-ui` | export **queries** behind the endpoints | — | **UI + export endpoints** |
| `05-feasibility-testing` | risk #5 (sane scoring) metrics | risks #1, #4 (capture, device limits) | risks #2, #3 (attribution, workflow) |

Feasibility (05) is a **team activity**; each person instruments and validates the risk questions
their component produces, and the team writes the go/no-go report together.

---

## 7. Definition of done (whole team)
- [ ] All three contracts frozen as committed files and unchanged except by team decision.
- [ ] Each person's solo test suite is green in CI (A: pytest+PostGIS; B: flutter test; C:
      pytest+TestClient and integration).
- [ ] The three shared contract tests are green.
- [ ] Checkpoint 3 end-to-end passes on a real SF drive.
- [ ] The five M1 risk questions each have data from the responsible owner (see `../05`).
