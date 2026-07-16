"""Person A · Cycle 2 — the OSM road_segments loader.

Reads an OSM extract (.osm.pbf or .osm) and inserts the roads we render and score into
`road_segments`. This is the table that gives the inspector something to draw and the aggregation
its `length_mi` denominator cap.

**Regions are config, not code** (db/config/regions.json). Widening coverage is a config edit + a
re-run of this loader — never a schema, ingest or scoring change, because geography is data. Every
configured box sits inside the already-built norcal Valhalla tiles, so map-matching never needs a
rebuild when the list changes.

Run:
    DATABASE_URL=postgresql://… python loader.py backend/mapmatch/data/norcal-latest.osm.pbf
"""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Iterator
from pathlib import Path

import osmium
import psycopg

DEFAULT_REGIONS_PATH = Path(__file__).parent / "config" / "regions.json"

METERS_PER_MILE = 1609.344

# Upsert on way_id: a re-run refreshes geometry/tags rather than duplicating roads, so the loader is
# safe to run whenever the extract or the region list changes.
#
# length_mi is computed BY PostGIS from the geometry we just inserted, never in Python. One source of
# truth means the number can't drift from the shape it describes.
_UPSERT_SQL = f"""
INSERT INTO road_segments (way_id, geom, length_mi, road_class, name)
VALUES (
    %(way_id)s,
    ST_SetSRID(ST_GeomFromGeoJSON(%(geojson)s), 4326)::geography,
    ST_Length(ST_SetSRID(ST_GeomFromGeoJSON(%(geojson)s), 4326)::geography) / {METERS_PER_MILE},
    %(road_class)s,
    %(name)s
)
ON CONFLICT (way_id) DO UPDATE SET
    geom       = EXCLUDED.geom,
    length_mi  = EXCLUDED.length_mi,
    road_class = EXCLUDED.road_class,
    name       = EXCLUDED.name
"""


def load_regions(path: str | Path | None = None) -> list[dict]:
    """Load the region bbox list. REGIONS_CONFIG overrides the bundled default."""
    path = Path(path or os.environ.get("REGIONS_CONFIG") or DEFAULT_REGIONS_PATH)
    return json.loads(path.read_text())["regions"]


def _in_regions(coordinates: list[list[float]], regions: list[dict]) -> bool:
    """True if ANY vertex falls inside ANY box.

    Deliberately permissive: a road crossing a boundary is kept whole rather than clipped, so a way
    never gets split into fragments that would each carry their own exposure and scores.
    """
    for lon, lat in coordinates:
        for region in regions:
            south, west, north, east = region["bbox"]
            if south <= lat <= north and west <= lon <= east:
                return True
    return False


def read_ways(osm_path: str | Path, regions: list[dict]) -> Iterator[dict]:
    """Yield the road ways inside the configured regions. Pure parsing — no DB, so it's testable alone."""
    factory = osmium.geom.GeoJSONFactory()
    # NODE is requested alongside WAY because with_locations() builds its coordinate cache from the
    # node stream; ways alone carry only node refs, not positions.
    processor = osmium.FileProcessor(str(osm_path), osmium.osm.NODE | osmium.osm.WAY).with_locations()

    for obj in processor:
        if not isinstance(obj, osmium.osm.Way):
            continue
        tags = dict(obj.tags)
        road_class = tags.get("highway")
        if not road_class:
            continue  # not a road — buildings, boundaries, waterways etc.
        try:
            geometry = json.loads(factory.create_linestring(obj))
        except Exception:
            # Ways clipped by the extract's edge have nodes we don't have locations for. Skipping is
            # right: a partial geometry would understate the way's length and skew its score.
            continue
        if not _in_regions(geometry["coordinates"], regions):
            continue
        yield {
            "way_id": obj.id,
            "geojson": json.dumps(geometry),
            "road_class": road_class,
            "name": tags.get("name"),
        }


def load_road_segments(
    conn: psycopg.Connection, osm_path: str | Path, regions: list[dict] | None = None
) -> int:
    """Load roads from an OSM extract into road_segments. Returns the number of ways upserted."""
    regions = regions if regions is not None else load_regions()
    rows = list(read_ways(osm_path, regions))
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany(_UPSERT_SQL, rows)
    return len(rows)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: loader.py <path-to-osm-extract>")
    regions = load_regions()
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        count = load_road_segments(conn, sys.argv[1], regions)
        conn.commit()
    print(f"loaded {count} ways from {sys.argv[1]} across {len(regions)} regions")


if __name__ == "__main__":
    main()
