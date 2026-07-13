"""Real AuthPort over the Firebase Admin SDK, plus the FastAPI dependency.

Faked in unit tests. In production `verify_firebase_token` is wired to a FirebaseAuth instance.
"""

from __future__ import annotations

from fastapi import Header, HTTPException

from .ports import AuthPort


class FirebaseAuth(AuthPort):
    def __init__(self, project_id: str) -> None:
        # Lazy import so tests that fake AuthPort don't need firebase-admin installed.
        import firebase_admin  # type: ignore[import-untyped]
        from firebase_admin import credentials

        if not firebase_admin._apps:
            firebase_admin.initialize_app(credentials.ApplicationDefault(), {"projectId": project_id})

    def verify(self, bearer_token: str) -> str:
        from firebase_admin import auth as fb_auth  # type: ignore[import-untyped]

        try:
            decoded = fb_auth.verify_id_token(bearer_token)
        except Exception as exc:  # noqa: BLE001 — any verify failure is a 401
            raise HTTPException(status_code=401, detail="invalid token") from exc
        return decoded["uid"]


def bearer_from_header(authorization: str | None = Header(default=None)) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    return authorization.split(" ", 1)[1]
