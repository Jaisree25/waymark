# contracts — the frozen seams between the three M1 workstreams

## Purpose

M1 is built by three people in parallel with test-driven development. That only works if the
**seams between them are frozen as testable contracts on day 1** — each person then codes and tests
against the *contract* (mocking the other side) and only blocks on real integration at checkpoints.

This folder is the single source of truth for those contracts. It is **owned jointly**: nobody edits
a file here unilaterally, because a change invalidates other people's mocks. A contract change is a
team decision. See [docs/M1/Implementation/00-coordination.md](../docs/M1/Implementation/00-coordination.md).

## What's here

| File | Contract | Owner / consumers |
|---|---|---|
| [`openapi.yaml`](./openapi.yaml) | **Contract 2 — the ingest API.** The HTTP shape the mobile app POSTs to and the ingest service serves: `POST /v1/trips`, `/v1/events`, `/v1/breadcrumbs`, `GET /healthz`. Blobs are **not** in bodies — the app PUTs them to signed GCS URLs the API returns. | **Person C defines**; Person B (mobile) mocks against it to build its uploader. |
| [`mapmatch.py`](./mapmatch.py) | **Contract 3 — the map-match client interface.** `MapMatcher` (`match_event`, `match_track`) returning `MatchedEdge(way_id, length_mi, snapped_geojson)`. | **Person C implements** (`backend/mapmatch/valhalla.py`); Person A (database) mocks it to test exposure/attribution without a live Valhalla. |

> Contract 1 — the **database schema** — is owned by Person A and lives in `db/schema.sql` (not yet
> created). C and B depend on its shapes but never write DDL.

## Intent / design rules these encode

- **Blobs go direct to GCS** (Contract 2): large audio/sensor files never stream through Cloud Run;
  the API only mints signed PUT URLs.
- **Idempotency** (Contract 2): `/v1/events` and `/v1/breadcrumbs` require an `Idempotency-Key`
  header so retried uploads are safe.
- **Attributes bag** (Contract 2): `EventIn.features` is an open JSON object carried through verbatim,
  so M2/M3 add keys without a schema migration.
- **Portable map-matching** (Contract 3): `MatchedEdge` is a plain dataclass, so A's persistence code
  never depends on Valhalla being up — it depends only on this shape.

## How it's tested

The contracts are validated by the **shared contract tests** (run at integration checkpoints):

- `test_openapi_roundtrip` — a golden `EventIn` validates against `openapi.yaml` **and**, when POSTed
  to C's real app, produces a row satisfying A's schema.
- `test_mapmatch_contract` — C's real `MapMatcher.match_event` returns a `MatchedEdge` whose field
  types match what A's persistence expects. A runnable version lives in
  [`backend/mapmatch/tests/test_mapmatcher_integration.py::test_matcher_satisfies_contract`](../backend/mapmatch/tests/test_mapmatcher_integration.py).
- `test_idempotency_end_to_end` — the same event POSTed twice yields exactly one row.

Run the pure type-level contract check (no services needed) from the repo root:

```bash
pytest backend/mapmatch/tests/test_mapmatcher_integration.py::test_matcher_satisfies_contract -q
```

To eyeball that the running API still matches `openapi.yaml`, diff the app's generated schema against
this file — FastAPI serves it at `GET /openapi.json`.
