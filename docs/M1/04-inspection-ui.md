# M1 · 04 — Inspection UI (data-quality inspector, not a product)

M1's UI exists to **inspect data quality**, not to be used by the public. It must let the team:
see driven segments colored by `severity_per_mile`, eyeball whether map-matching put events on
the right roads (risk #2), and export raw rows for offline analysis. Keep it deliberately thin.

Two equally valid options; pick by team taste. Both are open source.

---

## Option A (recommended) — a single static MapLibre page

A one-file viewer served from anywhere (even `python -m http.server` locally, or a GCS bucket
later). It reads two read-only JSON/GeoJSON endpoints from the ingest service.

### Read-only endpoints to add to FastAPI
```python
@app.get("/v1/inspect/segments.geojson")
async def segments_geojson():
    # join road_segments ⨝ latest scores; return a FeatureCollection of LineStrings,
    # each feature.properties = {way_id, severity_per_mile, total_miles, incident_count, gated}
    ...

@app.get("/v1/inspect/events.geojson")
async def events_geojson():
    # FeatureCollection of Points: {event_id, severity, way_id, raw_accuracy_m, trigger_source,
    #                               raw_lat, raw_lon, snapped vs raw}
    ...
```
Return both **raw** and **snapped** coordinates for events so the inspector can draw a short line
between them — that line *is* the visual map-match-error check.

### The page (`inspector/index.html`)
```html
<!doctype html><meta charset="utf-8">
<link href="https://unpkg.com/maplibre-gl/dist/maplibre-gl.css" rel="stylesheet">
<script src="https://unpkg.com/maplibre-gl/dist/maplibre-gl.js"></script>
<div id="map" style="position:absolute;inset:0"></div>
<script>
const map = new maplibregl.Map({
  container: 'map',
  style: 'https://demotiles.maplibre.org/style.json',   // OSS demo basemap; swap for self-hosted PMTiles
  center: [-122.4194, 37.7749], zoom: 12                 // San Francisco
});
map.on('load', async () => {
  const seg = await (await fetch('/v1/inspect/segments.geojson')).json();
  map.addSource('seg', {type:'geojson', data: seg});
  map.addLayer({ id:'seg', type:'line', source:'seg',
    paint: {
      // color = risk; gray for gated/thin-data
      'line-color': ['case', ['get','gated'], '#999999',
        ['interpolate',['linear'],['get','severity_per_mile'],
          0,'#2ca25f', 0.1,'#fec44f', 0.2,'#de2d26']],
      'line-width': 4,
      'line-dasharray': ['case', ['get','gated'], ['literal',[2,2]], ['literal',[1,0]]]
    }});
  const ev = await (await fetch('/v1/inspect/events.geojson')).json();
  map.addSource('ev', {type:'geojson', data: ev});
  map.addLayer({ id:'ev', type:'circle', source:'ev',
    paint:{'circle-radius':5,'circle-color':'#3182bd','circle-stroke-color':'#fff','circle-stroke-width':1}});
  // click a segment → console/table with its raw row
  map.on('click','seg', e => showRow(e.features[0].properties));
});
</script>
```

This already exercises the M1 anti-misleading idea (gated/thin roads render gray + dashed) even
though the honest-uncertainty UX is a full M2 feature.

> Basemap note: `demotiles.maplibre.org` is fine for internal M1 use. For anything you keep, host
> an OSS basemap (Protomaps PMTiles on GCS, or OpenFreeMap) so there's no proprietary tile key —
> this is the same choice M2 makes in `milestone-2/05-web-ui.md`.

---

## Option B — a notebook / table-first inspector

If the team would rather slice data than click a map, skip the web page and use:
- a **CSV export** endpoint (below) +
- a small **Jupyter / Marimo** notebook (OSS) that loads the CSVs into pandas/GeoPandas, plots
  segments with `geopandas.GeoDataFrame.explore()` (which itself renders a Leaflet/folium map),
  and computes the risk #2 map-match error distribution numerically.

This is often *faster* for feasibility work because the numbers (accuracy distribution, match
error) are the deliverable, not the visuals.

---

## CSV export (needed by both options and by the feasibility report)

```python
import csv, io
from fastapi.responses import StreamingResponse

@app.get("/v1/export/events.csv")
async def export_events():
    rows = await fetch_events_join_scores()   # flat dict per event incl. raw+snapped coords
    def gen():
        buf = io.StringIO(); w = csv.DictWriter(buf, fieldnames=rows[0].keys()); w.writeheader()
        yield buf.getvalue(); buf.seek(0); buf.truncate(0)
        for r in rows:
            w.writerow(r); yield buf.getvalue(); buf.seek(0); buf.truncate(0)
    return StreamingResponse(gen(), media_type="text/csv",
        headers={"Content-Disposition":"attachment; filename=events.csv"})
```
Provide parallel `/v1/export/trips.csv`, `/v1/export/segment_exposure.csv`, and
`/v1/export/scores.csv`. These five CSVs are exactly what `05-feasibility-testing.md` consumes.

---

## What the inspector must make visible (tie-back to the five risks)

| Risk | What the inspector shows |
|---|---|
| #1 capture | event count vs. trip's logged trigger attempts; trigger_source breakdown (voice vs tap) |
| #2 attribution | raw→snapped line per event; `raw_accuracy_m`; events landing on the wrong way are obvious |
| #4 device | per-trip `metrics` (battery drain, peak temp, upload success) surfaced in the trip table |
| #5 scoring | the colored segment map + the scores CSV → "does this look like SF risk?" |

(Risk #3 workflow is assessed by debrief, not the UI — see `05`.)

---

## Acceptance checks for this file

- [ ] The map (or notebook) renders SF segments colored by `severity_per_mile`, gray/dashed when gated.
- [ ] Each event shows raw vs snapped location so map-match error is visually obvious.
- [ ] All five CSV exports download and open cleanly in pandas/Excel.
- [ ] No public-facing polish was added (this is a tool, not the product).

Next: [`05-feasibility-testing.md`](./05-feasibility-testing.md).
