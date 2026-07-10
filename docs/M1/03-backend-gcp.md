# M1 · 03 — Backend on Google Cloud

The M1 backend has four jobs: **accept uploads**, **store raw artifacts**, **map-match GPS to OSM
way IDs**, and run a **nightly aggregation** of `severity ÷ miles` per segment with a min-mileage
gate. Everything runs on GCP using open-source frameworks (FastAPI, PostgreSQL/PostGIS,
Valhalla), provisioned with Terraform.

```
Flutter ──HTTPS──► Cloud Run: FastAPI ingest ──► Cloud SQL (Postgres+PostGIS)
                       │                              ▲
                       ├── signed URL ──► GCS (audio/sensor blobs)
                       └── map-match ──► Cloud Run/GCE: Valhalla (OSM, SF tiles)
                                                       │
Cloud Scheduler ──nightly──► Cloud Run Job: aggregation ──► writes Score rows
```

---

## 1. Data model (core + attributes bag) — SQL

This is the *minimal* M1 schema, written so M2/M3 add columns/keys, never destructive migrations.
Run via Alembic (`backend/ingest/migrations`) or sqitch.

```sql
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE trips (
  id                 uuid PRIMARY KEY,
  user_id            text NOT NULL,            -- Firebase uid
  provider           text NOT NULL,            -- 'tesla' (M1)
  fsd_version        text,
  supervision        boolean NOT NULL,
  vehicle            text,
  device_info        jsonb NOT NULL DEFAULT '{}',
  app_config_version text NOT NULL,
  started_at         timestamptz NOT NULL,
  ended_at           timestamptz,
  metrics            jsonb NOT NULL DEFAULT '{}',  -- §02 trip_metrics (battery/thermal/upload)
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE events (
  id             uuid PRIMARY KEY,
  trip_id        uuid NOT NULL REFERENCES trips(id),
  t_trigger      timestamptz NOT NULL,
  t_pre_seconds  real NOT NULL,
  t_post_seconds real NOT NULL,
  trigger_source text NOT NULL,                 -- voice | tap | imu
  event_type     text NOT NULL DEFAULT 'incident',
  severity       int,                            -- 1..5 (voice), M1
  features       jsonb NOT NULL DEFAULT '{}',    -- the attributes bag (empty-ish in M1)
  geom           geography(Point,4326),          -- snapped point after map-match
  raw_lat        double precision,               -- pre-match, for QA
  raw_lon        double precision,
  raw_accuracy_m double precision,
  way_id         bigint,                         -- OSM way after map-match (NULL until matched)
  audio_uri      text,                           -- gs://… (NULL until uploaded)
  sensor_uri     text,
  idempotency_key text UNIQUE,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE breadcrumb_segments (
  id              uuid PRIMARY KEY,
  trip_id         uuid NOT NULL REFERENCES trips(id),
  track           geography(LineString,4326),    -- raw polyline
  matched_track   geography(LineString,4326),    -- after map-match
  motion_summary  jsonb NOT NULL DEFAULT '{}',
  idempotency_key text UNIQUE,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- exposure (miles) attributed to OSM ways, derived from matched breadcrumbs
CREATE TABLE segment_exposure (
  way_id     bigint NOT NULL,
  trip_id    uuid NOT NULL REFERENCES trips(id),
  miles      double precision NOT NULL,
  PRIMARY KEY (way_id, trip_id)
);

-- OSM ways we care about (loaded from the SF extract; geometry for rendering)
CREATE TABLE road_segments (
  way_id     bigint PRIMARY KEY,
  geom       geography(LineString,4326),
  length_mi  double precision,
  road_class text,
  name       text
);

-- nightly output
CREATE TABLE scores (
  way_id            bigint NOT NULL,
  provider          text NOT NULL DEFAULT 'tesla',
  version           text NOT NULL DEFAULT 'all',
  severity_per_mile double precision,
  total_severity    double precision,
  total_miles       double precision,
  incident_count    int,
  gated             boolean NOT NULL,            -- below min-mileage gate?
  calibration_version text NOT NULL DEFAULT 'm1',
  as_of             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (way_id, provider, version, as_of)
);

CREATE INDEX ON events USING gist (geom);
CREATE INDEX ON events (way_id);
CREATE INDEX ON road_segments USING gist (geom);
```

> The `features jsonb` and the `event_type` default are the seams for M2/M3. No M1 table will be
> dropped or rebuilt later.

---

## 2. Ingest API (FastAPI on Cloud Run)

`backend/ingest/app/main.py` (sketch):

```python
from fastapi import FastAPI, Depends, Header, HTTPException
from .auth import verify_firebase_token
from .schemas import TripIn, EventIn, BreadcrumbIn
from .storage import signed_upload_url
from .db import session

app = FastAPI(title="fsd-ingest")

@app.post("/v1/trips")
async def create_trip(t: TripIn, uid=Depends(verify_firebase_token)):
    await upsert_trip(t, uid)                       # idempotent on t.id
    return {"ok": True}

@app.post("/v1/events")
async def create_event(e: EventIn, uid=Depends(verify_firebase_token),
                       idem: str = Header(alias="Idempotency-Key")):
    await upsert_event(e, idem)                     # dedupe on idem
    # hand the app a one-time signed URL to PUT the audio/sensor blob straight to GCS
    return {"audio_upload": signed_upload_url(f"events/{e.id}/audio.wav"),
            "sensor_upload": signed_upload_url(f"events/{e.id}/sensors.json")}

@app.post("/v1/breadcrumbs")
async def create_breadcrumb(b: BreadcrumbIn, uid=Depends(verify_firebase_token),
                            idem: str = Header(alias="Idempotency-Key")):
    await upsert_breadcrumb(b, idem)
    return {"ok": True}

@app.get("/healthz")
async def health(): return {"status": "ok"}
```

Key points:
- **Auth:** `verify_firebase_token` uses the Firebase Admin SDK to validate the bearer ID token.
- **Idempotency:** the `idempotency_key` UNIQUE constraint makes retried uploads safe.
- **Blobs go direct to GCS** via signed URLs, so large files never stream through Cloud Run.
- Validation is Pydantic v2 models matching the app's JSON.

### Containerize
`backend/ingest/Dockerfile`:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
ENV PORT=8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

Build + push + deploy:
```bash
IMG=${REGION}-docker.pkg.dev/${PROJECT}/fsd/ingest:m1
docker build -t $IMG backend/ingest
docker push $IMG
gcloud run deploy fsd-ingest --image $IMG --region $REGION \
  --add-cloudsql-instances $PROJECT:$REGION:fsd-pg \
  --set-env-vars "DATABASE_URL=...,GCS_BUCKET=...,FIREBASE_PROJECT_ID=$PROJECT" \
  --no-allow-unauthenticated        # require Firebase token; or --allow-unauthenticated + app-level auth
```

---

## 3. Cloud SQL (PostgreSQL + PostGIS)

PostGIS is a supported Cloud SQL extension. Create via Terraform (§7), then enable the extension:
```bash
gcloud sql connect fsd-pg --user=app    # or use the Cloud SQL Auth Proxy
# in psql:
CREATE EXTENSION IF NOT EXISTS postgis;
```
Cloud Run reaches Cloud SQL via the **Cloud SQL connector** (`--add-cloudsql-instances`) or a
private IP + Serverless VPC connector. For M1 the connector is simplest.

---

## 4. Object storage (GCS)

Two buckets (Terraform-managed):
- `${PROJECT}-artifacts` — audio clips + sensor blobs. Lifecycle rule to transition to cheaper
  storage after N days; M1 volume is tiny (no video).
- `${PROJECT}-osm` — the SF OSM extract + Valhalla tiles.

The ingest API mints **V4 signed URLs** so the phone PUTs blobs directly. Use a dedicated service
account with `roles/storage.objectAdmin` on the artifacts bucket only.

---

## 5. Map-matching with Valhalla (OSS, OSM)

Valhalla snaps noisy GPS to the OSM road network and returns the matched **edge/way IDs** plus
matched geometry — exactly what risk #2 needs.

### Build SF tiles
```bash
# Download the SF Bay extract (Geofabrik provides ODbL OSM extracts)
mkdir -p backend/mapmatch/data && cd backend/mapmatch/data
curl -O https://download.geofabrik.de/north-america/us/california/norcal-latest.osm.pbf
# (norcal covers SF; trim to a bbox if you prefer a smaller build)
```

### Run Valhalla in a container
```bash
# Official-style OSS image; builds tiles on first run from the pbf you mount.
docker run -d --name valhalla -p 8002:8002 \
  -v $(pwd)/backend/mapmatch/data:/custom_files \
  ghcr.io/gis-ops/docker-valhalla/valhalla:latest
# First boot builds tiles (minutes). Then /trace_attributes is the map-matching endpoint.
```

### Use the Meili map-matching endpoint
- **Events:** POST the single point (or short track around it) to `/trace_attributes`; read back
  the matched `edge.way_id`. Store as `events.way_id` and snap `geom`.
- **Breadcrumb:** POST the trip polyline to `/trace_attributes` with `shape_match=map_snap`; for
  each matched edge, accumulate its length into `segment_exposure(way_id, trip_id, miles)`.

### Deploying Valhalla on GCP
- **Cloud Run (gen2)** can host the container if tiles are baked into the image or pulled from
  the `${PROJECT}-osm` bucket at start. Good for scale-to-zero.
- **GCE small VM** (e2-standard-2) is simplest if you want the tile cache always warm. For M1's
  tiny SF dataset either is fine; start with GCE for predictability.

Map-matching is invoked by the ingest API (synchronously for single events) and by the nightly
job (for breadcrumb exposure). Keep the way-ID extraction in a small `mapmatch` client module so
M2/M3 reuse it unchanged.

### Load the OSM ways we render
A one-off loader reads the same pbf (via `osmium`/`pyosmium`, OSS) and inserts `road_segments`
(way_id, geometry, length in miles, highway class → `road_class`, name) for the region(s) we
render. This gives the inspector something to color and gives the aggregator the `length_mi`
denominator cap.

**Regions are config, not code.** Which areas to load is a **bbox list** in config so widening
coverage is a config edit + one loader re-run — never a schema, ingest, or scoring change (the
no-rework rule: geography is data). All boxes below fall **inside** the already-built `norcal`
Valhalla tiles, so **map-matching needs no rebuild** — this loader is the only thing that changes.

```jsonc
// config: which regions road_segments covers (loader input).
// Boxes are [south_lat, west_lon, north_lat, east_lon]. VERIFY/TIGHTEN before load —
// these are generous starting rectangles, not surveyed bounds.
{
  "regions": [
    { "name": "sf_peninsula", "bbox": [37.40, -122.55, 37.85, -122.35] },
    { "name": "east_bay",     "bbox": [37.65, -122.35, 37.95, -122.10] },
    { "name": "south_bay",    "bbox": [37.20, -122.05, 37.50, -121.75] },
    { "name": "santa_cruz",   "bbox": [36.90, -122.10, 37.05, -121.95] },
    { "name": "sacramento",   "bbox": [38.45, -121.60, 38.70, -121.35] },
    { "name": "folsom",       "bbox": [38.60, -121.25, 38.72, -121.05] }
  ]
}
```

The loader iterates the list, running one bounded pass per box (osmium can filter by bbox), and
inserts the union into `road_segments` (dedupe on `way_id` since boxes may touch). Adding a metro
later is a new list entry + a re-run; removing one is a delete by region. Keep a `region` tag on
inserted rows if you want per-metro inspection filtering.

> **Scope caution (unchanged from the milestone design):** loading these six boxes *provisions*
> multi-metro coverage, but M1's feasibility questions still depend on **density**, which a
> 2-person team only builds by **concentrating** driving (SF, or a sub-area of it). Treat the
> other metros as pre-wired for M2's multi-contributor expansion — light them up as contributors
> arrive to cross the gate — rather than as places to scatter thin M1 miles. Loading the boxes is
> cheap; populating them enough to clear the min-mileage gate is the part that needs people.

---

## 6. Nightly aggregation (Cloud Run Job + Scheduler)

`backend/jobs/aggregate.py` computes, per OSM way, the M1 score:

```
severity_per_mile(way) = (Σ event.severity over that way) / (Σ exposure miles over that way)
gated = total_miles < config.scoring.min_mileage_gate_miles
```

Steps:
1. Ensure every event has a `way_id` (map-match any that arrived without one).
2. Ensure every breadcrumb is matched and its edges are summed into `segment_exposure`.
3. `GROUP BY way_id`: sum severities, sum miles, count incidents.
4. Apply the **min-mileage gate** → mark thin ways `gated = true`.
5. Insert a fresh `scores` snapshot stamped `calibration_version='m1'` and `as_of=now()`.

The query is plain SQL aggregation — no ML in M1 (that's the point of the slice). Package the job:
```dockerfile
# backend/jobs/Dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt . && RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "aggregate.py"]
```
```bash
gcloud run jobs create fsd-aggregate --image $REGION-docker.pkg.dev/$PROJECT/fsd/aggregate:m1 \
  --region $REGION --add-cloudsql-instances $PROJECT:$REGION:fsd-pg --set-env-vars DATABASE_URL=...
gcloud scheduler jobs create http fsd-aggregate-nightly \
  --schedule "0 3 * * *" --uri "<run-jobs-exec-endpoint>" --http-method POST \
  --oauth-service-account-email <runner-sa>
```

---

## 7. Terraform (all of the above as code)

Put resources in `infra/modules/` and wire them in `infra/envs/dev/main.tf`. Minimum set for M1:

```hcl
# infra/envs/dev/main.tf (abridged)
resource "google_sql_database_instance" "pg" {
  name             = "fsd-pg"
  database_version = "POSTGRES_16"
  region           = var.region
  settings { tier = "db-custom-1-3840"   # 1 vCPU / 3.75GB; small is fine for M1
             ip_configuration { ipv4_enabled = true } }
}
resource "google_sql_database" "fsd" { name = "fsd" instance = google_sql_database_instance.pg.name }
resource "google_sql_user" "app" { name = "app" instance = google_sql_database_instance.pg.name password = var.db_password }

resource "google_storage_bucket" "artifacts" {
  name = "${var.project}-artifacts" location = var.region uniform_bucket_level_access = true
  lifecycle_rule { condition { age = 90 } action { type = "SetStorageClass" storage_class = "NEARLINE" } }
}
resource "google_storage_bucket" "osm" { name = "${var.project}-osm" location = var.region uniform_bucket_level_access = true }

resource "google_cloud_run_v2_service" "ingest" {
  name = "fsd-ingest" location = var.region
  template {
    containers { image = var.ingest_image
                 env { name = "DATABASE_URL" value = var.database_url } }
    volumes { name = "cloudsql" cloud_sql_instance { instances = [google_sql_database_instance.pg.connection_name] } }
  }
}

resource "google_cloud_run_v2_job" "aggregate" { name = "fsd-aggregate" location = var.region
  template { template { containers { image = var.aggregate_image } } } }

resource "google_cloud_scheduler_job" "nightly" {
  name = "fsd-aggregate-nightly" schedule = "0 3 * * *"
  http_target { uri = "https://${var.region}-run.googleapis.com/v2/.../jobs/fsd-aggregate:run"
                http_method = "POST" oauth_token { service_account_email = var.runner_sa } }
}
```

```bash
cd infra/envs/dev
terraform init && terraform plan && terraform apply
```

Store `db_password` in **Secret Manager**, not in tfvars committed to git.

---

## 8. Acceptance checks for this file

- [ ] `POST /v1/trips`, `/v1/events`, `/v1/breadcrumbs` accept the app's payloads and dedupe on retry.
- [ ] Audio/sensor blobs land in GCS via signed URL (Cloud Run never proxies the bytes).
- [ ] A known-route breadcrumb map-matches to plausible OSM ways; `segment_exposure` miles look right.
- [ ] The nightly job writes `scores` with correct `severity_per_mile` and the gate applied.
- [ ] All cloud resources come from `terraform apply` (no click-ops left).

Next: [`04-inspection-ui.md`](./04-inspection-ui.md).
