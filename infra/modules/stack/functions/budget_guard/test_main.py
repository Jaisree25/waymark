"""Tests for the budget guard.

This function is the thing standing between a forgotten `terraform apply` and a month of billing, so
its logic is worth pinning. Two failure modes matter and they pull in opposite directions:

  * never fires  → the guard is decoration and the bill arrives anyway
  * always fires → budgets notify several times a day, so an over-eager guard stops the stack
                   permanently the moment it's switched on

Both are covered below. The GCP calls themselves are faked — what's under test is when we decide to
stop, not googleapiclient.

    cd infra/modules/stack/functions/budget_guard && pytest
"""

from __future__ import annotations

import base64
import importlib
import json
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

BASE_ENV = {
    "PROJECT_ID": "fsd-benchmark-dev",
    "SQL_INSTANCE": "fsd-pg",
    "VM_NAME": "fsd-valhalla",
    "VM_ZONE": "us-west1-a",
    "SHUTOFF_THRESHOLD": "1.0",
}


def _load(**overrides):
    """(Re)import the module with a given env — it reads config at import time, like the runtime does."""
    os.environ.update({**BASE_ENV, **overrides})
    import main

    return importlib.reload(main)


def _event(cost: float, budget: float):
    """A Cloud Billing budget notification, shaped as Pub/Sub delivers it."""
    payload = json.dumps({"costAmount": cost, "budgetAmount": budget}).encode()

    class _CloudEvent:
        data = {"message": {"data": base64.b64encode(payload).decode()}}

    return _CloudEvent()


@pytest.fixture
def stops(monkeypatch):
    """Record stop attempts instead of calling GCP."""
    main = _load()
    called: list[str] = []
    monkeypatch.setattr(main, "_stop_sql", lambda: called.append("sql"))
    monkeypatch.setattr(main, "_stop_vm", lambda: called.append("vm"))
    return main, called


# --- the no-op path (the common case) ---


@pytest.mark.parametrize("cost", [0, 1, 25, 49.99])
def test_under_threshold_does_nothing(stops, cost) -> None:
    """Most notifications are routine spend updates. Acting on them would stop the stack on day one."""
    main, called = stops
    main.handle(_event(cost=cost, budget=50))
    assert called == []


def test_zero_budget_is_ignored(stops) -> None:
    """A malformed/zero budget must not divide by zero or be read as '100% spent'."""
    main, called = stops
    main.handle(_event(cost=10, budget=0))
    assert called == []


# --- the firing path ---


def test_at_threshold_stops_both(stops) -> None:
    """At budget, stop the two things that bill 24/7."""
    main, called = stops
    main.handle(_event(cost=50, budget=50))
    assert sorted(called) == ["sql", "vm"]


def test_over_threshold_stops(stops) -> None:
    main, called = stops
    main.handle(_event(cost=73.20, budget=50))
    assert sorted(called) == ["sql", "vm"]


def test_threshold_is_configurable(monkeypatch) -> None:
    """A 90% threshold acts before the budget is blown, not after."""
    main = _load(SHUTOFF_THRESHOLD="0.9")
    called: list[str] = []
    monkeypatch.setattr(main, "_stop_sql", lambda: called.append("sql"))
    monkeypatch.setattr(main, "_stop_vm", lambda: called.append("vm"))

    main.handle(_event(cost=44, budget=50))  # 88%
    assert called == []

    main.handle(_event(cost=45, budget=50))  # 90%
    assert sorted(called) == ["sql", "vm"]


# --- resilience: stopping the meter beats a clean traceback ---


def test_one_failure_does_not_block_the_other(monkeypatch) -> None:
    """If the VM stop explodes, the database must still be stopped. Half a shutdown beats none."""
    main = _load()
    called: list[str] = []

    def _boom():
        raise RuntimeError("compute API is having a day")

    monkeypatch.setattr(main, "_stop_sql", _boom)
    monkeypatch.setattr(main, "_stop_vm", lambda: called.append("vm"))

    main.handle(_event(cost=50, budget=50))  # must not raise

    assert called == ["vm"]


def test_skips_resources_that_are_not_deployed(monkeypatch) -> None:
    """With Valhalla disabled there's no VM to stop — don't call compute with an empty name."""
    main = _load(VM_NAME="", VM_ZONE="")
    called: list[str] = []
    monkeypatch.setattr(main, "_stop_sql", lambda: called.append("sql"))
    monkeypatch.setattr(main, "_stop_vm", lambda: called.append("vm"))

    main.handle(_event(cost=50, budget=50))

    assert called == ["sql"]
