"""ValhallaMatcher — Contract 3 implementation (Person C owns; Person A consumes).

Snaps GPS to OSM ways via Valhalla and reads back edge way_ids + matched geometry. Kept as a small
standalone client so M2/M3 reuse it unchanged.

Events snap via /locate (a single point; trace_attributes needs >=2 points); tracks snap via
/trace_attributes (Meili map-matching). The dataclass/interface come from contracts/mapmatch.py
(frozen). The HTTP-free parsing helpers (decode_polyline, parse_locate_match, parse_track_match) are
pure functions so the response handling is unit-tested without a live Valhalla; the ValhallaMatcher
class is exercised by the integration tests against a real local instance (risk #2).
"""

from __future__ import annotations

import httpx

# The frozen contract types. In the deployed layout contracts/ is on the path; this import mirrors
# how A imports the same interface so both sides agree on MatchedEdge's shape.
from contracts.mapmatch import MapMatcher, MatchedEdge

_METERS_PER_MILE = 1609.344
_KM_TO_MILES = 1000.0 / _METERS_PER_MILE  # Valhalla returns edge length in kilometers

# The ONE Valhalla 400 that genuinely means "no road here" for a track: 171 "No suitable edges near
# location" (observed against the live norcal instance). Everything else must surface, not be swallowed
# as "no match" — notably 172 "Exceeded breakage distance", which is a gappy track that would silently
# drop matched miles and inflate severity ÷ miles if we returned []. Reached only from match_track;
# pinned by test_is_no_match_* and test_offroad_track_returns_empty.
_NO_MATCH_ERROR_CODES = {171}


def _is_no_match(exc: httpx.HTTPStatusError) -> bool:
    if exc.response.status_code != 400:
        return False
    try:
        return exc.response.json().get("error_code") in _NO_MATCH_ERROR_CODES
    except Exception:
        return False


def decode_polyline(encoded: str, precision: int = 6) -> list[list[float]]:
    """Decode a Valhalla-encoded polyline into ``[lon, lat]`` pairs (GeoJSON coordinate order).

    Valhalla encodes shapes with the Google polyline algorithm at precision 6 (1e-6 degrees).
    """
    inv = 10 ** -precision
    coords: list[list[float]] = []
    index = 0
    lat = 0
    lon = 0
    length = len(encoded)
    while index < length:
        for is_lon in (False, True):
            shift = 0
            result = 0
            while True:
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            delta = ~(result >> 1) if (result & 1) else (result >> 1)
            if is_lon:
                lon += delta
            else:
                lat += delta
        coords.append([round(lon * inv, precision), round(lat * inv, precision)])
    return coords


def _edge_length_mi(edge: dict) -> float:
    return float(edge.get("length", 0.0)) * _KM_TO_MILES


def parse_locate_match(payload: list) -> MatchedEdge | None:
    """Extract the nearest way for a single event point from a Valhalla /locate response.

    /locate is the right endpoint for one point (map-matching needs >=2). It answers HTTP 200 with
    ``edges: null`` when the point is off-road — so no-match is a clean None here, not a 400.
    ``length_mi`` is 0.0: a point has no length; exposure miles come from breadcrumb tracks, not events.
    """
    if not payload:
        return None
    loc = payload[0]
    edges = loc.get("edges") or []
    if not edges:
        return None
    edge = edges[0]
    way_id = (edge.get("edge_info") or {}).get("way_id", edge.get("way_id"))
    if way_id is None:
        return None
    snapped: dict = {}
    if edge.get("correlated_lat") is not None and edge.get("correlated_lon") is not None:
        snapped = {"type": "Point", "coordinates": [edge["correlated_lon"], edge["correlated_lat"]]}
    return MatchedEdge(way_id=int(way_id), length_mi=0.0, snapped_geojson=snapped)


def parse_track_match(payload: dict) -> list[MatchedEdge]:
    """Extract ordered matched edges for a track, each snapped to its slice of the matched shape."""
    edges = payload.get("edges") or []
    shape = payload.get("shape")
    coords = decode_polyline(shape) if shape else []
    out: list[MatchedEdge] = []
    for edge in edges:
        way_id = edge.get("way_id")
        if way_id is None:
            continue
        line: dict = {}
        b = edge.get("begin_shape_index")
        e = edge.get("end_shape_index")
        if coords and isinstance(b, int) and isinstance(e, int) and e >= b:
            seg = coords[b : e + 1]
            if len(seg) >= 2:
                line = {"type": "LineString", "coordinates": seg}
        out.append(MatchedEdge(way_id=int(way_id), length_mi=_edge_length_mi(edge), snapped_geojson=line))
    return out


class ValhallaMatcher(MapMatcher):
    def __init__(self, base_url: str, timeout_s: float = 10.0) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = httpx.Client(timeout=timeout_s)

    def match_event(self, lat: float, lon: float) -> MatchedEdge | None:
        # One point → /locate (trace_attributes needs >=2 points). Off-road returns 200 + edges:null.
        resp = self._client.post(
            f"{self._base_url}/locate",
            json={"locations": [{"lat": lat, "lon": lon}], "costing": "auto", "verbose": True},
        )
        resp.raise_for_status()
        return parse_locate_match(resp.json())

    def match_track(self, track_geojson: dict) -> list[MatchedEdge]:
        shape = [{"lat": c[1], "lon": c[0]} for c in track_geojson.get("coordinates", [])]
        if not shape:
            return []
        try:
            payload = self._trace(shape)
        except httpx.HTTPStatusError as exc:
            if _is_no_match(exc):
                return []
            raise
        return parse_track_match(payload)

    def close(self) -> None:
        self._client.close()

    # --- internals -------------------------------------------------------

    def _trace(self, shape: list[dict]) -> dict:
        resp = self._client.post(
            f"{self._base_url}/trace_attributes",
            json={"shape": shape, "costing": "auto", "shape_match": "map_snap", "units": "kilometers"},
        )
        resp.raise_for_status()
        return resp.json()
