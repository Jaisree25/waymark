"""Cycle 3 — signed URLs to REAL GCS (thin integration; do not fake the bucket).

Proves the app's minted V4 signed PUT URL really lands bytes in the bucket, and that the client PUTs
directly (bytes never proxy through the app). Skips cleanly when no bucket/credentials are available:

    export TEST_GCS_BUCKET=fsd-dev-uploads      # a real dev bucket you can write to
    gcloud auth application-default login        # or GOOGLE_APPLICATION_CREDENTIALS=<sa-key.json>
    pytest -m integration

The signed URL is generated with a service-account key (V4 signing needs a private key; ADC alone
can't sign). Set GOOGLE_APPLICATION_CREDENTIALS to that key for this test.
"""

from __future__ import annotations

import os
import uuid

import httpx
import pytest

pytestmark = pytest.mark.integration

TEST_BUCKET = os.environ.get("TEST_GCS_BUCKET")


def _gcs_ready() -> str | None:
    """Return a skip reason, or None when a real bucket is reachable and writable."""
    if not TEST_BUCKET:
        return "set TEST_GCS_BUCKET to a real dev bucket to run the signed-URL roundtrip"
    try:
        from google.cloud import storage  # type: ignore[import-untyped]

        storage.Client().bucket(TEST_BUCKET).exists()  # forces auth + a real API call
        return None
    except Exception as exc:  # noqa: BLE001 — any auth/network failure means "skip", not "fail"
        return f"GCS not reachable ({TEST_BUCKET}): {exc}"


@pytest.fixture(scope="module")
def bucket() -> str:
    reason = _gcs_ready()
    if reason:
        pytest.skip(reason)
    return TEST_BUCKET  # type: ignore[return-value]


def test_signed_url_roundtrip(bucket: str) -> None:
    """App mints a signed PUT URL → client PUTs bytes over plain HTTP → bytes land in the bucket."""
    from google.cloud import storage  # type: ignore[import-untyped]

    from app.storage import GcsStorage

    object_path = f"events/{uuid.uuid4()}/audio.wav"
    payload = b"RIFF....fake-wav-bytes...."

    storage_port = GcsStorage(bucket_name=bucket)
    url = storage_port.signed_upload_url(object_path)

    # The URL must be a direct GCS URL, not something proxied through our app host.
    assert url.startswith("https://storage.googleapis.com/")

    # PUT with a bare HTTP client carrying NO GCS credentials — the signature alone must authorize it.
    put = httpx.put(url, content=payload, headers={"Content-Type": "application/octet-stream"})
    assert put.status_code == 200, f"signed PUT failed: {put.status_code} {put.text}"

    blob = storage.Client().bucket(bucket).blob(object_path)
    try:
        assert blob.download_as_bytes() == payload  # the bytes really landed
    finally:
        blob.delete()  # keep the dev bucket clean between runs


def test_signed_url_rejects_wrong_method(bucket: str) -> None:
    """A URL signed for PUT must not authorize a GET — the method is bound into the signature."""
    from app.storage import GcsStorage

    url = GcsStorage(bucket_name=bucket).signed_upload_url(f"events/{uuid.uuid4()}/sensors.json")
    resp = httpx.get(url)
    assert resp.status_code in (400, 403), f"expected signature/method rejection, got {resp.status_code}"
