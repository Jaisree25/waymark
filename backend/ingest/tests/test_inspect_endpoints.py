"""Cycle 6 — inspection + export endpoints (read-only wrappers over A's export queries).

C owns the HTTP shape; A owns the SQL behind ExportsPort. These tests fake the port, so they're
fast and need no DB — the queries themselves are A's to test.

The events.geojson assertions encode the risk #2 contract: every event carries BOTH its raw and its
snapped position, so inspector/index.html can draw the raw→snapped line.
"""

from __future__ import annotations

import csv
import io

import pytest
from fastapi.testclient import TestClient

from app.deps import AppState
from app.main import create_app
from app.ports import ExportsPort

from .conftest import FakeAuth, FakeRepo, FakeStorage

# --- golden rows the fake returns (shapes A's exports.py must produce) ---

SEGMENT_ROWS = [
    {
        "geometry": {"type": "LineString", "coordinates": [[-122.4193, 37.7793], [-122.4183, 37.7799]]},
        "way_id": 12345,
        "severity_per_mile": 0.12,
        "total_miles": 3.4,
        "incident_count": 2,
        "gated": False,
    },
    {
        "geometry": {"type": "LineString", "coordinates": [[-122.4100, 37.7700], [-122.4090, 37.7710]]},
        "way_id": 67890,
        "severity_per_mile": None,
        "total_miles": 0.2,
        "incident_count": 0,
        "gated": True,  # below the min-mileage gate → UI renders gray + dashed
    },
]

# Snapped point differs from raw — that offset IS the map-match error the inspector visualizes.
EVENT_ROWS = [
    {
        "geometry": {"type": "Point", "coordinates": [-122.4190, 37.7795]},  # snapped
        "event_id": "11111111-1111-1111-1111-111111111111",
        "severity": 3,
        "way_id": 12345,
        "raw_accuracy_m": 6.5,
        "trigger_source": "voice",
        "raw_lat": 37.7793,  # raw
        "raw_lon": -122.4193,
    }
]

CSV_ROWS = {
    "events": [{"id": "e1", "severity": 3, "way_id": 12345}],
    "trips": [{"id": "t1", "provider": "tesla", "supervision": True}],
    "segment_exposure": [{"way_id": 12345, "trip_id": "t1", "miles": 1.2}],
    "scores": [{"way_id": 12345, "severity_per_mile": 0.12, "gated": False}],
}

CSV_DATASETS = ("events", "trips", "segment_exposure", "scores")


class FakeExports(ExportsPort):
    def segment_rows(self) -> list[dict]:
        return SEGMENT_ROWS

    def event_rows(self) -> list[dict]:
        return EVENT_ROWS

    def csv_rows(self, dataset: str) -> list[dict]:
        return CSV_ROWS[dataset]


@pytest.fixture
def client() -> TestClient:
    state = AppState(storage=FakeStorage(), auth=FakeAuth(), repo=FakeRepo(), exports=FakeExports())
    return TestClient(create_app(state))


# --- segments.geojson ---


def test_segments_geojson_endpoint(client: TestClient) -> None:
    """Valid GeoJSON FeatureCollection whose properties carry the score fields the UI colors by."""
    r = client.get("/v1/inspect/segments.geojson")
    assert r.status_code == 200
    body = r.json()
    assert body["type"] == "FeatureCollection"
    assert len(body["features"]) == 2

    first = body["features"][0]
    assert first["type"] == "Feature"
    assert first["geometry"]["type"] == "LineString"
    props = first["properties"]
    assert props["way_id"] == 12345
    assert props["severity_per_mile"] == 0.12
    assert props == {"way_id": 12345, "severity_per_mile": 0.12, "total_miles": 3.4,
                     "incident_count": 2, "gated": False}
    assert "geometry" not in props  # geometry is lifted into the Feature, not left in properties


def test_segments_geojson_marks_gated(client: TestClient) -> None:
    """Thin-data segments stay flagged so the UI can render them gray/dashed (anti-misleading)."""
    gated = client.get("/v1/inspect/segments.geojson").json()["features"][1]
    assert gated["properties"]["gated"] is True


# --- events.geojson (risk #2) ---


def test_events_geojson_shows_raw_and_snapped(client: TestClient) -> None:
    """Each event exposes snapped geometry AND raw coords, so the raw→snapped line is drawable."""
    r = client.get("/v1/inspect/events.geojson")
    assert r.status_code == 200
    feature = r.json()["features"][0]

    # geometry is the SNAPPED point (what the map plots)
    assert feature["geometry"] == {"type": "Point", "coordinates": [-122.4190, 37.7795]}

    # ...and raw is carried alongside, distinct from snapped — the offset is the match error
    props = feature["properties"]
    assert props["raw_lat"] == 37.7793
    assert props["raw_lon"] == -122.4193
    assert (props["raw_lon"], props["raw_lat"]) != tuple(feature["geometry"]["coordinates"])
    assert props["raw_accuracy_m"] == 6.5
    assert props["event_id"] == "11111111-1111-1111-1111-111111111111"


# --- CSV exports ---


@pytest.mark.parametrize("dataset", CSV_DATASETS)
def test_csv_export_endpoints(client: TestClient, dataset: str) -> None:
    """All four CSVs download as attachments with a header row and their data."""
    r = client.get(f"/v1/export/{dataset}.csv")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/csv")
    assert r.headers["content-disposition"] == f'attachment; filename="{dataset}.csv"'

    rows = list(csv.DictReader(io.StringIO(r.text)))
    assert rows, f"{dataset}.csv had no data rows"
    assert list(rows[0].keys()) == list(CSV_ROWS[dataset][0].keys())


def test_csv_export_rejects_unknown_dataset(client: TestClient) -> None:
    r = client.get("/v1/export/passwords.csv")
    assert r.status_code == 404


# --- port not wired ---


def test_inspect_returns_503_when_exports_unconfigured() -> None:
    """Ingest-only deploys don't wire A's exports; say so cleanly instead of raising a 500."""
    state = AppState(storage=FakeStorage(), auth=FakeAuth(), repo=FakeRepo())  # no exports
    r = TestClient(create_app(state)).get("/v1/inspect/segments.geojson")
    assert r.status_code == 503
