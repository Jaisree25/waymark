"""ValhallaMatcher — Contract 3 implementation (Person C owns; Person A consumes).

Calls Valhalla's Meili map-matching endpoint (/trace_attributes) to snap GPS to OSM ways and read
back edge way_ids + matched geometry. Kept as a small standalone client so M2/M3 reuse it unchanged.

The dataclass/interface come from contracts/mapmatch.py (frozen). This file is the concrete impl;
A tests its exposure/attribution logic against a FAKE MapMatcher and only wires this at Checkpoint 2.
"""

from __future__ import annotations

import httpx

# The frozen contract types. In the deployed layout contracts/ is on the path; this import mirrors
# how A imports the same interface so both sides agree on MatchedEdge's shape.
from contracts.mapmatch import MapMatcher, MatchedEdge

_METERS_PER_MILE = 1609.344


class ValhallaMatcher(MapMatcher):
    def __init__(self, base_url: str, timeout_s: float = 10.0) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = httpx.Client(timeout=timeout_s)

    def match_event(self, lat: float, lon: float) -> MatchedEdge | None:
        edges = self._trace([{"lat": lat, "lon": lon}], shape_match="map_snap")
        return edges[0] if edges else None

    def match_track(self, track_geojson: dict) -> list[MatchedEdge]:
        shape = [{"lat": c[1], "lon": c[0]} for c in track_geojson.get("coordinates", [])]
        return self._trace(shape, shape_match="map_snap")

    # --- internals -------------------------------------------------------

    def _trace(self, shape: list[dict], shape_match: str) -> list[MatchedEdge]:
        resp = self._client.post(
            f"{self._base_url}/trace_attributes",
            json={"shape": shape, "costing": "auto", "shape_match": shape_match},
        )
        resp.raise_for_status()
        return self._parse_edges(resp.json())

    @staticmethod
    def _parse_edges(payload: dict) -> list[MatchedEdge]:
        edges: list[MatchedEdge] = []
        for e in payload.get("edges", []):
            way_id = e.get("way_id")
            if way_id is None:
                continue
            length_km = e.get("length", 0.0)  # Valhalla returns km on edges
            edges.append(
                MatchedEdge(
                    way_id=int(way_id),
                    length_mi=float(length_km) * 1000.0 / _METERS_PER_MILE,
                    snapped_geojson={},  # TODO Cycle 4: build from matched_points shape
                )
            )
        return edges
