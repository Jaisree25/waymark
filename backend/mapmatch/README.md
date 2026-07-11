# backend/mapmatch — Valhalla + MapMatcher (Person C)

## The problem it solves

GPS from a phone in a car is **noisy** — especially inside a Tesla's metal cabin, where multipath
reflections push a fix 10–30 m off the real road, sometimes onto a parallel street. But the whole M1
benchmark hinges on two questions: *which road did this FSD incident happen on?* and *how many miles
were driven on each road?* You can't compute `severity ÷ miles` per road segment without them.

**Map-matching** snaps noisy GPS onto the actual road network. This module takes a raw lat/lon (or a
whole GPS track) and returns the **OSM way ID** — the stable identifier of the specific road segment
in OpenStreetMap — plus the cleaned-up (snapped) geometry.

```
raw GPS point/track ─► ValhallaMatcher ─► Valhalla /trace_attributes ─► MatchedEdge(way_id, length_mi, geom)
```

## How it works

It's a thin client over **Valhalla**, an OSS routing/map-matching engine loaded with San Francisco
OSM road data. Valhalla's `/trace_attributes` endpoint (the "Meili" map-matching algorithm) does the
heavy lifting; [`valhalla.py`](./valhalla.py) just calls it and extracts what the rest of the system
needs. Two operations:

- `match_event(lat, lon)` → snaps a **single incident point** to its road → fills `events.way_id`
  and `events.geom`.
- `match_track(track_geojson)` → snaps a **whole trip breadcrumb** and returns the ordered road edges,
  so their lengths sum into `segment_exposure` (the "miles" denominator for scoring).

## The contract seam (Contract 3) — why this module matters

`mapmatch` implements a **frozen interface**, [`contracts/mapmatch.py`](../../contracts/mapmatch.py):

```python
@dataclass
class MatchedEdge:
    way_id: int
    length_mi: float
    snapped_geojson: dict          # LineString for tracks, Point for events

class MapMatcher(Protocol):
    def match_event(self, lat, lon) -> MatchedEdge | None: ...
    def match_track(self, track_geojson) -> list[MatchedEdge]: ...
```

This is the seam between **Person C** and **Person A (database)**:

- **C implements** `ValhallaMatcher` against real Valhalla.
- **A consumes** `MapMatcher` to fill `way_id`/`geom` and build exposure — and tests A's
  exposure/attribution logic against a **fake** `MapMatcher` returning canned edges. So A never needs
  Valhalla running to develop, and A's code depends only on the `MatchedEdge` shape, not on Valhalla.
  We integrate at **Checkpoint 2**.

`snapped_geojson` is a plain dict (not a Valhalla object) on purpose — it keeps A's persistence code
portable and Valhalla-agnostic. The module is kept small and standalone so **M2/M3 reuse it unchanged**.

## This is where risk #2 lives

M1 is a feasibility test of five risks; **risk #2 is attribution accuracy** — *is map-matching
actually putting events on the right road?* This module is where that's proven. The approach: a small
**labelled set of SF points with known-correct ways** becomes a regression test, so "attribution is
good enough" is a *passing test*, not an opinion — see [tests](./tests/test_mapmatcher_integration.py).

## Run Valhalla locally (SF/norcal tiles)

```bash
mkdir -p data && cd data
curl -O https://download.geofabrik.de/north-america/us/california/norcal-latest.osm.pbf
cd ..
docker run -d --name valhalla -p 8002:8002 \
  -v "$(pwd)/data:/custom_files" \
  ghcr.io/gis-ops/docker-valhalla/valhalla:latest
# First boot builds tiles (minutes). Then /trace_attributes is the map-match endpoint.
```

## Test steps

```bash
# Contract type check — no Valhalla needed, runs everywhere:
pytest backend/mapmatch/tests/test_mapmatcher_integration.py::test_matcher_satisfies_contract -q

# Full integration — needs the local Valhalla above:
VALHALLA_URL=http://localhost:8002 pytest -m integration
```

Current state of the scaffold:
- `test_matcher_satisfies_contract` **passes** — pure check that `MatchedEdge` matches what A expects.
- `test_known_point_matches_expected_way`, `test_track_returns_ordered_edges`,
  `test_offroad_point_returns_none` are **`xfail`** until a local Valhalla is up (Cycle 4). Flip them
  to real assertions by starting Valhalla and filling in a verified `KNOWN_WAY_ID`.

## Deploy target

Valhalla runs as a container. For M1's tiny SF dataset:
- **GCE e2-standard-2** — a small always-warm VM; recommended for M1 predictability.
- **Cloud Run gen2** — scale-to-zero, with tiles baked into the image or pulled from the
  `${PROJECT}-osm` bucket at start.

## Known gaps in the scaffold (Cycle 4 work)

- `_parse_edges` treats Valhalla's `edge.length` as kilometers → miles; verify against the live API.
- `snapped_geojson` is currently a `{}` stub — building the real snapped Point/LineString from
  Valhalla's `matched_points` is the remaining Cycle-4 task.
