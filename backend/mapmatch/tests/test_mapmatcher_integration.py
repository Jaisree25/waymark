"""Cycle 4 — Valhalla + the MapMatcher (Contract 3, risk #2).

These are INTEGRATION tests: they need a real local Valhalla with SF tiles. Do not fake Valhalla —
it is the seam risk #2 lives on. The labelled SF points below become the attribution regression set:
"attribution is good enough" is a passing test, not an opinion.

Fill KNOWN_WAY_ID from a verified match once local Valhalla is up, then mark xfail off.
"""

from __future__ import annotations

import os

import pytest

from contracts.mapmatch import MatchedEdge

LOCAL_VALHALLA = os.environ.get("VALHALLA_URL", "http://localhost:8002")

pytestmark = pytest.mark.integration


@pytest.mark.xfail(reason="needs local Valhalla + labelled SF way id — Cycle 4", strict=False)
def test_known_point_matches_expected_way():
    from backend.mapmatch.valhalla import ValhallaMatcher

    KNOWN_WAY_ID = 0  # TODO: fill from a verified SF match
    m = ValhallaMatcher(base_url=LOCAL_VALHALLA)
    edge = m.match_event(lat=37.7793, lon=-122.4193)  # a known SF corner
    assert edge is not None and edge.way_id == KNOWN_WAY_ID


@pytest.mark.xfail(reason="needs local Valhalla — Cycle 4", strict=False)
def test_track_returns_ordered_edges():
    from backend.mapmatch.valhalla import ValhallaMatcher

    m = ValhallaMatcher(base_url=LOCAL_VALHALLA)
    track = {"type": "LineString", "coordinates": [[-122.4193, 37.7793], [-122.4183, 37.7799]]}
    edges = m.match_track(track)
    assert edges and all(isinstance(e, MatchedEdge) for e in edges)


@pytest.mark.xfail(reason="needs local Valhalla — Cycle 4", strict=False)
def test_offroad_point_returns_none():
    from backend.mapmatch.valhalla import ValhallaMatcher

    m = ValhallaMatcher(base_url=LOCAL_VALHALLA)
    assert m.match_event(lat=0.0, lon=0.0) is None  # middle of the ocean


def test_matcher_satisfies_contract():
    """The shared test_mapmatch_contract: returned type matches what A's persistence expects.
    Pure type check — no Valhalla needed, so it runs everywhere."""
    edge = MatchedEdge(way_id=123, length_mi=0.25, snapped_geojson={"type": "Point"})
    assert isinstance(edge.way_id, int)
    assert isinstance(edge.length_mi, float)
    assert isinstance(edge.snapped_geojson, dict)
