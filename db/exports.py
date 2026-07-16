"""Person A · Cycle 5 — the export queries behind C's inspection-UI endpoints.

A owns the SQL; C owns the HTTP. So this module hands C plain callables returning plain dicts —
no FastAPI, no web framework, nothing importable only inside the ingest service. C wraps these in
routes (see backend/ingest/app/main.py) and its ExportsPort describes exactly this shape; the match
is structural, so nothing here imports C.

Row convention: a `geometry` key, when present, is a GeoJSON geometry dict that C lifts into the
Feature; every other key becomes a Feature property.
"""

from __future__ import annotations

import psycopg
from psycopg.rows import dict_row

# road_segments ⨝ its LATEST score. A way with no score yet is returned as gated=true, so the UI
# renders it gray/dashed: "no data" must never look like "zero risk" (the M1 anti-misleading rule).
_SEGMENT_ROWS_SQL = """
SELECT rs.way_id,
       ST_AsGeoJSON(rs.geom)::jsonb AS geometry,
       s.severity_per_mile,
       s.total_miles,
       s.incident_count,
       COALESCE(s.gated, true)      AS gated
FROM road_segments rs
LEFT JOIN LATERAL (
    SELECT severity_per_mile, total_miles, incident_count, gated
    FROM scores
    WHERE scores.way_id = rs.way_id
    ORDER BY as_of DESC
    LIMIT 1
) s ON true
ORDER BY rs.way_id
"""

# Events carry BOTH positions: geometry is the snapped point, raw_lat/raw_lon the original fix.
# The distance between them is the map-match error the inspector draws — this query IS risk #2.
# geom is NULL until map-match runs, so geometry comes back None for unattributed events.
_EVENT_ROWS_SQL = """
SELECT e.id::text AS event_id,
       ST_AsGeoJSON(e.geom)::jsonb AS geometry,
       e.severity,
       e.way_id,
       e.raw_accuracy_m,
       e.trigger_source,
       e.raw_lat,
       e.raw_lon
FROM events e
ORDER BY e.t_trigger
"""

# Explicit column lists (never SELECT *) so the CSV headers are a stable contract for the
# feasibility report, and adding a column to a table can't silently reshape an export.
# The jsonb bags (features/metrics/motion_summary) are deliberately omitted — they don't flatten.
_CSV_SQL = {
    "events": """
        SELECT e.id::text      AS id,
               e.trip_id::text AS trip_id,
               e.t_trigger, e.trigger_source, e.event_type, e.severity, e.way_id,
               e.raw_lat, e.raw_lon, e.raw_accuracy_m,
               ST_Y(e.geom::geometry) AS snapped_lat,
               ST_X(e.geom::geometry) AS snapped_lon,
               e.audio_uri, e.sensor_uri, e.created_at
        FROM events e
        ORDER BY e.t_trigger
    """,
    "trips": """
        SELECT id::text AS id, user_id, provider, fsd_version, supervision, vehicle,
               app_config_version, started_at, ended_at, created_at
        FROM trips
        ORDER BY started_at
    """,
    "segment_exposure": """
        SELECT way_id, trip_id::text AS trip_id, miles
        FROM segment_exposure
        ORDER BY way_id, trip_id
    """,
    "scores": """
        SELECT way_id, provider, version, severity_per_mile, total_severity, total_miles,
               incident_count, gated, calibration_version, as_of
        FROM scores
        ORDER BY way_id, as_of DESC
    """,
}

CSV_DATASETS = tuple(_CSV_SQL)


class SqlExports:
    """Read-only export queries over the Contract-1 schema."""

    def __init__(self, database_url: str) -> None:
        self._url = database_url

    def _fetch(self, sql: str, params: tuple = ()) -> list[dict]:
        # Read-only and infrequent (an inspector refresh), so a short-lived connection is fine —
        # unlike the ingest write path, which pools.
        with psycopg.connect(self._url, row_factory=dict_row) as conn, conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()

    def segment_rows(self) -> list[dict]:
        return self._fetch(_SEGMENT_ROWS_SQL)

    def event_rows(self) -> list[dict]:
        return self._fetch(_EVENT_ROWS_SQL)

    def csv_rows(self, dataset: str) -> list[dict]:
        if dataset not in _CSV_SQL:
            raise ValueError(f"unknown dataset: {dataset!r}; expected one of {CSV_DATASETS}")
        return self._fetch(_CSV_SQL[dataset])
