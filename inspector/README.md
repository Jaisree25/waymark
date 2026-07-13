# inspector — M1 data-quality inspector (Person C)

## What it is (and isn't)

A single static web page that lets the two-person team **eyeball data quality** during the M1
feasibility campaign. It is deliberately **not a product** — no auth, no polish, no build step. It's a
throwaway lens on "does the data we're collecting actually look right?" The public-facing 3-view web
UI is M2 work; this is the internal tool that tells us whether M2 is worth building.

## The problem it solves

M1 collects FSD incident events and GPS breadcrumbs, map-matches them to roads, and scores each road
by `severity ÷ miles`. Before trusting any of that, the team needs to *see* it:

- Are high-severity roads plausibly the sketchy ones we remember driving? (**risk #5, sane scoring**)
- Did map-matching put events on the **right road**? (**risk #2, attribution**)
- Are thin, under-driven roads correctly quarantined rather than topping the chart?

## How it works

One file — [`index.html`](./index.html) — loads MapLibre GL JS and fetches two read-only endpoints
from the ingest service, then draws three layers over a San Francisco basemap:

| Layer | Source | What it shows |
|---|---|---|
| **Road segments** | `/v1/inspect/segments.geojson` | Colored by `severity_per_mile` (green → amber → red). **Gated/thin roads render gray + dashed** — the M1 anti-misleading rule, so a 1-mile fluke can't look like a hotspot. |
| **Event points** | `/v1/inspect/events.geojson` | Where incidents landed after snapping. |
| **raw → snapped line** | derived from event `raw_lat/lon` + snapped coords | The orange connector between where GPS *said* and where map-matching *put* each event. **This line is the visual risk #2 check** — a long line means a bad match. |

Click any segment or event to dump its raw properties in the corner panel.

The read-only endpoints are added to FastAPI in **Cycle 6** and wrap **Person A's** export queries —
C wraps them as routes; A owns the SQL behind them. So the inspector is a thin client over data A
produces and C serves.

## Intent / design rules

- **Static and hostable anywhere** — `python -m http.server`, or a GCS bucket later. No server-side
  rendering, no keys baked in.
- **No proprietary tile keys.** It currently uses `demotiles.maplibre.org` for throwaway internal use;
  for anything kept, self-host an OSS basemap (OpenFreeMap or Protomaps PMTiles on GCS) — the same
  choice M2 makes. Swap the `style` URL in `index.html`.
- **Exercises the honest-uncertainty idea early** — gray/dashed gating is here even though the full
  uncertainty UX is an M2 feature.

## Run / test steps

Serve it against a running ingest API:

```bash
# from repo root, with the API up (e.g. uvicorn on :8080):
python -m http.server -d inspector 8000
# open in a browser:
#   http://localhost:8000/?api=http://localhost:8080
```

The `?api=` query param points the page at the API base (defaults to same-origin when FastAPI serves
the page itself). What to verify:

- [ ] SF segments render colored by `severity_per_mile`; gated ones are gray + dashed.
- [ ] Each event shows a raw→snapped connector line (risk #2 is visually obvious).
- [ ] Clicking a segment/event shows its underlying row.

For a no-backend preview, the inspection endpoints can be stubbed (see how the live smoke in
[backend/ingest/README.md](../backend/ingest/README.md) mounts fake `segments.geojson` /
`events.geojson` responses).

## Related

CSV export endpoints (`/v1/export/*.csv`) feed the same data to the feasibility notebook in
[docs/M1/04-inspection-ui.md](../docs/M1/04-inspection-ui.md) Option B — often faster than the map for
the numeric risk-#2 error distribution.
