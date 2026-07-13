# backend/ingest — FastAPI ingest API (Person C)

## Purpose

The service the mobile app talks to. It implements **Contract 2**
([`contracts/openapi.yaml`](../../contracts/openapi.yaml)): accept trips, events, and breadcrumbs,
hand back **signed GCS URLs** so the phone uploads audio/sensor blobs directly, and persist rows into
**Person A's** schema. Runs as a container on **Cloud Run**.

## Endpoints (Contract 2)

| Method + path | Body | Headers | Response |
|---|---|---|---|
| `POST /v1/trips` | `TripIn` | `Authorization: Bearer <firebase>` | `{ "ok": true }` (idempotent on `id`) |
| `POST /v1/events` | `EventIn` | `Authorization`, `Idempotency-Key` | `{ "audio_upload": <url>, "sensor_upload": <url> }` |
| `POST /v1/breadcrumbs` | `BreadcrumbIn` | `Authorization`, `Idempotency-Key` | `{ "ok": true }` |
| `GET /healthz` | — | — | `{ "status": "ok" }` |

## Architecture / intent

Handlers are thin: **validate → authenticate → persist → (events) mint signed URLs.** The risky
externals are injected as **ports** so units never touch the network.

```
app/
├── main.py        create_app(state) wires handlers; build_production_app() wires real ports from env
├── schemas.py     Pydantic v2 models = Contract 2 (rejects e.g. severity 6 → 422 before A's DB CHECK)
├── ports.py       StoragePort (GCS signed URLs), AuthPort (Firebase) — the fakeable seams
├── storage.py     GcsStorage: real StoragePort over google-cloud-storage (V4 signed PUT URLs)
├── auth.py        FirebaseAuth: real AuthPort over firebase-admin
├── repository.py  Repository protocol + SqlRepository (psycopg pool; writes A's schema, idempotent)
└── deps.py        AppState — the composition root tests override with fakes
```

Why this shape:
- **Blobs never proxy through the app** — it returns a signed URL and the client PUTs bytes to GCS.
- **Idempotency** — `/v1/events` and `/v1/breadcrumbs` require `Idempotency-Key`; duplicates are a
  no-op (relies on A's UNIQUE constraint, caught cleanly, `200` both times).
- **`features` bag carried verbatim** — M2/M3 add keys with no migration.

## Test steps

Two layers (from [person-c-backend-infra.md](../../docs/M1/Implementation/person-c-backend-infra.md) §1).

### 1. Fast unit/contract tests (GCS + Firebase faked, no network)

```bash
# from repo root
python -m venv backend/ingest/.venv
backend/ingest/.venv/Scripts/python -m pip install -r backend/ingest/requirements-dev.txt
backend/ingest/.venv/Scripts/python -m pytest        # runs backend/ingest/tests + mapmatch
```

`tests/test_events_endpoint.py` covers: `healthz`, signed-URL response shape, `severity 6 → 422`,
missing `Idempotency-Key → 400`, missing auth → `401`, and duplicate-key no-op. Fakes live in
`tests/conftest.py`; golden payloads in `tests/fixtures.py`.

### 2. Live smoke (optional)

`create_app(state)` takes an `AppState`, so it isn't a zero-arg uvicorn factory. For a no-creds smoke,
write a tiny dev entrypoint that wires the test fakes, then serve that:

```python
# dev_smoke.py (scratch, not committed)
import sys; sys.path.insert(0, "backend/ingest"); sys.path.insert(0, "backend/ingest/tests")
from app.deps import AppState
from app.main import create_app
from conftest import FakeStorage, FakeAuth, FakeRepo
app = create_app(AppState(storage=FakeStorage(), auth=FakeAuth(), repo=FakeRepo()))
```

```bash
backend/ingest/.venv/Scripts/python -m uvicorn dev_smoke:app --port 8000
curl localhost:8000/healthz        # → {"status":"ok"}
```

The real server uses `build_production_app` (the container entrypoint), which wires the live GCS,
Firebase, and DB ports from `GCS_BUCKET`, `FIREBASE_PROJECT_ID`, and `DATABASE_URL`.

### 3. Persistence integration (real local PostGIS)

```bash
docker run -d --name fsd-pg-test -p 5433:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd_test postgis/postgis:16-3.4
pytest backend/ingest/tests/test_persistence_integration.py    # skips cleanly if no DB
```

`test_persistence_integration.py` loads the schema, wires the real `SqlRepository`, and asserts
one-row persistence, idempotent retries, `user_id` = authenticated uid, breadcrumb geography, and a
409 on event-before-trip. **Do not fake PostGIS** — it's the seam most likely to break.

> Schema source: until Person A ships `db/schema.sql`, the tests load `tests/contract_schema.sql`, a
> verbatim mirror of the frozen Contract-1 DDL. Repoint the fixture at `db/schema.sql` and delete the
> mirror once it exists. Use `127.0.0.1` (not `localhost`) in the DB URL on Windows to avoid a ~5s
> IPv6 connect stall.

## Build & deploy

```bash
IMG=$REGION-docker.pkg.dev/$PROJECT/fsd/ingest:m1
docker build -t $IMG backend/ingest && docker push $IMG
gcloud run deploy fsd-ingest --image $IMG --region $REGION \
  --add-cloudsql-instances $PROJECT:$REGION:fsd-pg \
  --set-env-vars "DATABASE_URL=...,GCS_BUCKET=...,FIREBASE_PROJECT_ID=$PROJECT"
```

The container runs `uvicorn app.main:build_production_app --factory` (see [Dockerfile](./Dockerfile)).
Infra for this service is Terraform — see [infra/README.md](../../infra/README.md).
