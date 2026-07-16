"""Fixtures for the nightly aggregation — a real, migrated PostGIS per test.

Aggregation is SQL, so it's tested against real Postgres. Faking the DB here would test nothing.
"""

from __future__ import annotations

import os
import uuid
from pathlib import Path

import psycopg
import pytest

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://app:app@127.0.0.1:5433/fsd_test")
# A's canonical Contract 1 — read the real file, so schema drift breaks a test, not production.
SCHEMA_SQL = (Path(__file__).parents[3] / "db" / "schema.sql").read_text()


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
    with psycopg.connect(db_url, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
        cur.execute(SCHEMA_SQL)
    with psycopg.connect(db_url) as conn:
        yield conn


def seed_trip(db) -> str:
    trip_id = str(uuid.uuid4())
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO trips (id, user_id, provider, supervision, app_config_version, started_at) "
            "VALUES (%s, 'test-uid', 'tesla', true, 'cfg-1', now())",
            (trip_id,),
        )
    return trip_id


def seed_exposure(db, trip_id: str, way_id: int, miles: float) -> None:
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO segment_exposure (way_id, trip_id, miles) VALUES (%s, %s, %s)",
            (way_id, trip_id, miles),
        )


def seed_event(db, trip_id: str, way_id: int | None, severity: int | None) -> None:
    with db.cursor() as cur:
        cur.execute(
            """
            INSERT INTO events (id, trip_id, t_trigger, t_pre_seconds, t_post_seconds,
                                trigger_source, severity, way_id, idempotency_key)
            VALUES (%s, %s, now(), 8.0, 4.0, 'voice', %s, %s, %s)
            """,
            (str(uuid.uuid4()), trip_id, severity, way_id, str(uuid.uuid4())),
        )


def fetch_score(db, way_id: int) -> dict | None:
    with db.cursor() as cur:
        cur.execute(
            "SELECT severity_per_mile, total_severity, total_miles, incident_count, gated, "
            "calibration_version, as_of FROM scores WHERE way_id = %s ORDER BY as_of DESC LIMIT 1",
            (way_id,),
        )
        row = cur.fetchone()
    if row is None:
        return None
    keys = ("severity_per_mile", "total_severity", "total_miles", "incident_count", "gated",
            "calibration_version", "as_of")
    return dict(zip(keys, row))
