"""Ports (interfaces) for the risky external systems.

GCS and Firebase live behind these so unit tests fake them and never hit the network.
PostGIS and Valhalla are deliberately NOT faked (they are the seams most likely to break) —
those get real local instances in integration tests.
"""

from __future__ import annotations

from typing import Protocol


class StoragePort(Protocol):
    """Mints V4 signed PUT URLs so the phone uploads blobs directly to GCS."""

    def signed_upload_url(self, object_path: str) -> str: ...


class AuthPort(Protocol):
    """Validates a Firebase bearer ID token, returning the uid."""

    def verify(self, bearer_token: str) -> str: ...


class ExportsPort(Protocol):
    """Person A's read-only export queries. A owns the SQL; C only wraps these as endpoints.

    NOT one of the three frozen contracts (00-coordination.md §1-3) — those don't cover exports.
    This is the seam C needs A's `exports.py` to satisfy; C fakes it until A delivers. Raise with
    the team before changing the shape.

    Rows are plain dicts. A `geometry` key, when present, is a GeoJSON geometry dict and C lifts it
    out into the Feature; every other key becomes a Feature property.
    """

    def segment_rows(self) -> list[dict]:
        """road_segments ⨝ latest scores. Keys: geometry (LineString), way_id, severity_per_mile,
        total_miles, incident_count, gated."""
        ...

    def event_rows(self) -> list[dict]:
        """Events with BOTH raw and snapped position — the raw→snapped line is the risk #2 check.
        Keys: geometry (snapped Point), event_id, severity, way_id, raw_accuracy_m, trigger_source,
        raw_lat, raw_lon."""
        ...

    def csv_rows(self, dataset: str) -> list[dict]:
        """Flat rows for one of: events | trips | segment_exposure | scores."""
        ...
