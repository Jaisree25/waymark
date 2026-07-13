"""Real StoragePort over google-cloud-storage (V4 signed URLs).

Wired in production; faked in unit tests via the StoragePort protocol. The app returns a URL and
the client PUTs bytes directly — blobs never stream through Cloud Run.

Signing is KEYLESS by default: on Cloud Run (and via local impersonation) the runtime SA has no
private key file, so we sign through the IAM SignBlob API — the SA needs
`roles/iam.serviceAccountTokenCreator` on itself (granted in infra/). If instead you point
GOOGLE_APPLICATION_CREDENTIALS at a service-account key file, that key signs locally and no IAM call
is made.
"""

from __future__ import annotations

from datetime import timedelta

import google.auth
from google.auth.transport import requests as ga_requests
from google.cloud import storage  # type: ignore[import-untyped]
from google.oauth2 import service_account

from .ports import StoragePort


class GcsStorage(StoragePort):
    def __init__(self, bucket_name: str, expiry_minutes: int = 15) -> None:
        self._client = storage.Client()
        self._bucket = self._client.bucket(bucket_name)
        self._expiry = timedelta(minutes=expiry_minutes)
        # Ambient credentials (SA key file, Cloud Run compute SA, or an impersonated SA).
        self._credentials, _ = google.auth.default()

    def signed_upload_url(self, object_path: str) -> str:
        blob = self._bucket.blob(object_path)
        return blob.generate_signed_url(
            version="v4",
            expiration=self._expiry,
            method="PUT",
            **self._signer_kwargs(),
        )

    def _signer_kwargs(self) -> dict[str, str]:
        """Sign locally with a key file if we have one; otherwise sign via IAM SignBlob (keyless)."""
        if isinstance(self._credentials, service_account.Credentials):
            return {}  # key file present — generate_signed_url signs locally, no network call
        # Keyless: a fresh access token + the SA email route signing through the IAM SignBlob API.
        self._credentials.refresh(ga_requests.Request())
        email = getattr(self._credentials, "service_account_email", None) or getattr(
            self._credentials, "signer_email", None
        )
        if not email or email == "default":
            raise RuntimeError(
                "cannot sign V4 URL: keyless credentials expose no service-account email; "
                "run on Cloud Run, impersonate the ingest SA, or set GOOGLE_APPLICATION_CREDENTIALS"
            )
        return {"service_account_email": email, "access_token": self._credentials.token}
