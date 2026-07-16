"""The nightly pipeline, on real PostGIS with a FAKE MapMatcher.

The point of these: step 3 was already tested in isolation, but "aggregate works" and "the nightly
produces a real score" are different claims. Nothing populated segment_exposure in production before
this job existed, so every road would have gated out with a NULL score. These assert the chain.
"""

from __future__ import annotations

import json
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[3]))  # repo root, for contracts/
from contracts.mapmatch import MatchedEdge  # noqa: E402

from nightly import run_nightly  # noqa: E402

from .conftest import fetch_score, seed_trip  # noqa: E402

TRACK = {"type": "LineString", "coordinates": [[-122.4193, 37.7793], [-122.4183, 37.7799]]}
SNAPPED_POINT = {"type": "Point", "coordinates": [-122.4190, 37.7795]}
GATE = 5.0


class FakeMatcher:
    """Contract 3, canned: every track is 6 miles of way 100; every event snaps onto way 100."""

    def __init__(self, track_edges=None, event_edge=...):
        self._track_edges = (
            track_edges if track_edges is not None
            else [MatchedEdge(way_id=100, length_mi=6.0, snapped_geojson=TRACK)]
        )
        self._event_edge = (
            MatchedEdge(way_id=100, length_mi=0.0, snapped_geojson=SNAPPED_POINT)
            if event_edge is ... else event_edge
        )
        self.match_track_calls = 0
        self.match_event_calls = 0

    def match_track(self, track_geojson: dict):
        self.match_track_calls += 1
        return self._track_edges

    def match_event(self, lat: float, lon: float):
        self.match_event_calls += 1
        return self._event_edge


def seed_breadcrumb(db, trip_id: str) -> None:
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO breadcrumb_segments (id, trip_id, track, idempotency_key) "
            "VALUES (%s, %s, ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)::geography, %s)",
            (str(uuid.uuid4()), trip_id, json.dumps(TRACK), str(uuid.uuid4())),
        )


def seed_raw_event(db, trip_id: str, severity: int) -> None:
    """An event as ingest stores it: raw fix only, no way_id — attribution hasn't run yet."""
    with db.cursor() as cur:
        cur.execute(
            """
            INSERT INTO events (id, trip_id, t_trigger, t_pre_seconds, t_post_seconds,
                                trigger_source, severity, raw_lat, raw_lon, idempotency_key)
            VALUES (gen_random_uuid(), %s, now(), 8.0, 4.0, 'voice', %s, 37.7793, -122.4193, %s)
            """,
            (trip_id, severity, str(uuid.uuid4())),
        )


def _full_trip(db) -> str:
    """A trip as it lands from the phone: breadcrumbs + two unattributed events (severity 3 and 5)."""
    trip = seed_trip(db)
    seed_breadcrumb(db, trip)
    seed_raw_event(db, trip, severity=3)
    seed_raw_event(db, trip, severity=5)
    return trip


# --- the chain ---


def test_nightly_scores_a_raw_trip_end_to_end(db) -> None:
    """Raw uploads in, a real score out: 3+5 severity over 6 miles → 8/6 = 1.3333. Hand-checkable."""
    _full_trip(db)

    result = run_nightly(db, FakeMatcher(), gate_miles=GATE)

    assert result == {"events_attributed": 2, "trips_exposed": 1, "ways_scored": 1}
    score = fetch_score(db, 100)
    assert score["total_severity"] == 8
    assert score["total_miles"] == 6.0
    assert score["severity_per_mile"] == 8 / 6
    assert score["incident_count"] == 2
    assert score["gated"] is False


def test_aggregation_alone_would_have_gated_everything(db) -> None:
    """Why this job exists: without steps 1-2, there's no denominator and no attribution.

    This is the bug the pipeline closes — aggregate() on its own looks green while scoring nothing.
    """
    from aggregate import aggregate

    _full_trip(db)

    aggregate(db, gate_miles=GATE)  # step 3 only, as the job used to do

    assert fetch_score(db, 100) is None  # events unattributed, exposure empty → no road scored


def test_nightly_attributes_before_scoring(db) -> None:
    """Events arrive with no way_id; the pipeline must snap them or their severity scores nothing."""
    _full_trip(db)

    run_nightly(db, FakeMatcher(), gate_miles=GATE)

    with db.cursor() as cur:
        cur.execute("SELECT count(*) FROM events WHERE way_id IS NULL")
        assert cur.fetchone()[0] == 0


def test_nightly_builds_exposure_before_scoring(db) -> None:
    _full_trip(db)

    run_nightly(db, FakeMatcher(), gate_miles=GATE)

    with db.cursor() as cur:
        cur.execute("SELECT way_id, miles FROM segment_exposure")
        assert cur.fetchall() == [(100, 6.0)]


# --- re-running ---


def test_nightly_is_idempotent(db) -> None:
    """Re-running must not double exposure — that would halve the score and fake a safer road."""
    _full_trip(db)

    run_nightly(db, FakeMatcher(), gate_miles=GATE)
    run_nightly(db, FakeMatcher(), gate_miles=GATE)

    with db.cursor() as cur:
        cur.execute("SELECT miles FROM segment_exposure WHERE way_id = 100")
        assert cur.fetchone()[0] == 6.0  # not 12.0

    assert fetch_score(db, 100)["severity_per_mile"] == 8 / 6  # unchanged


def test_rerun_skips_already_attributed_events(db) -> None:
    """Attribution is the expensive part (a Valhalla call each) — don't redo settled work."""
    _full_trip(db)

    run_nightly(db, FakeMatcher(), gate_miles=GATE)
    second = FakeMatcher()
    result = run_nightly(db, second, gate_miles=GATE)

    assert result["events_attributed"] == 0
    assert second.match_event_calls == 0


def test_rerun_refolds_late_arriving_breadcrumbs(db) -> None:
    """Uploads are resumable, so a trip's breadcrumbs can land across nights. The rebuild catches up.

    If exposure were skipped for trips that already had rows, this trip would stay frozen at 6 miles
    and permanently overstate its risk.
    """
    trip = _full_trip(db)
    run_nightly(db, FakeMatcher(), gate_miles=GATE)
    assert fetch_score(db, 100)["total_miles"] == 6.0

    seed_breadcrumb(db, trip)  # the rest of the trip finally uploads
    run_nightly(db, FakeMatcher(), gate_miles=GATE)

    assert fetch_score(db, 100)["total_miles"] == 12.0  # both segments counted
    assert fetch_score(db, 100)["severity_per_mile"] == 8 / 12  # more miles → lower risk


# --- edges ---


def test_nightly_on_empty_database(db) -> None:
    """A night with no driving is a no-op, not a crash."""
    assert run_nightly(db, FakeMatcher(), gate_miles=GATE) == {
        "events_attributed": 0, "trips_exposed": 0, "ways_scored": 0
    }


def test_offroad_event_scores_nothing_but_survives(db) -> None:
    """An unmatchable event stays a valid row and attributes to no road (never a guessed one)."""
    trip = seed_trip(db)
    seed_breadcrumb(db, trip)
    seed_raw_event(db, trip, severity=5)

    run_nightly(db, FakeMatcher(event_edge=None), gate_miles=GATE)

    score = fetch_score(db, 100)
    assert score["total_severity"] == 0   # the severity landed nowhere…
    assert score["severity_per_mile"] == 0.0
    with db.cursor() as cur:                # …but the incident is still on record
        cur.execute("SELECT count(*) FROM events WHERE way_id IS NULL AND severity = 5")
        assert cur.fetchone()[0] == 1


def test_thin_trip_is_gated(db) -> None:
    """A short drive scores, but gates — the UI grays it rather than trusting one mile of data."""
    trip = seed_trip(db)
    seed_breadcrumb(db, trip)
    seed_raw_event(db, trip, severity=5)
    thin = FakeMatcher(track_edges=[MatchedEdge(way_id=100, length_mi=1.0, snapped_geojson=TRACK)])

    run_nightly(db, thin, gate_miles=GATE)

    score = fetch_score(db, 100)
    assert score["total_miles"] == 1.0
    assert score["gated"] is True


def test_pipeline_uses_only_the_matcher_interface(db) -> None:
    """run_nightly never imports Valhalla — it calls Contract 3, so the fake is a drop-in."""
    _full_trip(db)
    matcher = FakeMatcher()

    run_nightly(db, matcher, gate_miles=GATE)

    assert matcher.match_track_calls == 1
    assert matcher.match_event_calls == 2
