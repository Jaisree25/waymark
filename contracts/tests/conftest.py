"""Fixtures for the shared contract tests.

These tests are owned jointly and deliberately fake as little as possible: their whole job is to
catch the seams between three people drifting apart. So they load B's ACTUAL golden payload, C's
ACTUAL app, and A's ACTUAL schema — never a local copy of any of them. A copy would keep passing
after the original changed, which is the exact failure these exist to prevent.

    docker run -d --name fsd-pg-test -p 5433:5432 \
      -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd_test postgis/postgis:16-3.4
    cd contracts && pytest
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import psycopg
import pytest
import yaml
from fastapi.testclient import TestClient

# C's app and A's schema, imported from their real homes (see pythonpath in contracts/pyproject.toml).
from app.deps import AppState
from app.main import create_app
from app.ports import AuthPort, StoragePort
from app.repository import SqlRepository

REPO_ROOT = Path(__file__).parents[2]

# The three contracts, plus B's golden payload — every one read from its owner's tree.
OPENAPI_PATH = REPO_ROOT / "contracts" / "openapi.yaml"
SCHEMA_SQL_PATH = REPO_ROOT / "db" / "schema.sql"
B_GOLDEN_EVENT_PATH = REPO_ROOT / "app" / "test" / "golden" / "event_payload.json"

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://app:app@127.0.0.1:5433/fsd_test")

AUTH_HEADERS = {"Authorization": "Bearer test"}
TEST_UID = "test-uid"


# --- the artefacts under test ---


@pytest.fixture(scope="session")
def openapi() -> dict:
    """Contract 2, as C froze it and B mocked against."""
    return yaml.safe_load(OPENAPI_PATH.read_text())


@pytest.fixture(scope="session")
def golden_event() -> dict:
    """B's real golden event payload — the bytes B's uploader tests assert on.

    Read from app/test/golden/, not copied here: if B changes what the phone sends, this suite must
    fail rather than keep validating a stale duplicate.
    """
    if not B_GOLDEN_EVENT_PATH.exists():
        pytest.skip(f"B's golden payload not found at {B_GOLDEN_EVENT_PATH}")
    return json.loads(B_GOLDEN_EVENT_PATH.read_text())


@pytest.fixture
def golden_trip(golden_event: dict) -> dict:
    """The trip B's event belongs to — events FK to it, so it must be posted first."""
    return {
        "id": golden_event["trip_id"],
        "user_id": TEST_UID,
        "provider": "tesla",
        "supervision": True,
        "app_config_version": "cfg-1",
        "started_at": "2026-07-10T17:00:00Z",
    }


# --- the real app over the real schema (only GCS + Firebase are faked) ---


class FakeStorage(StoragePort):
    """GCS is faked; signed URLs are C's own concern and covered by C's suite."""

    def signed_upload_url(self, object_path: str) -> str:
        return f"https://storage.googleapis.com/fake-bucket/{object_path}"


class FakeAuth(AuthPort):
    def verify(self, bearer_token: str) -> str:
        return TEST_UID


def _db_reachable(url: str) -> bool:
    try:
        psycopg.connect(url, connect_timeout=2).close()
        return True
    except Exception:
        return False


@pytest.fixture
def db_url() -> str:
    """A database migrated from A's canonical schema.sql — not a mirror, not a fixture copy."""
    if not _db_reachable(TEST_DB_URL):
        pytest.skip(f"no PostGIS at {TEST_DB_URL}; start fsd-pg-test or set TEST_DATABASE_URL")
    with psycopg.connect(TEST_DB_URL, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
        cur.execute(SCHEMA_SQL_PATH.read_text())
    return TEST_DB_URL


@pytest.fixture
def client(db_url: str) -> TestClient:
    """C's real app, writing to A's real schema."""
    repo = SqlRepository(db_url)
    state = AppState(storage=FakeStorage(), auth=FakeAuth(), repo=repo)
    yield TestClient(create_app(state))
    repo.close()
