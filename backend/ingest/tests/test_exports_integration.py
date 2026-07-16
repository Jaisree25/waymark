"""The C↔A export seam, unfaked: A's real SqlExports driving C's inspect/export endpoints.

Cycle 6's other tests fake ExportsPort. This one wires A's actual SQL (db/exports.py) into C's app
against a real PostGIS, so a mismatch between what A returns and what C's routes expect fails HERE
rather than at Checkpoint 3. It's the exports analogue of the shared contract tests in
00-coordination.md §5, and the thing that proves ExportsPort is satisfied structurally.

    pytest -m integration tests/test_exports_integration.py
"""

from __future__ import annotations

import os
import sys
import uuid
from pathlib import Path

import psycopg
import pytest
from fastapi.testclient import TestClient

from app.deps import AppState
from app.main import create_app

from .conftest import FakeAuth, FakeRepo, FakeStorage

# A's module lives in db/, outside C's package tree — import it the way a deploy would wire it.
sys.path.insert(0, str(Path(__file__).parents[3] / "db"))
from exports import SqlExports  # noqa: E402

pytestmark = pytest.mark.integration

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://app:app@127.0.0.1:5433/fsd_test")
SCHEMA_SQL = (Path(__file__).parents[3] / "db" / "schema.sql").read_text()

TRIP_ID = str(uuid.uuid4())


def _db_reachable(url: str) -> bool:
    try:
        psycopg.connect(url, connect_timeout=2).close()
        return True
    except Exception:
        return False


@pytest.fixture
def seeded_db_url() -> str:
    if not _db_reachable(TEST_DB_URL):
        pytest.skip(f"no PostGIS at {TEST_DB_URL}; start fsd-pg-test or set TEST_DATABASE_URL")
    with psycopg.connect(TEST_DB_URL, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
        cur.execute(SCHEMA_SQL)
        cur.execute(
            """
            INSERT INTO road_segments (way_id, geom, length_mi, road_class, name)
            VALUES (100, ST_SetSRID(ST_MakeLine(ST_MakePoint(-122.4193, 37.7793),
                                                ST_MakePoint(-122.4183, 37.7799)), 4326)::geography,
                    0.08, 'secondary', 'Market St')
            """
        )
        cur.execute(
            "INSERT INTO scores (way_id, severity_per_mile, total_severity, total_miles, "
            "incident_count, gated) VALUES (100, 0.12, 8.0, 4.0, 2, false)"
        )
        cur.execute(
            "INSERT INTO trips (id, user_id, provider, supervision, app_config_version, started_at) "
            "VALUES (%s, 'test-uid', 'tesla', true, 'cfg-1', now())",
            (TRIP_ID,),
        )
        cur.execute(
            """
            INSERT INTO events (id, trip_id, t_trigger, t_pre_seconds, t_post_seconds, trigger_source,
                                severity, way_id, geom, raw_lat, raw_lon, raw_accuracy_m, idempotency_key)
            VALUES (%s, %s, now(), 8.0, 4.0, 'voice', 3, 100,
                    ST_SetSRID(ST_MakePoint(-122.4190, 37.7795), 4326)::geography,
                    37.7793, -122.4193, 6.5, 'k1')
            """,
            (str(uuid.uuid4()), TRIP_ID),
        )
    return TEST_DB_URL


@pytest.fixture
def client(seeded_db_url: str) -> TestClient:
    # The real SqlExports — no FakeExports anywhere in this test.
    state = AppState(
        storage=FakeStorage(), auth=FakeAuth(), repo=FakeRepo(), exports=SqlExports(seeded_db_url)
    )
    return TestClient(create_app(state))


def test_segments_geojson_from_real_sql(client: TestClient) -> None:
    body = client.get("/v1/inspect/segments.geojson").json()
    assert body["type"] == "FeatureCollection"
    feature = body["features"][0]
    assert feature["geometry"]["type"] == "LineString"
    assert feature["properties"]["way_id"] == 100
    assert feature["properties"]["severity_per_mile"] == 0.12
    assert feature["properties"]["gated"] is False
    assert "geometry" not in feature["properties"]  # C lifted A's geometry key into the Feature


def test_events_geojson_from_real_sql_shows_raw_and_snapped(client: TestClient) -> None:
    """The risk #2 line, end to end: A's SQL → C's route → drawable raw→snapped offset."""
    feature = client.get("/v1/inspect/events.geojson").json()["features"][0]
    assert feature["geometry"]["coordinates"] == [-122.4190, 37.7795]  # snapped
    props = feature["properties"]
    assert (props["raw_lon"], props["raw_lat"]) == (-122.4193, 37.7793)  # raw
    assert feature["geometry"]["coordinates"] != [props["raw_lon"], props["raw_lat"]]


def test_csv_exports_from_real_sql(client: TestClient) -> None:
    r = client.get("/v1/export/events.csv")
    assert r.status_code == 200
    assert r.headers["content-disposition"] == 'attachment; filename="events.csv"'
    header, first = r.text.splitlines()[0], r.text.splitlines()[1]
    assert header.startswith("id,trip_id,t_trigger,trigger_source")
    assert "voice" in first

    scores = client.get("/v1/export/scores.csv")
    assert scores.status_code == 200
    assert "severity_per_mile" in scores.text.splitlines()[0]
