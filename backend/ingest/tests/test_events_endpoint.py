"""Cycle 1 — ingest API request/response (GCS + Firebase faked). RED first."""

from __future__ import annotations

from .fixtures import (
    AUTH_HEADERS,
    GOLDEN_BREADCRUMB_IN,
    GOLDEN_EVENT_ID,
    GOLDEN_EVENT_IN,
    GOLDEN_TRIP_IN,
)


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_post_event_returns_signed_urls(client, fake_gcs):
    r = client.post(
        "/v1/events",
        json=GOLDEN_EVENT_IN,
        headers={**AUTH_HEADERS, "Idempotency-Key": "k1"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["audio_upload"].startswith("https://storage.googleapis.com/")
    assert fake_gcs.signed_calls == [
        f"events/{GOLDEN_EVENT_ID}/audio.wav",
        f"events/{GOLDEN_EVENT_ID}/sensors.json",
    ]


def test_post_trip_ok(client):
    r = client.post("/v1/trips", json=GOLDEN_TRIP_IN, headers=AUTH_HEADERS)
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_post_breadcrumb_ok(client):
    r = client.post(
        "/v1/breadcrumbs",
        json=GOLDEN_BREADCRUMB_IN,
        headers={**AUTH_HEADERS, "Idempotency-Key": "b1"},
    )
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_event_validation_rejects_bad_severity(client):
    bad = {**GOLDEN_EVENT_IN, "severity": 6}
    r = client.post("/v1/events", json=bad, headers={**AUTH_HEADERS, "Idempotency-Key": "k2"})
    assert r.status_code == 422  # Pydantic rejects before it reaches A's CHECK


def test_missing_idempotency_key_400(client):
    r = client.post("/v1/events", json=GOLDEN_EVENT_IN, headers=AUTH_HEADERS)
    assert r.status_code == 400


def test_missing_auth_401(client):
    r = client.post("/v1/events", json=GOLDEN_EVENT_IN, headers={"Idempotency-Key": "k3"})
    assert r.status_code == 401


def test_breadcrumb_rejects_degenerate_geometry(client):
    # Bad geometry must 422 at the schema, not 500 later in ST_GeomFromGeoJSON.
    for coords in ([], [[1.0]], [[1.0, 2.0]]):  # empty, single-scalar position, single point
        bad = {**GOLDEN_BREADCRUMB_IN, "track": {"type": "LineString", "coordinates": coords}}
        r = client.post("/v1/breadcrumbs", json=bad, headers={**AUTH_HEADERS, "Idempotency-Key": "bad"})
        assert r.status_code == 422, coords


def test_duplicate_idempotency_key_is_noop(client, fake_repo):
    headers = {**AUTH_HEADERS, "Idempotency-Key": "dupe"}
    r1 = client.post("/v1/events", json=GOLDEN_EVENT_IN, headers=headers)
    r2 = client.post("/v1/events", json=GOLDEN_EVENT_IN, headers=headers)
    assert r1.status_code == 200 and r2.status_code == 200
    assert len(fake_repo.events) == 1  # one row despite two POSTs
