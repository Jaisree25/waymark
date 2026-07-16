"""FastAPI ingest service (Contract 2). Cloud Run entrypoint.

Handlers are thin: validate (Pydantic) → authenticate (AuthPort) → persist (Repository) →
for events, mint signed URLs (StoragePort). External systems are injected via AppState so unit
tests fake GCS + Firebase and never touch the network.
"""

from __future__ import annotations

import csv
import io
import os
from collections.abc import Iterator

import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

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


# The datasets 05-feasibility-testing.md consumes. An allowlist, so the path param can never be
# steered at something A's exports didn't mean to publish.
CSV_DATASETS = ("events", "trips", "segment_exposure", "scores")


def _exports(request: Request):
    """A's export queries, or a clean 503 on deploys that don't wire them (ingest-only)."""
    exports = _state(request).exports
    if exports is None:
        raise HTTPException(status_code=503, detail="export queries not configured")
    return exports


def _feature_collection(rows: list[dict]) -> dict:
    """Rows → GeoJSON. `geometry` is lifted into the Feature; every other key is a property."""
    features = []
    for row in rows:
        properties = dict(row)
        geometry = properties.pop("geometry", None)
        features.append({"type": "Feature", "geometry": geometry, "properties": properties})
    return {"type": "FeatureCollection", "features": features}


def _csv_stream(rows: list[dict]) -> Iterator[str]:
    """Stream rows as CSV so a large export never buffers the whole table in memory."""
    if not rows:
        return
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=list(rows[0].keys()))

    def flush() -> str:
        chunk = buf.getvalue()
        buf.seek(0)
        buf.truncate(0)
        return chunk

    writer.writeheader()
    yield flush()
    for row in rows:
        writer.writerow(row)
        yield flush()


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

    # --- read-only inspection + export (04-inspection-ui.md). C wraps A's queries; A owns the SQL.
    # Unauthenticated by design: M1's inspector is an internal data-quality tool, not a product.

    @app.get("/v1/inspect/segments.geojson")
    async def segments_geojson(request: Request) -> dict:
        # road_segments ⨝ latest scores; the UI colors by severity_per_mile, grays out `gated`.
        return _feature_collection(_exports(request).segment_rows())

    @app.get("/v1/inspect/events.geojson")
    async def events_geojson(request: Request) -> dict:
        # Snapped point as geometry + raw_lat/raw_lon as properties: the inspector draws the
        # raw→snapped line between them, and that line IS the risk #2 attribution check.
        return _feature_collection(_exports(request).event_rows())

    @app.get("/v1/export/{dataset}.csv")
    async def export_csv(dataset: str, request: Request) -> StreamingResponse:
        if dataset not in CSV_DATASETS:
            raise HTTPException(status_code=404, detail=f"unknown dataset: {dataset}")
        rows = _exports(request).csv_rows(dataset)
        return StreamingResponse(
            _csv_stream(rows),
            media_type="text/csv",
            headers={"Content-Disposition": f'attachment; filename="{dataset}.csv"'},
        )

    return app


def _load_exports(database_url: str):
    """Person A's export queries — shipped beside the app by the Dockerfile (db/exports.py).

    Optional by design: A owns this module and it lives outside C's package, so running the ingest
    API from a checkout without db/ on sys.path is a normal dev case. The inspect/export routes
    already answer a clean 503 when it's absent, which is also the right behaviour for an
    ingest-only deploy.
    """
    try:
        from exports import SqlExports  # noqa: PLC0415 — A's module, not part of C's package
    except ImportError:
        return None
    return SqlExports(database_url)


def build_production_app() -> FastAPI:
    """Wires the real ports from env. Imported by uvicorn in the container."""
    from .auth import FirebaseAuth
    from .repository import SqlRepository
    from .storage import GcsStorage

    database_url = os.environ["DATABASE_URL"]
    state = AppState(
        storage=GcsStorage(bucket_name=os.environ["GCS_BUCKET"]),
        auth=FirebaseAuth(project_id=os.environ["FIREBASE_PROJECT_ID"]),
        repo=SqlRepository(database_url=database_url),
        exports=_load_exports(database_url),
    )
    return create_app(state)
