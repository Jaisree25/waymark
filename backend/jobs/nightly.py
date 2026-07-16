"""The nightly pipeline — the Cloud Run Job's entrypoint (docs/M1/03-backend-gcp.md §6).

Three steps, in order, because each feeds the next:

    1. attribute events      raw fix  → events.way_id + snapped geom   (the NUMERATOR's attribution)
    2. build exposure        tracks   → segment_exposure.miles          (the DENOMINATOR)
    3. aggregate             both     → scores                          (severity ÷ miles, gated)

Step 3 alone is meaningless: with no exposure every way has a zero denominator, gates out, and
scores NULL. That's why the job orchestrates all three rather than just aggregating.

Map-matching happens HERE, not at ingest, so a slow or down Valhalla can never reject an upload —
the phone's data lands immediately as raw, and attribution catches up overnight.

`run_nightly` takes a `MapMatcher` (Contract 3) rather than building one, so the whole pipeline is
testable with a fake and no Valhalla. Only `main()` knows the real implementation exists.

Run:
    DATABASE_URL=postgresql://… VALHALLA_URL=http://valhalla:8002 python nightly.py
"""

from __future__ import annotations

import os
from typing import TYPE_CHECKING

import psycopg
from aggregate import aggregate, load_config
from exposure import attribute_unmatched_events, build_exposure

if TYPE_CHECKING:  # type-only: the pipeline depends on the interface, never an implementation
    from contracts.mapmatch import MapMatcher

_TRIPS_WITH_BREADCRUMBS_SQL = """
SELECT DISTINCT trip_id::text
FROM breadcrumb_segments
WHERE track IS NOT NULL
"""


def run_nightly(
    conn: psycopg.Connection,
    matcher: MapMatcher,
    *,
    gate_miles: float,
    calibration_version: str = "m1",
) -> dict[str, int]:
    """Attribute → build exposure → score. Returns counts per step.

    Safe to re-run: every step is idempotent (attribution skips already-matched events, exposure
    replaces a trip's rows, aggregation appends a new snapshot).
    """
    events_attributed = attribute_unmatched_events(conn, matcher)

    with conn.cursor() as cur:
        cur.execute(_TRIPS_WITH_BREADCRUMBS_SQL)
        trip_ids = [row[0] for row in cur.fetchall()]

    # Every trip is rebuilt each run, not just new ones. Uploads are resumable, so a trip's
    # breadcrumbs can arrive across several nights — skipping trips that already have exposure would
    # freeze them at whatever partial mileage landed first, permanently overstating their risk.
    # Rebuilding is O(all trips) in Valhalla calls; at M1's scale (two drivers) correctness is worth
    # more than the saving, but this is the first thing to make incremental as data grows.
    for trip_id in trip_ids:
        build_exposure(conn, trip_id, matcher)

    ways_scored = aggregate(conn, gate_miles=gate_miles, calibration_version=calibration_version)

    return {
        "events_attributed": events_attributed,
        "trips_exposed": len(trip_ids),
        "ways_scored": ways_scored,
    }


def _build_matcher() -> MapMatcher:
    """The real Valhalla client. Imported lazily so run_nightly stays testable without it."""
    from valhalla import ValhallaMatcher  # noqa: PLC0415 — C's implementation, shipped alongside

    return ValhallaMatcher(base_url=os.environ["VALHALLA_URL"])


def main() -> None:
    config = load_config()
    gate_miles = config["scoring"]["min_mileage_gate_miles"]
    calibration_version = config.get("calibration_version", "m1")

    matcher = _build_matcher()
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        result = run_nightly(
            conn, matcher, gate_miles=gate_miles, calibration_version=calibration_version
        )
        conn.commit()

    print(
        f"nightly: attributed {result['events_attributed']} events, "
        f"rebuilt exposure for {result['trips_exposed']} trips, "
        f"scored {result['ways_scored']} ways "
        f"(gate={gate_miles} mi, calibration={calibration_version})"
    )


if __name__ == "__main__":
    main()
