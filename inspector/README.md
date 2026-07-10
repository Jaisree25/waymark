# inspector — M1 data-quality inspector (Person C)

A single static MapLibre page (`docs/M1/04-inspection-ui.md`, Option A). Not a product — it exists
to eyeball data quality: segments colored by `severity_per_mile`, gated/thin roads gray+dashed, and
the **raw→snapped line per event** (the visual risk #2 map-match-error check).

Serve it locally against the ingest API:

```bash
# from repo root, with the API running (e.g. uvicorn on :8080):
python -m http.server -d inspector 8000
# then open http://localhost:8000/?api=http://localhost:8080
```

Endpoints it consumes (read-only, added to the FastAPI app in Cycle 6, wrapping **A's** export
callables — C wraps, A owns the SQL): `/v1/inspect/segments.geojson`, `/v1/inspect/events.geojson`,
and the CSV exports under `/v1/export/`.

> For anything kept, host an OSS basemap (OpenFreeMap / Protomaps PMTiles on GCS) — no proprietary
> tile key. `demotiles.maplibre.org` is fine only for throwaway internal use.
