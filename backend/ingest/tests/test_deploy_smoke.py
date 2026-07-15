"""Cycle 5 — post-deploy smoke tests against the REAL deployed Cloud Run URL.

These prove the container actually boots and serves: /healthz is public and app-level Firebase auth
rejects unauthenticated writes. They need a deployed service, not a database (the app answers
/healthz without touching the DB, and rejects unauthenticated events before any DB call).

Skips cleanly unless INGEST_URL points at the deployed service:

    export INGEST_URL=$(cd infra/envs/dev && terraform output -raw ingest_url)
    pytest -m smoke

infra/deploy.sh does this wiring for you after it deploys.
"""

from __future__ import annotations

import os

import httpx
import pytest

pytestmark = pytest.mark.smoke

_BASE = os.environ.get("INGEST_URL", "").rstrip("/")
_TIMEOUT = 30.0


@pytest.fixture(scope="module")
def base_url() -> str:
    if not _BASE:
        pytest.skip("set INGEST_URL to the deployed Cloud Run URL to run smoke tests")
    return _BASE


def test_deployed_healthz(base_url: str) -> None:
    """The public health endpoint answers 200 — the container is up and serving."""
    r = httpx.get(f"{base_url}/healthz", timeout=_TIMEOUT)
    assert r.status_code == 200, f"healthz not OK: {r.status_code} {r.text}"
    assert r.json() == {"status": "ok"}


def test_deployed_auth_required(base_url: str) -> None:
    """An unauthenticated event POST is rejected by app-level Firebase auth (never reaches the DB)."""
    r = httpx.post(f"{base_url}/v1/events", json={}, timeout=_TIMEOUT)
    assert r.status_code in (401, 403), f"expected auth rejection, got {r.status_code} {r.text}"
