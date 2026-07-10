"""Test fakes for the risky-but-not-the-point externals (GCS, Firebase, DB in Cycle 1).

Fake GCS and Firebase here. Do NOT fake PostGIS or Valhalla in integration tests — those are the
seams most likely to break and get real local instances.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.deps import AppState
from app.main import create_app
from app.ports import AuthPort, StoragePort
from app.repository import Repository
from app.schemas import BreadcrumbIn, EventIn, TripIn


class FakeStorage(StoragePort):
    def __init__(self) -> None:
        self.signed_calls: list[str] = []

    def signed_upload_url(self, object_path: str) -> str:
        self.signed_calls.append(object_path)
        return f"https://storage.googleapis.com/fake-bucket/{object_path}?X-Goog-Signature=fake"


class FakeAuth(AuthPort):
    def verify(self, bearer_token: str) -> str:
        return "test-uid"


class FakeRepo(Repository):
    def __init__(self) -> None:
        self.trips: dict[str, TripIn] = {}
        self.events: dict[str, EventIn] = {}
        self.breadcrumbs: dict[str, BreadcrumbIn] = {}

    def upsert_trip(self, trip: TripIn, uid: str) -> None:
        self.trips[trip.id] = trip

    def upsert_event(self, event: EventIn, idempotency_key: str) -> None:
        self.events.setdefault(idempotency_key, event)  # dedupe on key

    def upsert_breadcrumb(self, breadcrumb: BreadcrumbIn, idempotency_key: str) -> None:
        self.breadcrumbs.setdefault(idempotency_key, breadcrumb)


@pytest.fixture
def fake_gcs() -> FakeStorage:
    return FakeStorage()


@pytest.fixture
def fake_repo() -> FakeRepo:
    return FakeRepo()


@pytest.fixture
def client(fake_gcs: FakeStorage, fake_repo: FakeRepo) -> TestClient:
    state = AppState(storage=fake_gcs, auth=FakeAuth(), repo=fake_repo)
    return TestClient(create_app(state))
