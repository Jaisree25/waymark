"""Person A · Cycle 3 — exposure attribution, on real PostGIS with a FAKE MapMatcher.

A depends on exactly one external thing (Contract 3), and mocks it — so none of this needs Valhalla
running, and at Checkpoint 2 C's real ValhallaMatcher drops in with no code change.

The fake returns the real `MatchedEdge` from contracts/mapmatch.py rather than a look-alike: if C's
contract changes shape, these tests break here instead of at the integration checkpoint.
"""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[2]))  # repo root, for contracts/
from contracts.mapmatch import MatchedEdge  # noqa: E402

from exposure import attribute_event, attribute_unmatched_events, build_exposure  # noqa: E402

from .conftest import seed_trip  # noqa: E402

STRAIGHT_LINE = {"type": "LineString", "coordinates": [[-122.4193, 37.7793], [-122.4183, 37.7799]]}


def _point(lon: float, lat: float) -> dict:
    return {"type": "Point", "coordinates": [lon, lat]}


class FakeMatcher:
    """Contract 3, canned. Satisfies MapMatcher structurally — no inheritance needed."""

    def __init__(self, edges: list[MatchedEdge] | None = None, event_edge: MatchedEdge | None = None):
        self._edges = edges if edges is not None else [
            MatchedEdge(way_id=100, length_mi=0.5, snapped_geojson=STRAIGHT_LINE),
            MatchedEdge(way_id=101, length_mi=0.3, snapped_geojson=STRAIGHT_LINE),
        ]
        self._event_edge = event_edge
        self.track_calls: list[dict] = []

    def match_track(self, track_geojson: dict) -> list[MatchedEdge]:
        self.track_calls.append(track_geojson)
        return self._edges

    def match_event(self, lat: float, lon: float) -> MatchedEdge | None:
        return self._event_edge


def seed_breadcrumb(db, trip_id: str, track: dict = STRAIGHT_LINE) -> str:
    crumb_id = str(uuid.uuid4())
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO breadcrumb_segments (id, trip_id, track, idempotency_key) "
            "VALUES (%s, %s, ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)::geography, %s)",
            (crumb_id, trip_id, __import__("json").dumps(track), str(uuid.uuid4())),
        )
    return crumb_id


def seed_event(db, trip_id: str, raw_lat: float | None = 37.7793, raw_lon: float | None = -122.4193) -> str:
    event_id = str(uuid.uuid4())
    with db.cursor() as cur:
        cur.execute(
            """
            INSERT INTO events (id, trip_id, t_trigger, t_pre_seconds, t_post_seconds,
                                trigger_source, severity, raw_lat, raw_lon, idempotency_key)
            VALUES (%s, %s, now(), 8.0, 4.0, 'voice', 3, %s, %s, %s)
            """,
            (event_id, trip_id, raw_lat, raw_lon, str(uuid.uuid4())),
        )
    return event_id


def _exposure(db, trip_id: str) -> dict[int, float]:
    with db.cursor() as cur:
        cur.execute("SELECT way_id, miles FROM segment_exposure WHERE trip_id = %s", (trip_id,))
        return {row[0]: row[1] for row in cur.fetchall()}


# --- build_exposure ---


def test_exposure_sums_by_way(db) -> None:
    """A matched track becomes miles per way — the denominator the nightly score divides by."""
    trip = seed_trip(db)
    seed_breadcrumb(db, trip)

    build_exposure(db, trip, FakeMatcher())

    assert _exposure(db, trip) == {100: 0.5, 101: 0.3}


def test_repeated_way_accumulates(db) -> None:
    """A track revisiting a way sums its miles into the single (way_id, trip_id) row."""
    trip = seed_trip(db)
    seed_breadcrumb(db, trip)
    matcher = FakeMatcher([
        MatchedEdge(way_id=100, length_mi=0.5, snapped_geojson=STRAIGHT_LINE),
        MatchedEdge(way_id=101, length_mi=0.3, snapped_geojson=STRAIGHT_LINE),
        MatchedEdge(way_id=100, length_mi=0.2, snapped_geojson=STRAIGHT_LINE),  # back on 100
    ])

    build_exposure(db, trip, matcher)

    assert _exposure(db, trip) == {100: 0.7, 101: 0.3}


def test_build_exposure_is_idempotent(db) -> None:
    """Re-running recomputes rather than accumulating.

    This is the one that matters: double-counted miles would silently HALVE a road's
    severity_per_mile and make it look safer than it is.
    """
    trip = seed_trip(db)
    seed_breadcrumb(db, trip)

    build_exposure(db, trip, FakeMatcher())
    build_exposure(db, trip, FakeMatcher())

    assert _exposure(db, trip) == {100: 0.5, 101: 0.3}  # not doubled


def test_exposure_spans_multiple_breadcrumbs(db) -> None:
    """A trip's exposure is the sum over all its breadcrumb segments, not just the first."""
    trip = seed_trip(db)
    seed_breadcrumb(db, trip)
    seed_breadcrumb(db, trip)

    build_exposure(db, trip, FakeMatcher())

    assert _exposure(db, trip) == {100: 1.0, 101: 0.6}  # each crumb contributed 0.5 / 0.3


def test_exposure_is_per_trip(db) -> None:
    """Two trips over the same road keep separate rows — the aggregation sums them later."""
    trip_a, trip_b = seed_trip(db), seed_trip(db)
    seed_breadcrumb(db, trip_a)
    seed_breadcrumb(db, trip_b)

    build_exposure(db, trip_a, FakeMatcher())
    build_exposure(db, trip_b, FakeMatcher())

    assert _exposure(db, trip_a) == {100: 0.5, 101: 0.3}
    assert _exposure(db, trip_b) == {100: 0.5, 101: 0.3}


def test_trip_without_breadcrumbs_has_no_exposure(db) -> None:
    trip = seed_trip(db)
    assert build_exposure(db, trip, FakeMatcher()) == {}
    assert _exposure(db, trip) == {}


def test_unmatchable_track_writes_nothing(db) -> None:
    """A track the matcher can't place produces no exposure — no invented miles."""
    trip = seed_trip(db)
    seed_breadcrumb(db, trip)

    build_exposure(db, trip, FakeMatcher(edges=[]))

    assert _exposure(db, trip) == {}


# --- attribute_event (risk #2) ---


def test_event_gets_way_id_and_snapped_geom(db) -> None:
    """A matched event gets its way_id and snapped point — while raw is preserved untouched."""
    trip = seed_trip(db)
    event = seed_event(db, trip)
    matcher = FakeMatcher(event_edge=MatchedEdge(100, 0.05, _point(-122.4190, 37.7795)))

    edge = attribute_event(db, event, matcher)

    assert edge is not None and edge.way_id == 100
    with db.cursor() as cur:
        cur.execute(
            "SELECT way_id, ST_X(geom::geometry), ST_Y(geom::geometry), raw_lat, raw_lon "
            "FROM events WHERE id = %s",
            (event,),
        )
        way_id, snapped_lon, snapped_lat, raw_lat, raw_lon = cur.fetchone()

    assert way_id == 100
    assert (snapped_lon, snapped_lat) == pytest.approx((-122.4190, 37.7795))
    # Raw survives attribution — the raw→snapped delta IS the risk #2 check.
    assert (raw_lat, raw_lon) == (37.7793, -122.4193)


def test_unmatched_event_stays_valid_with_nulls(db) -> None:
    """No match → way_id/geom stay NULL and the event survives. We know it happened, not where."""
    trip = seed_trip(db)
    event = seed_event(db, trip)

    assert attribute_event(db, event, FakeMatcher(event_edge=None)) is None

    with db.cursor() as cur:
        cur.execute("SELECT way_id, geom, severity FROM events WHERE id = %s", (event,))
        assert cur.fetchone() == (None, None, 3)  # still a real, valid incident


def test_event_without_raw_fix_is_not_matched(db) -> None:
    """No raw coordinates → nothing to snap; don't call the matcher, don't guess."""
    trip = seed_trip(db)
    event = seed_event(db, trip, raw_lat=None, raw_lon=None)

    assert attribute_event(db, event, FakeMatcher(event_edge=MatchedEdge(100, 0.05, _point(0, 0)))) is None

    with db.cursor() as cur:
        cur.execute("SELECT way_id FROM events WHERE id = %s", (event,))
        assert cur.fetchone()[0] is None


# --- the nightly batch step ---


def test_attribute_unmatched_events(db) -> None:
    """Step 1 of the nightly: everything that arrived without a way_id gets snapped."""
    trip = seed_trip(db)
    seed_event(db, trip)
    seed_event(db, trip)
    matcher = FakeMatcher(event_edge=MatchedEdge(100, 0.05, _point(-122.4190, 37.7795)))

    assert attribute_unmatched_events(db, matcher) == 2

    with db.cursor() as cur:
        cur.execute("SELECT count(*) FROM events WHERE way_id = 100")
        assert cur.fetchone()[0] == 2


def test_attribute_unmatched_events_skips_already_matched(db) -> None:
    """Already-attributed events aren't re-matched — the batch is resumable and cheap to re-run."""
    trip = seed_trip(db)
    event = seed_event(db, trip)
    matcher = FakeMatcher(event_edge=MatchedEdge(100, 0.05, _point(-122.4190, 37.7795)))
    attribute_unmatched_events(db, matcher)

    assert attribute_unmatched_events(db, matcher) == 0  # nothing left to do


def test_fake_matcher_satisfies_the_frozen_contract() -> None:
    """The fake returns real MatchedEdge objects, so these tests track Contract 3's actual shape."""
    edge = FakeMatcher().match_track(STRAIGHT_LINE)[0]
    assert isinstance(edge, MatchedEdge)
    assert isinstance(edge.way_id, int)
    assert isinstance(edge.length_mi, float)
    assert edge.snapped_geojson["type"] == "LineString"
