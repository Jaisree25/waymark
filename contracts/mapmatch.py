"""Contract 3 — the map-match client interface.

FROZEN interface. Person C IMPLEMENTS it (ValhallaMatcher, in backend/mapmatch/);
Person A MOCKS it to test exposure/attribution without a live Valhalla.
Source: docs/M1/Implementation/00-coordination.md §3. Do not change except by team decision.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass
class MatchedEdge:
    way_id: int
    length_mi: float
    snapped_geojson: dict  # LineString for breadcrumbs, Point for events


class MapMatcher(Protocol):
    """The seam A depends on. C's ValhallaMatcher satisfies this; A's tests fake it."""

    def match_event(self, lat: float, lon: float) -> MatchedEdge | None:
        """Snap a single point to the nearest OSM way. None if off-road / no match."""
        ...

    def match_track(self, track_geojson: dict) -> list[MatchedEdge]:
        """Snap a polyline; return matched edges in order (for segment_exposure)."""
        ...
