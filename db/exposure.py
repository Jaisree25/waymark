"""Person A · Cycle 3 — exposure attribution: matched geometry → rows.

Two jobs, both written against **Contract 3's `MapMatcher` interface** and never against Valhalla:

  * `build_exposure`   — a trip's breadcrumbs → `segment_exposure(way_id, trip_id, miles)`.
                         This is the DENOMINATOR the nightly aggregation divides by.
  * `attribute_event`  — an event's raw fix → its `way_id` + snapped `geom`.
                         This is the NUMERATOR's attribution, and feasibility risk #2.

Depending on the interface rather than the implementation is what lets this be tested with a fake
matcher and no Valhalla running, then handed C's real ValhallaMatcher at Checkpoint 2 with no code
change. Nothing here imports the matcher: it's a structural Protocol, so a fake satisfies it by
shape alone.
"""

from __future__ import annotations

import json
from collections import defaultdict
from typing import TYPE_CHECKING

import psycopg

if TYPE_CHECKING:  # type-only: no runtime coupling to C's implementation or to contracts/
    from contracts.mapmatch import MapMatcher, MatchedEdge

# One row per (way_id, trip_id) — the PK. The row means "this trip's miles on this way", so a
# recomputation REPLACES it rather than adding to it. That makes re-running safe: miles are summed
# per way in Python across the trip first, so a track revisiting a way still accumulates correctly,
# but running the job twice can't silently double a road's exposure and halve its risk score.
_UPSERT_EXPOSURE_SQL = """
INSERT INTO segment_exposure (way_id, trip_id, miles)
VALUES (%(way_id)s, %(trip_id)s, %(miles)s)
ON CONFLICT (way_id, trip_id) DO UPDATE SET miles = EXCLUDED.miles
"""

_FETCH_TRACKS_SQL = """
SELECT ST_AsGeoJSON(track)::jsonb
FROM breadcrumb_segments
WHERE trip_id = %s AND track IS NOT NULL
ORDER BY created_at
"""

_ATTRIBUTE_EVENT_SQL = """
UPDATE events
SET way_id = %(way_id)s,
    geom   = ST_SetSRID(ST_GeomFromGeoJSON(%(snapped)s), 4326)::geography
WHERE id = %(event_id)s
"""


def build_exposure(conn: psycopg.Connection, trip_id: str, matcher: MapMatcher) -> dict[int, float]:
    """Match a trip's breadcrumbs and write its exposure. Returns miles per way_id.

    Idempotent: re-running recomputes the same rows rather than accumulating onto them.
    """
    with conn.cursor() as cur:
        cur.execute(_FETCH_TRACKS_SQL, (trip_id,))
        tracks = [row[0] for row in cur.fetchall()]

    miles_by_way: dict[int, float] = defaultdict(float)
    for track in tracks:
        for edge in matcher.match_track(track):
            # A track can cross the same way more than once (a loop, a there-and-back). Summing here
            # means the DB write stays a plain replace.
            miles_by_way[edge.way_id] += edge.length_mi

    if miles_by_way:
        with conn.cursor() as cur:
            cur.executemany(
                _UPSERT_EXPOSURE_SQL,
                [
                    {"way_id": way_id, "trip_id": trip_id, "miles": miles}
                    for way_id, miles in miles_by_way.items()
                ],
            )
    return dict(miles_by_way)


def attribute_event(conn: psycopg.Connection, event_id: str, matcher: MapMatcher) -> MatchedEdge | None:
    """Snap one event onto a way, filling way_id + geom. Returns the matched edge, or None.

    An unmatchable event (off-road, or no fix) keeps way_id/geom NULL and stays a valid row: we
    record that it happened but not where. Dropping it would hide a real incident; guessing a road
    would fabricate attribution — and misattribution is exactly what risk #2 is watching for.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT raw_lat, raw_lon FROM events WHERE id = %s", (event_id,))
        row = cur.fetchone()
    if row is None or row[0] is None or row[1] is None:
        return None  # no raw fix — nothing to snap

    edge = matcher.match_event(lat=row[0], lon=row[1])
    if edge is None:
        return None  # off-road: leave way_id/geom NULL rather than inventing a road

    with conn.cursor() as cur:
        cur.execute(
            _ATTRIBUTE_EVENT_SQL,
            {
                "way_id": edge.way_id,
                "snapped": json.dumps(edge.snapped_geojson),
                "event_id": event_id,
            },
        )
    return edge


def attribute_unmatched_events(conn: psycopg.Connection, matcher: MapMatcher) -> int:
    """Snap every event that arrived without a way_id. Returns how many were attributed.

    Step 1 of the nightly pipeline: ingest stores events immediately (raw only), and attribution
    happens here, so a slow or down Valhalla can never reject an upload.
    """
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id::text FROM events "
            "WHERE way_id IS NULL AND raw_lat IS NOT NULL AND raw_lon IS NOT NULL"
        )
        event_ids = [row[0] for row in cur.fetchall()]

    return sum(1 for event_id in event_ids if attribute_event(conn, event_id, matcher) is not None)
