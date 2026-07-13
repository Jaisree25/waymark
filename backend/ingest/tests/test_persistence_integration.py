"""Cycle 2 — persistence + idempotency against a REAL local PostGIS (do not fake the DB).

Loads the Contract-1 schema mirror (contract_schema.sql) into the test DB, wires the app with the
real SqlRepository (GCS/Firebase still faked), and proves rows land and retries dedupe. Skips cleanly
when no PostGIS is reachable:

    docker run -d --name fsd-pg-test -p 5433:5432 \
      -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd_test postgis/postgis:16-3.4
    pytest -m integration
"""

from __future__ import annotations

import os
from pathlib import Path

import psycopg
import pytest
from fastapi.testclient import TestClient

from app.deps import AppState
from app.main import create_app
from app.repository import SqlRepository

from .conftest import FakeAuth, FakeStorage
from .fixtures import (
    AUTH_HEADERS,
    GOLDEN_BREADCRUMB_IN,
    GOLDEN_EVENT_ID,
    GOLDEN_EVENT_IN,
    GOLDEN_TRIP_ID,
    GOLDEN_TRIP_IN,
)

pytestmark = pytest.mark.integration

# 127.0.0.1 not "localhost": on Windows localhost resolves to IPv6 ::1 first and stalls ~5s per
# connect before falling back to IPv4, and each repo call opens a fresh connection.
TEST_DB_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://app:app@127.0.0.1:5433/fsd_test")
SCHEMA_SQL = (Path(__file__).parent / "contract_schema.sql").read_text()
_DATA_TABLES = "trips, events, breadcrumb_segments, segment_exposure, scores, road_segments"


def _db_reachable(url: str) -> bool:
    try:
        psycopg.connect(url, connect_timeout=2).close()
        return True
    except Exception:
        return False


@pytest.fixture(scope="module")
def db_url() -> str:
    if not _db_reachable(TEST_DB_URL):
        pytest.skip(f"no PostGIS at {TEST_DB_URL}; start fsd-pg-test or set TEST_DATABASE_URL")
    with psycopg.connect(TEST_DB_URL) as conn, conn.cursor() as cur:
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
        cur.execute(SCHEMA_SQL)
    return TEST_DB_URL


@pytest.fixture
def client(db_url: str):
    # Truncate between tests for isolation (CASCADE clears FK children too).
    with psycopg.connect(db_url) as conn, conn.cursor() as cur:
        cur.execute(f"TRUNCATE {_DATA_TABLES} CASCADE")
    repo = SqlRepository(db_url)
    state = AppState(storage=FakeStorage(), auth=FakeAuth(), repo=repo)
    yield TestClient(create_app(state))
    repo.close()  # release the pool so tests don't leak connections


def _count(db_url: str, table: str) -> int:
    with psycopg.connect(db_url) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT count(*) FROM {table}")
        return cur.fetchone()[0]


def _post_trip(client: TestClient, body: dict | None = None):
    return client.post("/v1/trips", json=body or GOLDEN_TRIP_IN, headers=AUTH_HEADERS)


def test_trip_persists(client, db_url):
    assert _post_trip(client).status_code == 200
    assert _count(db_url, "trips") == 1


def test_trip_upsert_idempotent(client, db_url):
    _post_trip(client)
    _post_trip(client)  # same id again
    assert _count(db_url, "trips") == 1


def test_user_id_is_authenticated_uid_not_body(client, db_url):
    # FakeAuth returns "test-uid"; the body claims a different user — the token must win.
    _post_trip(client, {**GOLDEN_TRIP_IN, "user_id": "spoofed-uid"})
    with psycopg.connect(db_url) as conn, conn.cursor() as cur:
        cur.execute("SELECT user_id FROM trips WHERE id = %s", (GOLDEN_TRIP_ID,))
        assert cur.fetchone()[0] == "test-uid"


def test_event_persists_with_fields(client, db_url):
    _post_trip(client)  # FK: trip must exist first
    r = client.post("/v1/events", json=GOLDEN_EVENT_IN, headers={**AUTH_HEADERS, "Idempotency-Key": "k1"})
    assert r.status_code == 200
    assert _count(db_url, "events") == 1
    with psycopg.connect(db_url) as conn, conn.cursor() as cur:
        cur.execute("SELECT trigger_source, severity, way_id FROM events WHERE id = %s", (GOLDEN_EVENT_ID,))
        assert cur.fetchone() == ("voice", 3, None)  # way_id NULL until map-match (Person A, later)


def test_event_before_trip_returns_409(client, db_url):
    # No trip yet → FK violation → clean 409 (via the IntegrityError handler), not a raw 500.
    r = client.post("/v1/events", json=GOLDEN_EVENT_IN, headers={**AUTH_HEADERS, "Idempotency-Key": "orphan"})
    assert r.status_code == 409
    assert _count(db_url, "events") == 0


def test_duplicate_idempotency_key_is_noop(client, db_url):
    _post_trip(client)
    headers = {**AUTH_HEADERS, "Idempotency-Key": "dupe"}
    r1 = client.post("/v1/events", json=GOLDEN_EVENT_IN, headers=headers)
    r2 = client.post("/v1/events", json=GOLDEN_EVENT_IN, headers=headers)
    assert r1.status_code == 200 and r2.status_code == 200  # both succeed
    assert _count(db_url, "events") == 1                     # but only one row


def test_breadcrumb_persists_as_geography(client, db_url):
    _post_trip(client)
    r = client.post("/v1/breadcrumbs", json=GOLDEN_BREADCRUMB_IN, headers={**AUTH_HEADERS, "Idempotency-Key": "b1"})
    assert r.status_code == 200
    assert _count(db_url, "breadcrumb_segments") == 1
    with psycopg.connect(db_url) as conn, conn.cursor() as cur:
        # the GeoJSON LineString became a real SRID-4326 geography linestring
        cur.execute(
            "SELECT ST_GeometryType(track::geometry), ST_SRID(track::geometry) "
            "FROM breadcrumb_segments WHERE id = %s",
            (GOLDEN_BREADCRUMB_IN["id"],),
        )
        assert cur.fetchone() == ("ST_LineString", 4326)


def test_breadcrumb_duplicate_idempotency_key_is_noop(client, db_url):
    _post_trip(client)
    headers = {**AUTH_HEADERS, "Idempotency-Key": "b-dupe"}
    client.post("/v1/breadcrumbs", json=GOLDEN_BREADCRUMB_IN, headers=headers)
    client.post("/v1/breadcrumbs", json=GOLDEN_BREADCRUMB_IN, headers=headers)
    assert _count(db_url, "breadcrumb_segments") == 1
