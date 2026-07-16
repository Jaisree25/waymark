"""Person A · Cycle 5 — the export queries, against a real PostGIS.

These assert the shape C's endpoints wrap. The events assertions are the risk #2 contract: every
event must expose raw AND snapped so the inspector can draw the error line between them.
"""

from __future__ import annotations

import pytest

from exports import CSV_DATASETS, SqlExports

from .conftest import seed_event, seed_road_segment, seed_score, seed_trip


@pytest.fixture
def exports(db, db_url) -> SqlExports:
    return SqlExports(db_url)


# --- segments ---


def test_segments_geojson_query(db, db_url, exports: SqlExports) -> None:
    """road_segments joined to their latest scores, with the properties the UI colors by."""
    seed_road_segment(db, way_id=100)
    seed_score(db, way_id=100, severity_per_mile=0.12, gated=False)
    db.commit()

    rows = exports.segment_rows()
    assert len(rows) == 1
    row = rows[0]
    assert row["way_id"] == 100
    assert row["geometry"]["type"] == "LineString"  # GeoJSON dict, ready for C to lift into a Feature
    assert row["severity_per_mile"] == 0.12
    assert row["incident_count"] == 2
    assert row["gated"] is False


def test_segments_latest_score_wins(db, db_url, exports: SqlExports) -> None:
    """A way accumulates score snapshots over time; the export shows only the newest."""
    seed_road_segment(db, way_id=100)
    with db.cursor() as cur:
        cur.execute(
            "INSERT INTO scores (way_id, severity_per_mile, gated, as_of) "
            "VALUES (100, 0.99, false, '2026-07-01T03:00:00Z')"  # stale
        )
        cur.execute(
            "INSERT INTO scores (way_id, severity_per_mile, gated, as_of) "
            "VALUES (100, 0.12, false, '2026-07-14T03:00:00Z')"  # newest
        )
    db.commit()

    assert exports.segment_rows()[0]["severity_per_mile"] == 0.12


def test_segment_without_score_is_gated(db, db_url, exports: SqlExports) -> None:
    """An unscored road returns gated=true → the UI grays it. 'No data' must not read as 'no risk'."""
    seed_road_segment(db, way_id=200)
    db.commit()

    row = exports.segment_rows()[0]
    assert row["severity_per_mile"] is None
    assert row["gated"] is True


# --- events (risk #2) ---


def test_events_geojson_query(db, db_url, exports: SqlExports) -> None:
    """Both raw and snapped come back, and they differ — that delta is the map-match error."""
    trip = seed_trip(db)
    seed_event(db, trip, severity=3)
    db.commit()

    row = exports.event_rows()[0]
    assert row["geometry"]["type"] == "Point"
    assert row["geometry"]["coordinates"] == [-122.4190, 37.7795]  # snapped
    assert (row["raw_lon"], row["raw_lat"]) == (-122.4193, 37.7793)  # raw
    assert row["geometry"]["coordinates"] != [row["raw_lon"], row["raw_lat"]]
    assert row["severity"] == 3
    assert row["way_id"] == 100
    assert row["raw_accuracy_m"] == 6.5
    assert row["trigger_source"] == "voice"


def test_event_not_yet_matched_has_null_geometry(db, db_url, exports: SqlExports) -> None:
    """An unattributed event still exports (with raw only) — it isn't silently dropped."""
    trip = seed_trip(db)
    seed_event(db, trip, way_id=None, snapped_lat=None, snapped_lon=None)
    db.commit()

    row = exports.event_rows()[0]
    assert row["geometry"] is None
    assert row["raw_lat"] == 37.7793  # raw survives, so the gap is visible rather than invisible


# --- CSV ---


def test_csv_exports_have_agreed_columns(db, db_url, exports: SqlExports) -> None:
    trip = seed_trip(db)
    seed_event(db, trip)
    seed_road_segment(db)
    seed_score(db)
    with db.cursor() as cur:
        cur.execute("INSERT INTO segment_exposure (way_id, trip_id, miles) VALUES (100, %s, 1.2)", (trip,))
    db.commit()

    events = exports.csv_rows("events")[0]
    assert events["severity"] == 3
    assert events["snapped_lat"] == pytest.approx(37.7795)  # flattened out of geom for the CSV
    assert events["snapped_lon"] == pytest.approx(-122.4190)
    assert events["raw_lat"] == 37.7793

    assert exports.csv_rows("trips")[0]["provider"] == "tesla"
    assert exports.csv_rows("segment_exposure")[0]["miles"] == 1.2
    assert exports.csv_rows("scores")[0]["severity_per_mile"] == 0.12


@pytest.mark.parametrize("dataset", CSV_DATASETS)
def test_every_csv_dataset_queryable(db, db_url, exports: SqlExports, dataset: str) -> None:
    """All four datasets the feasibility report consumes run cleanly, even when empty."""
    assert exports.csv_rows(dataset) == []


def test_csv_rejects_unknown_dataset(db, db_url, exports: SqlExports) -> None:
    with pytest.raises(ValueError):
        exports.csv_rows("passwords")
