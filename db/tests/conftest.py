"""Person A's test fixtures — a real, migrated PostGIS per test.

A's rule: test against a REAL PostGIS, never a mock. PostGIS geography math and the SQL constraints
ARE the thing under test, so faking them proves nothing.

    docker run -d --name fsd-pg-test -p 5433:5432 \
      -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd_test postgis/postgis:16-3.4
    cd db && pytest
"""

from __future__ import annotations

import os
import uuid
from pathlib import Path

import psycopg
import pytest

# 127.0.0.1 not "localhost": on Windows localhost resolves to IPv6 ::1 first and stalls per connect.
TEST_DB_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://app:app@127.0.0.1:5433/fsd_test")
SCHEMA_SQL = (Path(__file__).parents[1] / "schema.sql").read_text()


def _db_reachable(url: str) -> bool:
    try:
        psycopg.connect(url, connect_timeout=2).close()
        return True
    except Exception:
        return False


@pytest.fixture(scope="session")
def db_url() -> str:
    if not _db_reachable(TEST_DB_URL):
        pytest.skip(f"no PostGIS at {TEST_DB_URL}; start fsd-pg-test or set TEST_DATABASE_URL")
    return TEST_DB_URL


@pytest.fixture
def db(db_url: str):
    """A clean, migrated DB per test. Rebuilt from schema.sql so migrations are proven reproducible."""
    with psycopg.connect(db_url, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
        cur.execute(SCHEMA_SQL)
    with psycopg.connect(db_url) as conn:
        yield conn


# --- seed helpers (shared by the constraint and export tests) ---


def seed_trip(db, trip_id: str | None = None, user_id: str = "test-uid") -> str:
    trip_id = trip_id or str(uuid.uuid4())
    with db.cursor() as cur:
        cur.execute(
            """
            INSERT INTO trips (id, user_id, provider, supervision, app_config_version, started_at)
            VALUES (%s, %s, 'tesla', true, 'cfg-1', now())
            """,
            (trip_id, user_id),
        )
    return trip_id


def seed_event(db, trip_id: str, **overrides) -> str:
    """Insert an event. Defaults are a matched SF event: raw near, snapped onto way 100."""
    row = {
        "id": str(uuid.uuid4()),
        "severity": 3,
        "trigger_source": "voice",
        "way_id": 100,
        "raw_lat": 37.7793,
        "raw_lon": -122.4193,
        "raw_accuracy_m": 6.5,
        "snapped_lat": 37.7795,
        "snapped_lon": -122.4190,
        "idempotency_key": str(uuid.uuid4()),
    }
    row.update(overrides)
    geom = (
        "ST_SetSRID(ST_MakePoint(%(snapped_lon)s, %(snapped_lat)s), 4326)::geography"
        if row["snapped_lat"] is not None
        else "NULL"
    )
    with db.cursor() as cur:
        cur.execute(
            f"""
            INSERT INTO events (id, trip_id, t_trigger, t_pre_seconds, t_post_seconds,
                                trigger_source, severity, way_id, geom,
                                raw_lat, raw_lon, raw_accuracy_m, idempotency_key)
            VALUES (%(id)s, %(trip_id)s, now(), 8.0, 4.0, %(trigger_source)s, %(severity)s,
                    %(way_id)s, {geom}, %(raw_lat)s, %(raw_lon)s, %(raw_accuracy_m)s, %(idem)s)
            """,
            {**row, "trip_id": trip_id, "idem": row["idempotency_key"]},
        )
    return row["id"]


def seed_road_segment(db, way_id: int = 100, name: str = "Market St") -> None:
    with db.cursor() as cur:
        cur.execute(
            """
            INSERT INTO road_segments (way_id, geom, length_mi, road_class, name)
            VALUES (%s, ST_SetSRID(ST_MakeLine(ST_MakePoint(-122.4193, 37.7793),
                                               ST_MakePoint(-122.4183, 37.7799)), 4326)::geography,
                    0.08, 'secondary', %s)
            """,
            (way_id, name),
        )


def seed_score(db, way_id: int = 100, severity_per_mile: float = 0.12, gated: bool = False) -> None:
    with db.cursor() as cur:
        cur.execute(
            """
            INSERT INTO scores (way_id, severity_per_mile, total_severity, total_miles,
                                incident_count, gated)
            VALUES (%s, %s, 8.0, 4.0, 2, %s)
            """,
            (way_id, severity_per_mile, gated),
        )
