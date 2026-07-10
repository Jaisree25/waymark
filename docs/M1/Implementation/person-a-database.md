# M1 · Person A (databases only) — TDD plan: the data layer

**You own everything that lives in or is computed by the database.** No Flutter, no cloud deploys,
no web framework. Your work is the most TDD-friendly in the project because every unit is *input
rows → SQL/Python → output rows*, all assertable against a real PostGIS.

Your scope (from `../03-backend-gcp.md`, split per `00-coordination.md`):
1. The **schema + migrations** (Contract 1 — you own it).
2. The **OSM `road_segments` loader** (pyosmium → inserts).
3. **Exposure attribution** — turn matched breadcrumbs into `segment_exposure` miles.
4. The **nightly scoring aggregation** — `severity_per_mile`, min-mileage **gate**, `scores` rows.
5. The **export queries** behind C's inspection-UI endpoints (`../04-inspection-ui.md`).
6. Feasibility **risk #5** (sane scoring) — the DB-side metrics.

You depend on exactly one external thing — the **`MapMatcher` interface** (Contract 3) — which you
**mock**, so you are never blocked on Valhalla.

---

## 1. TDD setup (do this first)

You test against a **real PostGIS**, not a mock DB — PostGIS geography math and SQL constraints are
the whole point, so faking them proves nothing.

```bash
python3.12 -m venv .venv && source .venv/bin/activate
pip install pytest "psycopg[binary]>=3.2" pytest-postgresql testcontainers \
            shapely pyosmium "sqlalchemy>=2.0" geoalchemy2 pandas numpy
# Real PostGIS for tests — the same OSS image M1 uses:
docker run -d --name fsd-pg-test -p 5433:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd_test \
  postgis/postgis:16-3.4
```

A `conftest.py` fixture gives every test a **clean, migrated DB** (transaction rolled back per test):

```python
# tests/conftest.py
import pytest, psycopg
@pytest.fixture
def db():
    con = psycopg.connect("postgresql://app:app@localhost:5433/fsd_test")
    con.execute("CREATE EXTENSION IF NOT EXISTS postgis;")
    apply_migrations(con)                 # your migrations/*.sql, in order
    tx = con.transaction()
    tx.__enter__()
    yield con                             # test runs inside a tx…
    tx.__exit__(Exception, None, None)    # …always rolled back → isolation
```

> Rule: **every task below starts with a failing test.** Red → green → refactor. If you can't write
> the test, the spec isn't clear enough yet — resolve that first.

---

## 2. Build order as red-green-refactor cycles

### Cycle 1 — Schema & constraints (Checkpoint 0/1)
Write the DDL by making constraint tests pass. Don't hand-write the schema then "hope"; assert it.

- 🔴 `test_event_requires_trip` — inserting an event with a non-existent `trip_id` raises FK error.
- 🔴 `test_event_idempotency_key_unique` — two events with the same `idempotency_key` → one row / IntegrityError on the second.
- 🔴 `test_severity_range` — (add a CHECK) severity outside 1..5 is rejected.
- 🔴 `test_scores_pk` — duplicate `(way_id, provider, version, as_of)` rejected.
- 🟢 Write `migrations/001_init.sql` (the Contract-1 DDL + CHECK constraints) until green.
- ♻️ Extract a `apply_migrations()` helper; commit `db/schema.sql` as the frozen Contract 1.

### Cycle 2 — OSM `road_segments` loader
Load only the SF (or regions per `../03-backend-gcp.md`) ways into `road_segments`.

- 🔴 `test_loader_inserts_ways` — given a tiny fixture `.osm.pbf` (a few known ways), the loader
  inserts exactly those `way_id`s with non-null `geom` and `length_mi > 0`.
- 🔴 `test_loader_is_idempotent` — running twice doesn't duplicate (upsert on `way_id`).
- 🔴 `test_length_mi_matches_geometry` — `length_mi` equals PostGIS `ST_Length(geom)` converted to
  miles within tolerance (hand-check one known segment).
- 🟢 Implement `load_road_segments(pbf, bbox)` with pyosmium + `ON CONFLICT (way_id) DO UPDATE`.
- ♻️ Parameterize the bbox list (regions) so it's config, not code.

### Cycle 3 — Exposure attribution (uses the mocked MapMatcher)
Turn a matched breadcrumb into `segment_exposure(way_id, trip_id, miles)`.

```python
# tests/test_exposure.py
class FakeMatcher:                        # Contract 3, canned
    def match_track(self, track): 
        return [MatchedEdge(way_id=100, length_mi=0.5, snapped_geojson=...),
                MatchedEdge(way_id=101, length_mi=0.3, snapped_geojson=...)]

def test_exposure_sums_by_way(db):
    trip = seed_trip(db); seed_breadcrumb(db, trip, track=STRAIGHT_LINE)
    build_exposure(db, trip, matcher=FakeMatcher())
    rows = fetch(db, "SELECT way_id, miles FROM segment_exposure WHERE trip_id=%s", trip)
    assert rows == {100: 0.5, 101: 0.3}
```

- 🔴 `test_exposure_sums_by_way` (above).
- 🔴 `test_repeated_way_accumulates` — a track that revisits way 100 sums its miles, respecting the
  `(way_id, trip_id)` PK (upsert-add).
- 🔴 `test_event_gets_way_id` — `attribute_event(event, matcher.match_event(...))` fills `way_id`
  and snapped `geom`; a `None` match leaves them NULL (event still valid).
- 🟢 Implement `build_exposure()` and `attribute_event()` against the **interface**, not Valhalla.
- ♻️ Keep these as pure functions taking a `MapMatcher` — swappable for the real one at Checkpoint 2.

### Cycle 4 — Nightly scoring aggregation (risk #5)
The headline M1 math: per way, `severity_per_mile = Σseverity / Σexposure_miles`, gated below the
config min-mileage.

- 🔴 `test_severity_per_mile_basic` — 2 events (sev 3, 5) on way 100 with 4 exposure miles →
  `total_severity=8`, `total_miles=4`, `severity_per_mile=2.0`, `incident_count=2`. Hand-checkable.
- 🔴 `test_gate_below_threshold` — a way with `total_miles < gate_miles` → `gated=True` and is
  excluded from any ranking view.
- 🔴 `test_no_events_no_row_or_zero` — a way with exposure but no events scores `severity_per_mile=0`
  (decide + assert the intended behaviour explicitly).
- 🔴 `test_scores_are_reproducible` — running the job twice on the same data yields identical
  `severity_per_mile` (determinism).
- 🟢 Implement `aggregate.py` (SQL `GROUP BY way_id` joining events + `segment_exposure`, gate from
  config), writing `scores` rows.
- ♻️ Pull thresholds from config; version-stamp `calibration_version='m1'`.

> This cycle *is* feasibility risk #5. Keep a fixture that mirrors a worked example so "is the score
> sane?" is answered by a passing test, not a vibe.

### Cycle 5 — Export queries (behind C's UI endpoints)
C owns the HTTP endpoints in `../04-inspection-ui.md`; **you own the SQL they call.**

- 🔴 `test_segments_geojson_query` — returns a FeatureCollection of `road_segments` joined to their
  latest `scores`, with `severity_per_mile`, `gated`, `incident_count` as properties.
- 🔴 `test_events_geojson_query` — returns events with **both** raw (`raw_lat/lon`) and snapped
  (`geom`) points, so the UI can show map-match quality (risk #2 visual).
- 🔴 `test_csv_exports` — `events`, `trips`, `segment_exposure`, `scores` each export to CSV with the
  agreed columns; assert header + a known row.
- 🟢 Implement the query functions returning plain dicts/GeoJSON (no web framework — you hand C
  callables).
- ♻️ Give C a thin module `exports.py` with typed functions; C wraps them in FastAPI routes.

---

## 3. Your checkpoints
- **Checkpoint 1:** Cycles 1–2 green on real PostGIS; migrations reproducible from scratch.
- **Checkpoint 2:** swap `FakeMatcher` → C's real `MapMatcher`; Cycles 3–4 pass on real matched
  data. Run the shared `test_mapmatch_contract`.
- **Checkpoint 3:** nightly job runs on a real SF drive's rows; export queries feed the live UI.

---

## 4. Definition of done (Person A)
- [ ] `db/schema.sql` frozen as Contract 1; migrations apply cleanly on an empty PostGIS.
- [ ] `pytest` green: schema constraints, OSM loader, exposure, aggregation, exports.
- [ ] Aggregation math proven by a hand-checkable fixture (risk #5).
- [ ] All logic that touches map-matching is written against the **interface** and passed the real
      implementation at Checkpoint 2 with no code change.
- [ ] Export callables handed to C and covered by the shared `test_openapi_roundtrip` /
      GeoJSON tests.
- [ ] No dependency in your code on Flutter, Valhalla internals, GCS, or Cloud Run.

---
Coordination & contracts: [`00-coordination.md`](./00-coordination.md). Peers:
[`person-b-mobile.md`](./person-b-mobile.md), [`person-c-backend-infra.md`](./person-c-backend-infra.md).
