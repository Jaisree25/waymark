# M2 · 03 — Backend on GCP (rich aggregation + read API)

M2's backend extends M1's. Same Cloud Run + Cloud SQL/PostGIS + GCS + Valhalla, with: **schema
additions** (all additive), **conditions enrichment** at ingest, **per-(segment, provider,
version, condition-bucket) aggregation**, **corridor and district rollups**, **confidence tiers**,
and a **read-only scoring API** that the web UI consumes. The scoring *math* lives in the shared
package described in [`04-scoring-engine.md`](./04-scoring-engine.md); this file is the data
plumbing around it.

---

## 1. Schema additions (additive migrations only)

```sql
-- events: nothing destructive. The rich fields live in features JSONB already.
-- Add generated/extracted columns for query speed (optional, derived from features):
ALTER TABLE events ADD COLUMN IF NOT EXISTS category text;          -- mirror of features->>'category'
ALTER TABLE events ADD COLUMN IF NOT EXISTS conditions jsonb NOT NULL DEFAULT '{}'; -- enriched at ingest

-- breadcrumb miles must also carry conditions so per-condition EXPOSURE exists
ALTER TABLE segment_exposure ADD COLUMN IF NOT EXISTS conditions jsonb NOT NULL DEFAULT '{}';
ALTER TABLE segment_exposure ADD COLUMN IF NOT EXISTS provider text NOT NULL DEFAULT 'tesla';
ALTER TABLE segment_exposure ADD COLUMN IF NOT EXISTS version  text NOT NULL DEFAULT 'all';
-- widen PK so exposure splits by provider/version/bucket
ALTER TABLE segment_exposure DROP CONSTRAINT segment_exposure_pkey;
ALTER TABLE segment_exposure ADD PRIMARY KEY (way_id, trip_id, provider, version);

-- road hierarchy (corridors + districts) — loaded from OSM
CREATE TABLE IF NOT EXISTS corridors (
  id text PRIMARY KEY, name text, way_ids bigint[] NOT NULL
);
CREATE TABLE IF NOT EXISTS districts (
  id text PRIMARY KEY, name text, boundary geography(Polygon,4326) NOT NULL
);

-- scores gains buckets, intervention rate, confidence tier, risk band
ALTER TABLE scores ADD COLUMN IF NOT EXISTS condition_bucket text NOT NULL DEFAULT 'all';
ALTER TABLE scores ADD COLUMN IF NOT EXISTS intervention_rate double precision;
ALTER TABLE scores ADD COLUMN IF NOT EXISTS confidence_tier text;     -- solid|provisional|insufficient
ALTER TABLE scores ADD COLUMN IF NOT EXISTS risk_band int;            -- fixed bands for color
ALTER TABLE scores ADD COLUMN IF NOT EXISTS unit_kind text NOT NULL DEFAULT 'segment'; -- segment|corridor|district
ALTER TABLE scores ADD COLUMN IF NOT EXISTS unit_id text;             -- way_id as text, or corridor/district id
```

> M1 rows still satisfy these tables: new columns have defaults, the `features` bag already holds
> the rich data, and old `scores` rows are simply `condition_bucket='all'`, `unit_kind='segment'`.

---

## 2. Conditions enrichment at ingest

When an event (or, in the nightly pass, a breadcrumb segment) is processed, derive its conditions
from timestamp + lat/lon and store them on the row:

```python
# backend/ingest/app/conditions.py
from astral import LocationInfo
from astral.sun import sun

def lighting_bucket(ts, lat, lon) -> str:
    s = sun(LocationInfo(latitude=lat, longitude=lon).observer, date=ts.date())
    if ts < s["dawn"] or ts > s["dusk"]: return "night"
    if ts < s["sunrise"] or ts > s["sunset"]: return "twilight"
    return "day"

def time_of_day_bucket(ts) -> str:
    h = ts.hour
    return ("am_rush" if 7 <= h < 10 else "pm_rush" if 16 <= h < 19
            else "midday" if 10 <= h < 16 else "overnight")

async def weather_bucket(ts, lat, lon, cache) -> str:
    cell = (round(lat,1), round(lon,1), ts.replace(minute=0, second=0))   # coarse cache key
    if cell in cache: return cache[cell]
    data = await weather_client.historical(lat, lon, ts)   # Open-Meteo
    bucket = classify_weather(data)                         # dry|wet|fog|...
    cache[cell] = bucket
    return bucket
```

`event.conditions = {lighting, time_of_day, weather}`; the same function stamps each breadcrumb
segment so **per-condition miles** exist. Batch + cache by coarse cell to control API cost (the
design's named M2 risk).

---

## 3. Loading the road hierarchy from OSM

A one-off loader (extends M1's `road_segments` loader) builds:
- **corridors:** group consecutive ways sharing an OSM `name` or route relation → `corridors.way_ids`.
- **districts:** import SF neighborhood boundary polygons (city open-data or OSM admin relations)
  → `districts.boundary`. PostGIS `ST_Within` later assigns ways to districts at rollup time.

Use `pyosmium`/`osmium` (OSS) on the same SF pbf from M1. Keep it idempotent (upsert by id).

---

## 4. Nightly aggregation (now per bucket, with rollups + tiers)

`backend/jobs/aggregate_v2.py` (calls the shared scoring package from `04`):

1. **Match + enrich** any new events/breadcrumbs (way_id + conditions).
2. **Segment scores** — `GROUP BY (way_id, provider, version, condition_bucket)`:
   - `severity_per_mile = Σσ / Σmiles` (plus an `all`-bucket roll-up across conditions),
   - `intervention_rate = (# interventions) / Σmiles`,
   - `incident_count`, `total_miles`,
   - **confidence tier** + **gate** + **risk band** via `04`.
3. **Corridor rollup** — length-weighted mean of member ways' rates (`04 §rollups`).
4. **District rollup** — exposure-weighted mean of contained ways' rates via PostGIS
   `ST_Within(road_segments.geom, districts.boundary)`.
5. Write a fresh `scores` snapshot for all three `unit_kind`s, stamped `calibration_version='m2'`,
   `as_of=now()`. (History is retained → trend sparklines in the UI.)

Plain SQL + pandas; **no ML**. Schedule with the same Cloud Scheduler → Cloud Run Job pattern as
M1 (bump the image tag to `:m2`).

```bash
gcloud run jobs update fsd-aggregate \
  --image $REGION-docker.pkg.dev/$PROJECT/fsd/aggregate:m2 --region $REGION
```

---

## 5. Read-only scoring API (serves the web UI)

Add read endpoints to the FastAPI service. They serve **pre-computed** rows from `scores` +
geometry — heavy work already happened in the nightly job (design §9.11).

```python
# segments as GeoJSON for the map (color + confidence + sample size baked into properties)
@app.get("/v1/scores/segments.geojson")
async def segments(provider="tesla", version="all", bucket="all"): ...

@app.get("/v1/scores/districts.geojson")
async def districts(provider="tesla", version="all", bucket="all"): ...

@app.get("/v1/scores/corridors")           # list + aggregate rate/CI per corridor
async def corridors(...): ...

@app.get("/v1/segment/{way_id}")           # detail panel: rate, CI, miles, incidents,
async def segment_detail(way_id: int): ... #   category breakdown, conditions, trend, tier

@app.get("/v1/route")                      # Route A→B: call Valhalla for the path, score its ways
async def route(from_: str, to: str): ...  #   returns route score, worst stretches, risk profile

@app.get("/v1/ranking")                    # sortable table of units with gate quarantine flag
async def ranking(scope="city", by="risk_rate"): ...

@app.get("/v1/compare")                    # version-vs-version & Tesla-vs-Waymo (see 06)
async def compare(...): ...
```

Every payload includes the **honest-uncertainty trio**: risk rate + CI, sample size (miles +
incident count), and confidence tier — because the UI must show all three (design §9.1).

> Route scoring reuses Valhalla: ask it for the route's ordered ways, then length-weight their
> stored segment scores (`04 §route`). No new engine.

---

## 6. Confidence tiers + gate + risk bands (where they're applied)

Computed in the scoring package (`04`) and **stored** on each `scores` row so the API and UI never
recompute:
- **Gate:** `total_miles < min_mileage_gate_miles` → `confidence_tier='insufficient'`, excluded
  from rankings/comparisons (shown as "collecting data").
- **Tiers:** `insufficient < provisional < solid` based on miles thresholds (config-driven).
- **Risk bands:** fixed, version-stamped numeric bands → stable map colors regardless of session.

---

## 7. Acceptance checks for this file
- [ ] Events and breadcrumb miles both carry `conditions` (lighting/time/weather); a wet-weather
      rate is computable because wet-weather miles exist.
- [ ] `scores` has rows per `(way_id, provider, version, condition_bucket)` plus `all` rollups,
      and corridor/district rows via length-/exposure-weighting.
- [ ] `intervention_rate` is populated; confidence tier + gate + risk band are stored, not computed in the UI.
- [ ] All read endpoints return the rate + CI + sample-size + tier trio.
- [ ] Re-running the nightly job over M1's old data reproduces scores (recomputation, not re-collection).

Next: [`04-scoring-engine.md`](./04-scoring-engine.md).
