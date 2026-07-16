"""Person A · Cycle 4 — the nightly scoring aggregation (feasibility risk #5).

The headline M1 number, per OSM way:

    severity_per_mile = Σ event.severity  /  Σ exposure miles
    gated             = total_miles < config.scoring.min_mileage_gate_miles

Plain SQL aggregation — no ML in M1; that restraint is the point of the slice. Each run writes a
fresh `scores` snapshot stamped with `as_of` and `calibration_version`, so scores are an audit trail
rather than a mutable current-value table.

This job aggregates what is ALREADY in the tables. Filling `events.way_id` and `segment_exposure`
is map-matching's job (exposure attribution, upstream of this) — if that hasn't run, ways simply
have no exposure and gate out, which is the honest result rather than a silent zero.

Run:
    DATABASE_URL=postgresql://… python aggregate.py
"""

from __future__ import annotations

import json
import os
from datetime import datetime
from pathlib import Path

import psycopg

DEFAULT_CONFIG_PATH = Path(__file__).parent / "config" / "scoring.json"

# One statement, so the whole snapshot shares a single as_of and can't tear across ways.
#
# FULL OUTER JOIN, deliberately: exposure and incidents are independent facts and a way can have
# either without the other. Each case is decided explicitly below rather than left to SQL defaults —
# this is risk #5, so "what does a weird way score?" must have an answer we chose.
_AGGREGATE_SQL = """
WITH exposure AS (
    SELECT way_id, SUM(miles) AS total_miles
    FROM segment_exposure
    GROUP BY way_id
),
incidents AS (
    SELECT way_id,
           COALESCE(SUM(severity), 0) AS total_severity,   -- SUM skips unrated (NULL) severities…
           COUNT(*)                   AS incident_count    -- …but the incident still happened.
    FROM events
    WHERE way_id IS NOT NULL          -- unmatched events can't be attributed to any road
    GROUP BY way_id
),
combined AS (
    SELECT COALESCE(e.way_id, i.way_id)      AS way_id,
           COALESCE(e.total_miles, 0)        AS total_miles,
           COALESCE(i.total_severity, 0)     AS total_severity,
           COALESCE(i.incident_count, 0)     AS incident_count
    FROM exposure e
    FULL OUTER JOIN incidents i ON i.way_id = e.way_id
)
INSERT INTO scores (way_id, provider, version, severity_per_mile, total_severity, total_miles,
                    incident_count, gated, calibration_version, as_of)
SELECT way_id,
       %(provider)s,
       %(version)s,
       -- No exposure → the ratio is undefined, so NULL. NOT 0, and never a divide-by-zero:
       -- "we don't know" must not render as "perfectly safe".
       CASE WHEN total_miles > 0 THEN total_severity / total_miles END,
       total_severity,
       total_miles,
       incident_count,
       -- Thin data (including the 0-mile case above) is gated, so the UI grays it out.
       total_miles < %(gate_miles)s,
       %(calibration_version)s,
       %(as_of)s
FROM combined
ORDER BY way_id
"""


def load_config(path: str | Path | None = None) -> dict:
    """Load the versioned scoring config. SCORING_CONFIG overrides the bundled default."""
    path = Path(path or os.environ.get("SCORING_CONFIG") or DEFAULT_CONFIG_PATH)
    return json.loads(path.read_text())


def aggregate(
    conn: psycopg.Connection,
    *,
    gate_miles: float,
    as_of: datetime | None = None,
    calibration_version: str = "m1",
    provider: str = "tesla",
    version: str = "all",
) -> int:
    """Write one `scores` snapshot. Returns the number of way rows written.

    `gate_miles` is injected rather than read from config here, so the caller owns config loading and
    tests can pin a hand-checkable threshold.
    """
    if as_of is None:
        as_of = _snapshot_stamp(conn)
    with conn.cursor() as cur:
        cur.execute(
            _AGGREGATE_SQL,
            {
                "gate_miles": gate_miles,
                "as_of": as_of,
                "calibration_version": calibration_version,
                "provider": provider,
                "version": version,
            },
        )
        return cur.rowcount


def _snapshot_stamp(conn: psycopg.Connection) -> datetime:
    """The wall-clock moment this snapshot was computed.

    clock_timestamp(), not now(): now() is the TRANSACTION timestamp, so two runs sharing a
    transaction would produce an identical as_of and collide on the scores PK. Read once here and
    passed to the INSERT as a parameter — inlining clock_timestamp() in the SQL would re-evaluate it
    per row and tear one snapshot across several timestamps.

    The DB's clock, not the caller's, so as_of is comparable with the other timestamps in the schema
    without worrying about skew between the job host and Postgres.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT clock_timestamp()")
        return cur.fetchone()[0]


def main() -> None:
    config = load_config()
    gate_miles = config["scoring"]["min_mileage_gate_miles"]
    calibration_version = config.get("calibration_version", "m1")
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        written = aggregate(conn, gate_miles=gate_miles, calibration_version=calibration_version)
        conn.commit()
    print(f"scored {written} ways (gate={gate_miles} mi, calibration={calibration_version})")


if __name__ == "__main__":
    main()
