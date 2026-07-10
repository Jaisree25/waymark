"""Real StoragePort over google-cloud-storage (V4 signed URLs).

Wired in production; faked in unit tests via the StoragePort protocol. The app returns a URL and
the client PUTs bytes directly — blobs never stream through Cloud Run.
"""

from __future__ import annotations

from datetime import timedelta

from google.cloud import storage  # type: ignore[import-untyped]

from .ports import StoragePort


class GcsStorage(StoragePort):
    def __init__(self, bucket_name: str, expiry_minutes: int = 15) -> None:
        self._client = storage.Client()
        self._bucket = self._client.bucket(bucket_name)
        self._expiry = timedelta(minutes=expiry_minutes)

    def signed_upload_url(self, object_path: str) -> str:
        blob = self._bucket.blob(object_path)
        return blob.generate_signed_url(
            version="v4",
            expiration=self._expiry,
            method="PUT",
        )
