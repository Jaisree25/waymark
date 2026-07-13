"""Cycle 4 — Valhalla + the MapMatcher (Contract 3, risk #2).

INTEGRATION tests: they need a real local Valhalla with SF tiles. Do not fake Valhalla — it is the
seam risk #2 lives on. When no Valhalla is reachable they SKIP (not xfail), so the suite stays green
locally and these turn into real assertions the moment a Valhalla is up:

    docker run -d --name valhalla -p 8002:8002 \
      -v "$PWD/data:/custom_files" ghcr.io/gis-ops/docker-valhalla/valhalla:latest
    VALHALLA_URL=http://localhost:8002 pytest -m integration

The labelled SF points below are the attribution regression set: "attribution is good enough" becomes
a passing test, not an opinion. Set EXPECTED_WAY_ID to pin a known corner once you've verified a match.
"""

from __future__ import annotations

import math
import os

import httpx
import pytest

from contracts.mapmatch import MatchedEdge

LOCAL_VALHALLA = os.environ.get("VALHALLA_URL", "http://localhost:8002")

pytestmark = pytest.mark.integration

# Labelled SF points for the risk #2 attribution regression set. `way_id` is tied to the current
# norcal tileset (observed at build time); the snapped-distance check below is version-robust. Grow
# this list as you verify more corners.
LABELLED_SF_POINTS = [
    {"name": "hayes-octavia", "lat": 37.779211, "lon": -122.419997, "way_id": 502795544},
    {"name": "civic-center", "lat": 37.7749, "lon": -122.4194, "way_id": 228228520},
]


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi, dlmb = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def _valhalla_up(url: str) -> bool:
    try:
        # Require a real 200 — a wrong port or some other service answering shouldn't count as "up".
        return httpx.get(f"{url}/status", timeout=2.0).status_code == 200
    except Exception:
        return False


@pytest.fixture(scope="module")
def matcher():
    if not _valhalla_up(LOCAL_VALHALLA):
        pytest.skip(f"no Valhalla at {LOCAL_VALHALLA}; start it or set VALHALLA_URL")
    from backend.mapmatch.valhalla import ValhallaMatcher

    m = ValhallaMatcher(base_url=LOCAL_VALHALLA)
    yield m
    m.close()


@pytest.mark.parametrize("pt", LABELLED_SF_POINTS, ids=lambda p: p["name"])
def test_labelled_point_attribution(matcher, pt):
    """Risk #2: a known event point snaps to the CORRECT way, near where the event actually was.
    The exact way_id is the attribution regression guard (tied to the norcal tileset — if you rebuild
    from a newer OSM extract and this changes, verify the new way is right and update the constant).
    The distance bound is the version-robust proximity check."""
    edge = matcher.match_event(lat=pt["lat"], lon=pt["lon"])
    assert edge is not None
    assert edge.way_id == pt["way_id"]  # attribution: correct road, not merely a nearby one
    assert edge.snapped_geojson.get("type") == "Point"
    snap_lon, snap_lat = edge.snapped_geojson["coordinates"]
    assert _haversine_m(pt["lat"], pt["lon"], snap_lat, snap_lon) < 30  # meters


def test_offroad_track_returns_empty(matcher):
    # A track with no road nearby → Valhalla 400 error_code 171 → match_track swallows to [].
    track = {"type": "LineString", "coordinates": [[0.0, 0.0], [0.001, 0.001]]}
    assert matcher.match_track(track) == []


def test_track_returns_ordered_edges(matcher):
    track = {
        "type": "LineString",
        "coordinates": [[-122.4193, 37.7793], [-122.4183, 37.7799], [-122.4173, 37.7805]],
    }
    edges = matcher.match_track(track)
    assert edges and all(isinstance(e, MatchedEdge) for e in edges)
    assert all(e.length_mi >= 0 for e in edges)
    assert all(e.snapped_geojson.get("type") == "LineString" for e in edges if e.snapped_geojson)


def test_offroad_point_returns_none(matcher):
    assert matcher.match_event(lat=0.0, lon=0.0) is None  # middle of the ocean
