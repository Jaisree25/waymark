"""The three shared contract tests (00-coordination.md §5) — owned jointly, run at checkpoints.

Each person's own suite passes against their *mocks* of everyone else. That's what makes three
parallel streams possible, and it's also what lets them drift apart silently: B's stub server and
C's real app can both be green while disagreeing. These are the regression net that catches that,
and the reason to run them on a laptop rather than discover it in a car at Checkpoint 3.

Each test spans lanes on purpose:

    test_openapi_roundtrip        B's payload → Contract 2 → C's app → A's schema
    test_mapmatch_contract        C's matcher → Contract 3 → A's persistence
    test_idempotency_end_to_end   B's retry → C's conflict handling → A's UNIQUE constraint
"""

from __future__ import annotations

import json

import psycopg
import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

# A's attribution consumes Contract 3; C's parser produces it. Both real — see pyproject pythonpath.
from contracts.mapmatch import MatchedEdge
from exposure import attribute_event
from valhalla import parse_locate_match

from .conftest import AUTH_HEADERS, TEST_UID


def _resolve(spec: dict, schema: dict) -> dict:
    """Inline the spec's $defs so jsonschema can validate a component standalone."""
    return {**schema, "$defs": spec["components"]["schemas"]}


# --- Contract 2: B → C → A -------------------------------------------------


def test_openapi_roundtrip(client: TestClient, openapi: dict, golden_event: dict, golden_trip: dict, db_url: str) -> None:
    """B's golden EventIn validates against openapi.yaml AND lands as a row in A's events table.

    This is the B↔C↔A seam in one assertion. B builds its uploader against the spec; C builds the
    server; A owns the table. All three can be individually green and still not fit.
    """
    # 1. B's payload satisfies Contract 2 as frozen.
    schema = _resolve(openapi, openapi["components"]["schemas"]["EventIn"])
    errors = sorted(Draft202012Validator(schema).iter_errors(golden_event), key=str)
    assert not errors, f"B's golden payload violates openapi.yaml: {[e.message for e in errors]}"

    # 2. C's real app accepts it.
    assert client.post("/v1/trips", json=golden_trip, headers=AUTH_HEADERS).status_code == 200
    response = client.post(
        "/v1/events", json=golden_event, headers={**AUTH_HEADERS, "Idempotency-Key": "k1"}
    )
    assert response.status_code == 200, response.text

    # 3. C's response satisfies Contract 2's response schema — B parses these fields.
    upload_schema = _resolve(openapi, openapi["components"]["schemas"]["EventUploadResponse"])
    assert not sorted(Draft202012Validator(upload_schema).iter_errors(response.json()), key=str)

    # 4. It became a real row in A's schema, with the fields B sent intact.
    with psycopg.connect(db_url) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT trip_id::text, trigger_source, severity, raw_lat, raw_lon, user_id "
            "FROM events JOIN trips ON trips.id = events.trip_id WHERE events.id = %s",
            (golden_event["id"],),
        )
        row = cur.fetchone()

    assert row is not None, "B's event validated and POSTed 200 but no row reached A's schema"
    trip_id, trigger_source, severity, raw_lat, raw_lon, user_id = row
    assert trip_id == golden_event["trip_id"]
    assert trigger_source == golden_event["trigger_source"]
    assert severity == golden_event["severity"]
    assert (raw_lat, raw_lon) == (golden_event["raw_lat"], golden_event["raw_lon"])
    # The uid comes from the token, never the body — a client can't attribute a trip to someone else.
    assert user_id == TEST_UID


def test_golden_trip_matches_contract(openapi: dict, golden_trip: dict) -> None:
    """The trip B posts alongside its events also satisfies Contract 2."""
    schema = _resolve(openapi, openapi["components"]["schemas"]["TripIn"])
    assert not sorted(Draft202012Validator(schema).iter_errors(golden_trip), key=str)


def test_app_matches_the_frozen_spec(client: TestClient, openapi: dict) -> None:
    """Every path in Contract 2 exists on C's running app — the spec isn't aspirational."""
    served = {route.path for route in client.app.routes}
    missing = [path for path in openapi["paths"] if path not in served]
    assert not missing, f"openapi.yaml promises paths the app doesn't serve: {missing}"


# --- Contract 3: C → A -----------------------------------------------------

# A real /locate response shape, so C's parser runs for real without Valhalla being up. C's own suite
# covers the HTTP; what's under test HERE is only whether C's output fits A's persistence.
_LOCATE_RESPONSE = [
    {
        "edges": [
            {
                "way_id": 12345678,
                "correlated_lat": 37.7795,
                "correlated_lon": -122.4190,
                "edge_info": {"way_id": 12345678},
            }
        ]
    }
]


def test_mapmatch_contract(client: TestClient, golden_event: dict, golden_trip: dict, db_url: str) -> None:
    """C's real matcher output has the exact types A's persistence expects — and A can store it.

    Not a type check against a hand-written stand-in: this feeds C's REAL parser output into A's
    REAL attribute_event, so a shape disagreement fails here rather than at Checkpoint 2.
    """
    edge = parse_locate_match(_LOCATE_RESPONSE)  # C's code, C's MatchedEdge

    # The types A's persistence code is written against (Contract 3).
    assert isinstance(edge, MatchedEdge)
    assert isinstance(edge.way_id, int)
    assert isinstance(edge.length_mi, float)
    assert isinstance(edge.snapped_geojson, dict)
    assert edge.snapped_geojson["type"] == "Point"  # events snap to a Point, tracks to a LineString

    # And A can actually persist it: bigint way_id, geography(Point) geom.
    client.post("/v1/trips", json=golden_trip, headers=AUTH_HEADERS)
    client.post("/v1/events", json=golden_event, headers={**AUTH_HEADERS, "Idempotency-Key": "k1"})

    class _Matcher:
        def match_event(self, lat: float, lon: float) -> MatchedEdge:
            return edge

        def match_track(self, track_geojson: dict) -> list[MatchedEdge]:
            return [edge]

    with psycopg.connect(db_url) as conn:
        assert attribute_event(conn, golden_event["id"], _Matcher()) is edge  # A consumes C's edge
        conn.commit()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT way_id, ST_X(geom::geometry), ST_Y(geom::geometry) FROM events WHERE id = %s",
                (golden_event["id"],),
            )
            way_id, lon, lat = cur.fetchone()

    assert way_id == 12345678  # C's way_id survived A's bigint column
    assert (lon, lat) == pytest.approx((-122.4190, 37.7795))


def test_mapmatch_contract_handles_no_match() -> None:
    """Off-road is None, not an exception or a fabricated way — A branches on exactly this."""
    assert parse_locate_match([{"edges": None}]) is None
    assert parse_locate_match([]) is None


# --- Idempotency: B's retry → C's handling → A's constraint ----------------


def test_idempotency_end_to_end(client: TestClient, golden_event: dict, golden_trip: dict, db_url: str) -> None:
    """B retries an upload → exactly one row. B's policy, C's conflict handling, A's UNIQUE agree.

    B's uploader retries on any uncertain outcome (a dropped connection mid-flight is normal in a
    moving car), so a retry MUST be a safe no-op returning 200 — a 409 would strand B's queue.
    """
    client.post("/v1/trips", json=golden_trip, headers=AUTH_HEADERS)
    headers = {**AUTH_HEADERS, "Idempotency-Key": "retry-me"}

    first = client.post("/v1/events", json=golden_event, headers=headers)
    second = client.post("/v1/events", json=golden_event, headers=headers)

    assert first.status_code == 200
    assert second.status_code == 200, "a retry must be a clean no-op, or B's queue stalls"

    with psycopg.connect(db_url) as conn, conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM events WHERE id = %s", (golden_event["id"],))
        assert cur.fetchone()[0] == 1  # A's UNIQUE constraint held


def test_idempotency_key_is_required(client: TestClient, golden_event: dict, golden_trip: dict) -> None:
    """C rejects an event with no Idempotency-Key — retry-safety can't be optional for B."""
    client.post("/v1/trips", json=golden_trip, headers=AUTH_HEADERS)
    assert client.post("/v1/events", json=golden_event, headers=AUTH_HEADERS).status_code == 400


def test_trip_upsert_is_idempotent(client: TestClient, golden_trip: dict, db_url: str) -> None:
    """B re-posts a trip on retry; A's PK makes it one row."""
    assert client.post("/v1/trips", json=golden_trip, headers=AUTH_HEADERS).status_code == 200
    assert client.post("/v1/trips", json=golden_trip, headers=AUTH_HEADERS).status_code == 200

    with psycopg.connect(db_url) as conn, conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM trips WHERE id = %s", (golden_trip["id"],))
        assert cur.fetchone()[0] == 1
