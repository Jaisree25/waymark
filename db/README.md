# db — the data layer (Person A)

## The problem it solves

Everything in M1 converges on one question: *is this stretch of road riskier than that one?* That
answer is computed from rows, so the data layer has to be trustworthy before anything above it
matters. This module owns the schema every other lane codes against, and the read-only queries the
inspector renders.

## What's here

| File | What it is |
|---|---|
| [`schema.sql`](./schema.sql) | **Contract 1** — the frozen M1 schema. Also migration 001. |
| [`loader.py`](./loader.py) | OSM extract → `road_segments` (pyosmium), bounded by the region config. |
| [`exposure.py`](./exposure.py) | Matched breadcrumbs → `segment_exposure`; events → `way_id` + snapped `geom`. |
| [`exports.py`](./exports.py) | The export queries behind C's inspection-UI endpoints. |
| [`config/regions.json`](./config/regions.json) | Which bboxes `road_segments` covers. |
| [`tests/`](./tests/) | 52 tests against a **real** PostGIS. |

The nightly `severity ÷ miles` aggregation is A's too, but lives in
[`backend/jobs/`](../backend/jobs/) because it ships as a Cloud Run Job image.

Together these are the data layer's chain:

```
OSM extract ──loader──► road_segments ─────────────┐
                                                    ├──aggregate──► scores ──exports──► inspector
breadcrumbs ─┬─exposure──► segment_exposure (miles)─┤
             └─attribute─► events.way_id (severity)─┘
                  ▲
                  └── Contract 3's MapMatcher (faked in tests, C's Valhalla at Checkpoint 2)
```

## Intent / design rules

- **`schema.sql` is frozen and canonical.** It's Contract 1 ([00-coordination.md](../docs/M1/Implementation/00-coordination.md) §1):
  C's ingest repository and B's payloads are written against these exact shapes, so a change here
  invalidates their mocks and is a **team decision, never unilateral**. C's persistence tests read
  *this file* — not a copy — so DDL drift breaks a test instead of production.
- **One schema, no snapshot drift.** M1 has a single init migration, so `schema.sql` *is* the
  migration rather than a snapshot that can silently diverge. Later changes land as numbered files
  in `db/migrations/`.
- **Constraints are tested, not hoped for.** The FK, the UNIQUE `idempotency_key`, and the severity
  CHECK are guarantees C actively leans on (its 409 path and retry-safety), so each has a test.
- **The DB is the last line of defence.** `severity BETWEEN 1 AND 5` is enforced here as well as in
  C's Pydantic layer, because a direct writer can bypass the app but not the database.
- **"No data" ≠ "no risk".** `segment_rows()` returns unscored ways as `gated=true` so the UI grays
  them out rather than coloring them safe. Likewise an event that can't be matched keeps `way_id`
  NULL and stays a valid row: we record that it happened but not where, rather than dropping a real
  incident or inventing a road for it.
- **Regions are config, not code.** `config/regions.json` bounds the loader. Widening coverage is a
  config edit + a re-run — never a schema, ingest or scoring change, because geography is data.
- **Re-running is safe.** The loader upserts on `way_id`, and `build_exposure` sums a trip's miles
  per way in Python then *replaces* its rows. Double-counted miles would silently halve a road's
  `severity_per_mile` and make it look safer than it is.
- **Map-matching is an interface, never an import.** `exposure.py` calls Contract 3's `MapMatcher`
  and nothing else, so it's tested with a fake and no Valhalla — then takes C's real matcher at
  Checkpoint 2 with no code change.
- **No web framework.** A hands C plain callables returning plain dicts; C wraps them in routes.
  Nothing here imports C — the match to C's `ExportsPort` is structural.

## Test / run steps

Tests need a real PostGIS — PostGIS geography math and the SQL constraints *are* the thing under
test, so faking them proves nothing:

```bash
docker run -d --name fsd-pg-test -p 5433:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd_test postgis/postgis:16-3.4

cd db && pytest                    # 52 tests: constraints, loader, exposure, exports
```

Each test rebuilds the schema from `schema.sql`, which keeps migrations provably reproducible from
scratch. Tests skip cleanly (not fail) when no PostGIS is reachable; override the DSN with
`TEST_DATABASE_URL`.

The C↔A seam is covered from the other side too — `backend/ingest/tests/test_exports_integration.py`
drives C's endpoints through the **real** `SqlExports`, so a shape mismatch fails there rather than
at Checkpoint 3.

## Ownership note

Person A owns this lane. C consumes the schema and wraps `exports.py`; C never authors DDL. The
`ExportsPort` protocol in `backend/ingest/app/ports.py` describes what C needs from `exports.py` —
it is **not** one of the three frozen contracts, so its shape still needs A's sign-off.
