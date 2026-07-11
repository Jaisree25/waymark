"""FastAPI ingest service (Contract 2). Cloud Run entrypoint.

Handlers are thin: validate (Pydantic) → authenticate (AuthPort) → persist (Repository) →
for events, mint signed URLs (StoragePort). External systems are injected via AppState so unit
tests fake GCS + Firebase and never touch the network.
"""

from __future__ import annotations

import os

import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse

from .auth import bearer_from_header
from .deps import AppState
from .schemas import (
    BreadcrumbIn,
    EventIn,
    EventUploadResponse,
    OkResponse,
    TripIn,
)


def _state(request: Request) -> AppState:
    return request.app.state.deps


def _uid(request: Request, token: str = Depends(bearer_from_header)) -> str:
    return _state(request).auth.verify(token)


def require_idempotency_key(idempotency_key: str | None = Header(default=None, alias="Idempotency-Key")) -> str:
    if not idempotency_key:
        raise HTTPException(status_code=400, detail="Idempotency-Key header required")
    return idempotency_key


def create_app(state: AppState) -> FastAPI:
    app = FastAPI(title="fsd-ingest", version="m1")
    app.state.deps = state

    @app.exception_handler(psycopg.errors.IntegrityError)
    async def _integrity_conflict(request: Request, exc: psycopg.errors.IntegrityError) -> JSONResponse:
        # FK miss (e.g. event before its trip) or an unexpected unique clash → a clean 409, not a 500.
        # The idempotency happy path never reaches here (ON CONFLICT DO NOTHING swallows it).
        return JSONResponse(status_code=409, content={"detail": "integrity conflict"})

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/trips", response_model=OkResponse)
    async def create_trip(trip: TripIn, request: Request, uid: str = Depends(_uid)) -> OkResponse:
        _state(request).repo.upsert_trip(trip, uid)  # idempotent on trip.id
        return OkResponse()

    @app.post("/v1/events", response_model=EventUploadResponse)
    async def create_event(
        event: EventIn,
        request: Request,
        uid: str = Depends(_uid),
        idempotency_key: str = Depends(require_idempotency_key),
    ) -> EventUploadResponse:
        st = _state(request)
        st.repo.upsert_event(event, idempotency_key)  # dedupe on idempotency_key
        return EventUploadResponse(
            audio_upload=st.storage.signed_upload_url(f"events/{event.id}/audio.wav"),
            sensor_upload=st.storage.signed_upload_url(f"events/{event.id}/sensors.json"),
        )

    @app.post("/v1/breadcrumbs", response_model=OkResponse)
    async def create_breadcrumb(
        breadcrumb: BreadcrumbIn,
        request: Request,
        uid: str = Depends(_uid),
        idempotency_key: str = Depends(require_idempotency_key),
    ) -> OkResponse:
        _state(request).repo.upsert_breadcrumb(breadcrumb, idempotency_key)
        return OkResponse()

    return app


def build_production_app() -> FastAPI:
    """Wires the real ports from env. Imported by uvicorn in the container."""
    from .auth import FirebaseAuth
    from .repository import SqlRepository
    from .storage import GcsStorage

    state = AppState(
        storage=GcsStorage(bucket_name=os.environ["GCS_BUCKET"]),
        auth=FirebaseAuth(project_id=os.environ["FIREBASE_PROJECT_ID"]),
        repo=SqlRepository(database_url=os.environ["DATABASE_URL"]),
    )
    return create_app(state)
