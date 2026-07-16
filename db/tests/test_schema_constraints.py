"""Person A · Cycle 1 — the schema's constraints, asserted rather than hoped for.

Contract 1 is only trustworthy if the guarantees B and C rely on are *tested*: C leans on the
UNIQUE idempotency_key for safe retries, and on the FK to reject orphan events cleanly (its 409).
"""

from __future__ import annotations

import uuid

import psycopg
import pytest

from .conftest import seed_event, seed_trip


def test_event_requires_trip(db) -> None:
    """An event whose trip doesn't exist is rejected by the FK — this is what makes C's 409 real."""
    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        seed_event(db, trip_id=str(uuid.uuid4()))  # no such trip


def test_event_idempotency_key_unique(db) -> None:
    """Two events sharing an Idempotency-Key → the second is rejected. C's retry-safety rests here."""
    trip = seed_trip(db)
    seed_event(db, trip, idempotency_key="dupe")
    with pytest.raises(psycopg.errors.UniqueViolation):
        seed_event(db, trip, idempotency_key="dupe")


def test_trip_id_is_unique(db) -> None:
    """Re-POSTing a trip can't duplicate it (C relies on this PK for upsert idempotency)."""
    trip = seed_trip(db)
    with pytest.raises(psycopg.errors.UniqueViolation):
        seed_trip(db, trip_id=trip)


@pytest.mark.parametrize("severity", [0, 6, -1, 99])
def test_severity_range_rejects_out_of_band(db, severity: int) -> None:
    """severity must be 1..5. The DB is the last line of defence — a direct writer can't bypass it."""
    trip = seed_trip(db)
    with pytest.raises(psycopg.errors.CheckViolation):
        seed_event(db, trip, severity=severity)


@pytest.mark.parametrize("severity", [1, 3, 5, None])
def test_severity_range_accepts_valid(db, severity) -> None:
    """1..5 is valid, and NULL stays legal (an event captured but not yet rated)."""
    trip = seed_trip(db)
    seed_event(db, trip, severity=severity)  # must not raise


def test_unmatched_event_is_valid(db) -> None:
    """way_id/geom stay NULL until map-match runs — an event must be storable before attribution."""
    trip = seed_trip(db)
    seed_event(db, trip, way_id=None, snapped_lat=None, snapped_lon=None)
    with db.cursor() as cur:
        cur.execute("SELECT way_id, geom FROM events WHERE trip_id = %s", (trip,))
        assert cur.fetchone() == (None, None)


def test_scores_pk(db) -> None:
    """Duplicate (way_id, provider, version, as_of) is rejected — one snapshot per key."""
    stamp = "2026-07-14T03:00:00Z"
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO scores (way_id, severity_per_mile, gated, as_of) VALUES (100, 0.1, false, %s)",
            (stamp,),
        )
        with pytest.raises(psycopg.errors.UniqueViolation):
            cur.execute(
                "INSERT INTO scores (way_id, severity_per_mile, gated, as_of) VALUES (100, 0.2, false, %s)",
                (stamp,),
            )


def test_segment_exposure_pk_is_way_and_trip(db) -> None:
    """(way_id, trip_id) is the PK — exposure accumulates via upsert, never duplicate rows."""
    trip = seed_trip(db)
    with db.cursor() as cur:
        cur.execute("INSERT INTO segment_exposure (way_id, trip_id, miles) VALUES (100, %s, 0.5)", (trip,))
        with pytest.raises(psycopg.errors.UniqueViolation):
            cur.execute("INSERT INTO segment_exposure (way_id, trip_id, miles) VALUES (100, %s, 0.3)", (trip,))


def test_postgis_geography_round_trips(db) -> None:
    """geom really is SRID-4326 geography — the type, not just a blob (PostGIS is the point)."""
    trip = seed_trip(db)
    seed_event(db, trip)
    with db.cursor() as cur:
        cur.execute("SELECT ST_GeometryType(geom::geometry), ST_SRID(geom::geometry) FROM events")
        assert cur.fetchone() == ("ST_Point", 4326)
