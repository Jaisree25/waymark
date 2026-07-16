"""Person A · Cycle 2 — the OSM road_segments loader, against a real PostGIS.

The fixture (fixtures/tiny.osm) is built so each assertion pins one decision the loader makes:
which ways are roads, which fall in a configured region, and how long they are.
"""

from __future__ import annotations

import math
from pathlib import Path

import pytest

from loader import DEFAULT_REGIONS_PATH, load_regions, load_road_segments, read_ways

FIXTURE = Path(__file__).parent / "fixtures" / "tiny.osm"

# Only the SF + Sacramento boxes, so the fixture's Nevada way is out of region.
REGIONS = [
    {"name": "sf_peninsula", "bbox": [37.40, -122.55, 37.85, -122.35]},
    {"name": "sacramento", "bbox": [38.45, -121.60, 38.70, -121.35]},
]


def _way_ids(db) -> set[int]:
    with db.cursor() as cur:
        cur.execute("SELECT way_id FROM road_segments")
        return {r[0] for r in cur.fetchall()}


# --- what gets loaded ---


def test_loader_inserts_ways(db) -> None:
    """Exactly the in-region roads land, each with real geometry and a positive length."""
    count = load_road_segments(db, FIXTURE, REGIONS)

    assert count == 3
    assert _way_ids(db) == {100, 101, 102}
    with db.cursor() as cur:
        cur.execute("SELECT count(*) FROM road_segments WHERE geom IS NULL OR length_mi <= 0")
        assert cur.fetchone()[0] == 0


def test_loader_skips_non_roads(db) -> None:
    """A building has no highway tag — it isn't a road and must not be scoreable."""
    load_road_segments(db, FIXTURE, REGIONS)
    assert 901 not in _way_ids(db)


def test_loader_skips_ways_outside_regions(db) -> None:
    """The Nevada motorway is a road, but outside every configured box — coverage is the config."""
    load_road_segments(db, FIXTURE, REGIONS)
    assert 900 not in _way_ids(db)


def test_regions_are_config_not_code(db) -> None:
    """Dropping a region from the config drops its roads — no code change involved."""
    sf_only = [{"name": "sf_peninsula", "bbox": [37.40, -122.55, 37.85, -122.35]}]
    load_road_segments(db, FIXTURE, sf_only)
    assert _way_ids(db) == {100, 101}  # Sacramento's way 102 is gone

    load_road_segments(db, FIXTURE, REGIONS)  # widen again: config edit + re-run
    assert _way_ids(db) == {100, 101, 102}


def test_loader_stores_tags(db) -> None:
    load_road_segments(db, FIXTURE, REGIONS)
    with db.cursor() as cur:
        cur.execute("SELECT road_class, name FROM road_segments WHERE way_id = 100")
        assert cur.fetchone() == ("secondary", "Market St")


# --- idempotency ---


def test_loader_is_idempotent(db) -> None:
    """Re-running upserts on way_id rather than duplicating — the loader is safe to re-run."""
    load_road_segments(db, FIXTURE, REGIONS)
    load_road_segments(db, FIXTURE, REGIONS)

    with db.cursor() as cur:
        cur.execute("SELECT count(*) FROM road_segments")
        assert cur.fetchone()[0] == 3


def test_rerun_refreshes_stale_rows(db) -> None:
    """A re-run corrects drifted data — that's what makes re-running after a new extract worthwhile."""
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO road_segments (way_id, geom, length_mi, road_class, name) "
            "VALUES (100, NULL, 0, 'wrong', 'Stale Name')"
        )

    load_road_segments(db, FIXTURE, REGIONS)

    with db.cursor() as cur:
        cur.execute("SELECT road_class, name, geom IS NOT NULL FROM road_segments WHERE way_id = 100")
        assert cur.fetchone() == ("secondary", "Market St", True)


# --- geometry + length ---


def test_length_mi_matches_geometry(db) -> None:
    """length_mi is PostGIS's own measurement of the stored geom — the two can never disagree."""
    load_road_segments(db, FIXTURE, REGIONS)
    with db.cursor() as cur:
        cur.execute("SELECT length_mi, ST_Length(geom) / 1609.344 FROM road_segments WHERE way_id = 100")
        stored, measured = cur.fetchone()
    assert stored == pytest.approx(measured, rel=1e-9)


def test_length_mi_is_hand_checkable(db) -> None:
    """Independently verify way 100's length, so 'the numbers are right' isn't circular.

    Market St runs (37.7793, -122.4193) → (37.7799, -122.4183). Approximating with equirectangular
    projection at this latitude:
        dlat = 0.0006° × 111_320 m/°                 ≈  66.8 m
        dlon = 0.0010° × 111_320 m/° × cos(37.78°)   ≈  88.0 m
        dist = hypot(66.8, 88.0) ≈ 110.5 m ≈ 0.0687 mi
    PostGIS uses a real geodesic on the spheroid, so allow a small tolerance for the approximation.
    """
    load_road_segments(db, FIXTURE, REGIONS)

    dlat_m = 0.0006 * 111_320
    dlon_m = 0.0010 * 111_320 * math.cos(math.radians(37.7796))
    expected_mi = math.hypot(dlat_m, dlon_m) / 1609.344

    with db.cursor() as cur:
        cur.execute("SELECT length_mi FROM road_segments WHERE way_id = 100")
        stored = cur.fetchone()[0]

    assert stored == pytest.approx(expected_mi, rel=0.01)  # within 1% of the hand calculation


def test_geometry_is_srid_4326_linestring(db) -> None:
    load_road_segments(db, FIXTURE, REGIONS)
    with db.cursor() as cur:
        cur.execute(
            "SELECT ST_GeometryType(geom::geometry), ST_SRID(geom::geometry) "
            "FROM road_segments WHERE way_id = 100"
        )
        assert cur.fetchone() == ("ST_LineString", 4326)


# --- parsing, without a DB ---


def test_read_ways_is_pure_parsing() -> None:
    """read_ways touches no database, so the OSM parse is testable on its own."""
    ways = list(read_ways(FIXTURE, REGIONS))
    assert {w["way_id"] for w in ways} == {100, 101, 102}
    assert all(w["geojson"] for w in ways)


def test_shipped_regions_config_covers_sf() -> None:
    """The committed config is the documented region list, SF included (docs/M1/03-backend-gcp §5)."""
    regions = load_regions(DEFAULT_REGIONS_PATH)
    names = {r["name"] for r in regions}
    assert "sf_peninsula" in names
    assert len(regions) == 6
    for region in regions:
        south, west, north, east = region["bbox"]
        assert south < north and west < east, f"{region['name']} bbox is inverted"


def test_empty_region_list_loads_nothing(db) -> None:
    """No configured regions → no roads. Fails closed rather than loading the whole planet."""
    assert load_road_segments(db, FIXTURE, []) == 0
