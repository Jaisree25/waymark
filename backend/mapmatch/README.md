# backend/mapmatch — Valhalla + MapMatcher (Person C)

Implements **Contract 3** (`contracts/mapmatch.py`). Person A consumes `MapMatcher` to fill
`events.way_id`/`geom` and build `segment_exposure`; A tests against a **fake** matcher, so this
concrete impl is only wired at **Checkpoint 2**.

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

Then point tests at it: `VALHALLA_URL=http://localhost:8002 pytest -m integration`.

> Risk #2 lives here: a small labelled set of SF points with known-correct ways is the attribution
> regression test. Deploy target: GCE e2-standard-2 (warm tile cache) for M1 predictability, or
> Cloud Run gen2 with baked/pulled tiles for scale-to-zero.
