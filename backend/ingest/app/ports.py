"""Ports (interfaces) for the risky external systems.

GCS and Firebase live behind these so unit tests fake them and never hit the network.
PostGIS and Valhalla are deliberately NOT faked (they are the seams most likely to break) —
those get real local instances in integration tests.
"""

from __future__ import annotations

from typing import Protocol


class StoragePort(Protocol):
    """Mints V4 signed PUT URLs so the phone uploads blobs directly to GCS."""

    def signed_upload_url(self, object_path: str) -> str: ...


class AuthPort(Protocol):
    """Validates a Firebase bearer ID token, returning the uid."""

    def verify(self, bearer_token: str) -> str: ...
