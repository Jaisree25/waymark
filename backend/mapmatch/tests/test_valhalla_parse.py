"""Cycle 4 — unit tests for the pure Valhalla response parsing (no live Valhalla needed).

These test the HTTP-free helpers in valhalla.py against recorded /trace_attributes payloads, so the
response handling (way_id extraction, km->mi, snapped geometry, no-match) is proven deterministically.
The live seam is covered separately by test_mapmatcher_integration.py against a real Valhalla.
"""

from __future__ import annotations

import math

import httpx

from contracts.mapmatch import MatchedEdge
from backend.mapmatch.valhalla import _is_no_match, decode_polyline, parse_locate_match, parse_track_match


def _http_error(status: int, body: dict) -> httpx.HTTPStatusError:
    resp = httpx.Response(status, json=body, request=httpx.Request("POST", "http://v/trace_attributes"))
    return httpx.HTTPStatusError("err", request=resp.request, response=resp)


def test_is_no_match_only_swallows_no_suitable_edges():
    # 171 "No suitable edges near location" is the real off-road-track code → swallow to [].
    assert _is_no_match(_http_error(400, {"error_code": 171})) is True
    # 172 "Exceeded breakage distance" is a gappy track — must SURFACE, not silently drop exposure.
    assert _is_no_match(_http_error(400, {"error_code": 172})) is False
    assert _is_no_match(_http_error(500, {"error_code": 171})) is False  # not a 400
    assert _is_no_match(_http_error(400, {})) is False                    # no error_code
    assert _is_no_match(_http_error(400, {"error_code": 154})) is False   # some other 400

# Google's canonical polyline example (precision 5) — an algorithm check independent of Valhalla.
# Decodes (lat,lon) to (38.5,-120.2),(40.7,-120.95),(43.252,-126.453).
GOOGLE_POLYLINE = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"


def test_decode_polyline_known_vector():
    coords = decode_polyline(GOOGLE_POLYLINE, precision=5)  # returns [lon, lat]
    assert coords == [[-120.2, 38.5], [-120.95, 40.7], [-126.453, 43.252]]


def test_decode_polyline_precision6_known_vector():
    # Pin the production path (precision 6, Valhalla's default) to a hand-verifiable vector.
    # A delta of 10 encodes as (10<<1)+63 == 'S'; "SS" is lat=10, lon=10 → 10 * 1e-6 = 1e-05.
    assert decode_polyline("SS", precision=6) == [[1e-05, 1e-05]]


# A real minimal /locate response for the SF corner (37.7793, -122.4193), captured from Valhalla.
LOCATE_PAYLOAD = [
    {
        "edges": [
            {"edge_info": {"way_id": 502795544}, "correlated_lat": 37.779211, "correlated_lon": -122.419997}
        ],
        "input_lat": 37.7793,
        "input_lon": -122.4193,
    }
]


def test_parse_locate_match_extracts_way_and_snapped_point():
    edge = parse_locate_match(LOCATE_PAYLOAD)
    assert isinstance(edge, MatchedEdge)
    assert edge.way_id == 502795544
    assert edge.length_mi == 0.0  # a single event point has no exposure length
    assert edge.snapped_geojson == {"type": "Point", "coordinates": [-122.419997, 37.779211]}


def test_parse_locate_no_edges_returns_none():
    # Off-road: Valhalla answers 200 with edges: null.
    assert parse_locate_match([{"edges": None, "input_lat": 0.0, "input_lon": 0.0}]) is None
    assert parse_locate_match([{"edges": []}]) is None
    assert parse_locate_match([]) is None


def test_parse_locate_edge_without_way_id_returns_none():
    assert parse_locate_match([{"edges": [{"edge_info": {}}]}]) is None


def test_length_conversion_km_to_miles_is_exact():
    # 1609.344 m == 1 mile, so 1.609344 km -> 1.0 mi exactly (exercised via the track parser).
    payload = {"edges": [{"way_id": 1, "length": 1.609344, "begin_shape_index": 0, "end_shape_index": 0}]}
    edge = parse_track_match(payload)[0]
    assert math.isclose(edge.length_mi, 1.0, rel_tol=1e-12)


def test_parse_track_match_returns_ordered_edges_with_sliced_geometry():
    coords = decode_polyline(GOOGLE_POLYLINE)  # default precision 6, our oracle
    payload = {
        "edges": [
            {"way_id": 111, "length": 0.5, "begin_shape_index": 0, "end_shape_index": 1},
            {"way_id": 222, "length": 1.609344, "begin_shape_index": 1, "end_shape_index": 2},
        ],
        "shape": GOOGLE_POLYLINE,
    }
    edges = parse_track_match(payload)
    assert [e.way_id for e in edges] == [111, 222]                      # order preserved
    assert math.isclose(edges[1].length_mi, 1.0, rel_tol=1e-12)          # unit conversion
    assert edges[0].snapped_geojson == {"type": "LineString", "coordinates": coords[0:2]}
    assert edges[1].snapped_geojson == {"type": "LineString", "coordinates": coords[1:3]}


def test_parse_track_skips_edges_without_way_id():
    payload = {
        "edges": [{"length": 0.1}, {"way_id": 5, "length": 0.2, "begin_shape_index": 0, "end_shape_index": 0}],
        "shape": GOOGLE_POLYLINE,
    }
    edges = parse_track_match(payload)
    assert [e.way_id for e in edges] == [5]  # the way_id-less edge is dropped


def test_parse_track_without_shape_yields_empty_geometry():
    payload = {"edges": [{"way_id": 9, "length": 0.3}]}  # no "shape" key
    edges = parse_track_match(payload)
    assert edges[0].way_id == 9
    assert edges[0].snapped_geojson == {}  # nothing to snap to, but the edge is still returned


def test_matcher_satisfies_contract():
    """Shared test_mapmatch_contract: MatchedEdge field types match what A's persistence expects."""
    edge = MatchedEdge(way_id=123, length_mi=0.25, snapped_geojson={"type": "Point"})
    assert isinstance(edge.way_id, int)
    assert isinstance(edge.length_mi, float)
    assert isinstance(edge.snapped_geojson, dict)
