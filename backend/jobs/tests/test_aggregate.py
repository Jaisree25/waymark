"""Person A · Cycle 4 — the nightly aggregation, on real PostGIS. This IS feasibility risk #5.

"Is the score sane?" must be answered by a passing, hand-checkable test rather than a vibe — so the
core fixture uses numbers you can verify in your head: severities 3 and 5 over 4 miles → 8/4 = 2.0.

The edge cases matter as much as the happy path: a way with no exposure, a way with no events, an
unrated event. Each has an explicitly chosen answer asserted here, because the failure mode of a
risk score is looking confident about data it doesn't have.
"""

from __future__ import annotations

import pytest

from aggregate import DEFAULT_CONFIG_PATH, aggregate, load_config

from .conftest import fetch_score, seed_event, seed_exposure, seed_trip

GATE = 5.0  # miles; matches the shipped config default


# --- the headline math ---


def test_severity_per_mile_basic(db) -> None:
    """2 events (severity 3 + 5) on way 100 with 4 exposure miles → 8 / 4 = 2.0. Hand-checkable."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=4.0)
    seed_event(db, trip, way_id=100, severity=3)
    seed_event(db, trip, way_id=100, severity=5)

    aggregate(db, gate_miles=GATE)

    score = fetch_score(db, 100)
    assert score["total_severity"] == 8
    assert score["total_miles"] == 4.0
    assert score["severity_per_mile"] == 2.0
    assert score["incident_count"] == 2


def test_exposure_sums_across_trips(db) -> None:
    """Miles on the same way from different trips accumulate into one denominator."""
    trip_a, trip_b = seed_trip(db), seed_trip(db)
    seed_exposure(db, trip_a, way_id=100, miles=3.0)
    seed_exposure(db, trip_b, way_id=100, miles=5.0)
    seed_event(db, trip_a, way_id=100, severity=4)

    aggregate(db, gate_miles=GATE)

    score = fetch_score(db, 100)
    assert score["total_miles"] == 8.0
    assert score["severity_per_mile"] == 0.5  # 4 / 8


# --- the gate ---


def test_gate_below_threshold(db) -> None:
    """A way with less exposure than the gate is marked gated — too thin to rank honestly."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=4.9)  # just under
    seed_event(db, trip, way_id=100, severity=5)

    aggregate(db, gate_miles=GATE)

    assert fetch_score(db, 100)["gated"] is True


def test_gate_at_threshold_is_not_gated(db) -> None:
    """The gate is a strict `<`: exactly the threshold counts as enough data."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=5.0)
    seed_event(db, trip, way_id=100, severity=5)

    aggregate(db, gate_miles=GATE)

    assert fetch_score(db, 100)["gated"] is False


def test_gate_comes_from_config_not_code(db) -> None:
    """Retuning the gate is a config edit — the same data gates differently under a bigger gate."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=6.0)
    seed_event(db, trip, way_id=100, severity=5)

    aggregate(db, gate_miles=5.0)
    assert fetch_score(db, 100)["gated"] is False

    aggregate(db, gate_miles=10.0)  # a stricter tuning, no code change
    assert fetch_score(db, 100)["gated"] is True


def test_shipped_config_matches_the_documented_gate(db) -> None:
    """The committed config is the documented 5.0-mile gate (docs/M1/02-flutter-app.md)."""
    config = load_config(DEFAULT_CONFIG_PATH)
    assert config["scoring"]["min_mileage_gate_miles"] == 5.0
    assert config["calibration_version"] == "m1"


# --- the edge cases: what does a weird way score? ---


def test_exposure_without_events_scores_zero(db) -> None:
    """Driven but incident-free → 0.0, a real measurement. Distinct from 'no data' (NULL below)."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=10.0)

    aggregate(db, gate_miles=GATE)

    score = fetch_score(db, 100)
    assert score["severity_per_mile"] == 0.0
    assert score["incident_count"] == 0
    assert score["gated"] is False  # plenty of miles — we genuinely know this road looks clean


def test_events_without_exposure_are_undefined_not_infinite(db) -> None:
    """Events but 0 miles → severity_per_mile is NULL, never a divide-by-zero or a fake number."""
    trip = seed_trip(db)
    seed_event(db, trip, way_id=100, severity=5)  # matched, but no breadcrumb exposure

    aggregate(db, gate_miles=GATE)

    score = fetch_score(db, 100)
    assert score["severity_per_mile"] is None  # "unknown", not 0 and not infinity
    assert score["total_miles"] == 0
    assert score["incident_count"] == 1
    assert score["gated"] is True  # 0 miles is the thinnest possible data


def test_unmatched_events_are_excluded(db) -> None:
    """An event with no way_id can't be attributed, so it must not score any road."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=10.0)
    seed_event(db, trip, way_id=None, severity=5)  # never map-matched

    aggregate(db, gate_miles=GATE)

    score = fetch_score(db, 100)
    assert score["total_severity"] == 0  # the orphan severity landed nowhere
    assert score["incident_count"] == 0


def test_unrated_event_counts_as_incident_but_adds_no_severity(db) -> None:
    """severity NULL = captured, not yet rated. It's a real incident, but contributes no severity."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=10.0)
    seed_event(db, trip, way_id=100, severity=None)
    seed_event(db, trip, way_id=100, severity=4)

    aggregate(db, gate_miles=GATE)

    score = fetch_score(db, 100)
    assert score["incident_count"] == 2   # both happened…
    assert score["total_severity"] == 4   # …but only the rated one is scored
    assert score["severity_per_mile"] == 0.4


def test_no_data_writes_no_rows(db) -> None:
    """An empty database scores nothing — no phantom rows for roads nobody drove."""
    assert aggregate(db, gate_miles=GATE) == 0
    assert fetch_score(db, 100) is None


# --- snapshot semantics ---


def test_scores_are_reproducible(db) -> None:
    """Running twice on identical data yields an identical number — the job is deterministic."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=4.0)
    seed_event(db, trip, way_id=100, severity=3)

    aggregate(db, gate_miles=GATE)
    first = fetch_score(db, 100)["severity_per_mile"]
    aggregate(db, gate_miles=GATE)
    second = fetch_score(db, 100)["severity_per_mile"]

    assert first == second == 0.75


def test_each_run_appends_a_snapshot(db) -> None:
    """Runs append rather than overwrite: scores are an audit trail stamped with as_of."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=4.0)
    seed_event(db, trip, way_id=100, severity=3)

    aggregate(db, gate_miles=GATE)
    aggregate(db, gate_miles=GATE)

    with db.cursor() as cur:
        cur.execute("SELECT count(DISTINCT as_of) FROM scores WHERE way_id = 100")
        assert cur.fetchone()[0] == 2


def test_snapshot_is_stamped_with_calibration_version(db) -> None:
    """Every row records which tuning produced it, so old scores stay interpretable."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=4.0)
    seed_event(db, trip, way_id=100, severity=3)

    aggregate(db, gate_miles=GATE, calibration_version="m1")

    assert fetch_score(db, 100)["calibration_version"] == "m1"


def test_one_snapshot_shares_a_single_as_of(db) -> None:
    """All ways in a run carry the same as_of, so a snapshot can't tear across roads."""
    trip = seed_trip(db)
    for way_id in (100, 101, 102):
        seed_exposure(db, trip, way_id=way_id, miles=6.0)
        seed_event(db, trip, way_id=way_id, severity=3)

    aggregate(db, gate_miles=GATE)

    with db.cursor() as cur:
        cur.execute("SELECT count(DISTINCT as_of) FROM scores")
        assert cur.fetchone()[0] == 1


def test_rowcount_matches_ways_scored(db) -> None:
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=6.0)
    seed_exposure(db, trip, way_id=101, miles=6.0)
    seed_event(db, trip, way_id=102, severity=3)  # events-only way still gets a (gated) row

    assert aggregate(db, gate_miles=GATE) == 3


@pytest.mark.parametrize("severity,miles,expected", [
    (5, 1.0, 5.0),
    (1, 4.0, 0.25),
    (3, 3.0, 1.0),
])
def test_severity_per_mile_is_plain_division(db, severity: int, miles: float, expected: float) -> None:
    """No smoothing, no priors, no ML — M1 is deliberately Σseverity ÷ Σmiles."""
    trip = seed_trip(db)
    seed_exposure(db, trip, way_id=100, miles=miles)
    seed_event(db, trip, way_id=100, severity=severity)

    aggregate(db, gate_miles=GATE)

    assert fetch_score(db, 100)["severity_per_mile"] == pytest.approx(expected)
