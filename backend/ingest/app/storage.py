"""Real StoragePort over google-cloud-storage (V4 signed URLs).

Wired in production; faked in unit tests via the StoragePort protocol. The app returns a URL and
the client PUTs bytes directly — blobs never stream through Cloud Run.

Signing is KEYLESS: no private-key file is ever downloaded. Three cases, auto-detected:

  * On Cloud Run — ambient credentials ARE the ingest SA (a compute identity with a
    service-account email but no local key). We sign via the IAM SignBlob API.
  * Locally with user ADC (`gcloud auth application-default login`) — user credentials have no
    SA identity, so set INGEST_SIGNER_SA (or pass signer_sa=) to the ingest SA email and we
    IMPERSONATE it to sign. You need roles/iam.serviceAccountTokenCreator on that SA.
  * With GOOGLE_APPLICATION_CREDENTIALS pointing at a real SA key file — that key signs locally
    and no IAM call is made.
"""

from __future__ import annotations

import os
from datetime import timedelta

import google.auth
from google.auth import impersonated_credentials
from google.auth.transport import requests as ga_requests
from google.cloud import storage  # type: ignore[import-untyped]
from google.oauth2 import service_account

from .ports import StoragePort

_CLOUD_PLATFORM = "https://www.googleapis.com/auth/cloud-platform"


class GcsStorage(StoragePort):
    def __init__(self, bucket_name: str, expiry_minutes: int = 15, signer_sa: str | None = None) -> None:
        self._client = storage.Client()
        self._bucket = self._client.bucket(bucket_name)
        self._expiry = timedelta(minutes=expiry_minutes)

        signer_sa = signer_sa or os.environ.get("INGEST_SIGNER_SA")
        creds, _ = google.auth.default(scopes=[_CLOUD_PLATFORM])
        if signer_sa and not isinstance(creds, service_account.Credentials):
            # User ADC can't sign; impersonate the ingest SA so signing stays keyless.
            creds = impersonated_credentials.Credentials(
                source_credentials=creds,
                target_principal=signer_sa,
                target_scopes=[_CLOUD_PLATFORM],
            )
        self._credentials = creds

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
        email = getattr(self._credentials, "signer_email", None) or getattr(
            self._credentials, "service_account_email", None
        )
        if not email or email == "default":
            raise RuntimeError(
                "cannot sign V4 URL: no service-account identity to sign as. Run on Cloud Run, "
                "set INGEST_SIGNER_SA to impersonate the ingest SA, or set "
                "GOOGLE_APPLICATION_CREDENTIALS to a key file."
            )
        return {"service_account_email": email, "access_token": self._credentials.token}
