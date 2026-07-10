# M1 · Person C (backend + infra + UI) — TDD plan: services & glue

**You own the services and the glue between them:** the environment/GCP bootstrap, the FastAPI
ingest API, GCS signed URLs, the Valhalla deployment + the `MapMatcher` implementation, the Cloud
Run deploy + Terraform, and the inspection UI. You **define** Contract 2 (the API) and **implement**
Contract 3 (the map-match client) that Person A consumes.

You depend on A's **schema** (Contract 1) and A's **export callables** (for the UI). You test the DB
layer with a **real local PostGIS** (same image as A) so you don't mock away the thing most likely
to break.

Feasibility ownership: **risk #2 (attribution accuracy)** — is map-matching putting events on the
right way? — and **risk #3 (two-person workflow)** end-to-end reliability.

---

## 1. TDD setup (do this first)

```bash
python3.12 -m venv .venv && source .venv/bin/activate
pip install pytest httpx "fastapi>=0.115" "uvicorn[standard]" "pydantic>=2.9" \
            "psycopg[binary]>=3.2" "sqlalchemy>=2.0" geoalchemy2 \
            google-cloud-storage respx testcontainers
# Local PostGIS for API tests (or reuse A's test DB on :5433)
docker run -d --name fsd-pg-test -p 5433:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd_test postgis/postgis:16-3.4
```

Two test layers:
- **Fast contract tests** — FastAPI `TestClient`/`httpx.ASGITransport` with GCS **faked** (no
  network), asserting request/response shapes and idempotency.
- **Integration tests** — the real app against real local PostGIS, and the real `MapMatcher` against
  a real local Valhalla (a few, slower, run in CI).

> Rule: **red first.** Write the endpoint test (or the map-match assertion) before the handler.
> Fake GCS and Firebase; do **not** fake PostGIS or Valhalla — those are the risky seams.

---

## 2. Build order as red-green-refactor cycles

### Cycle 0 — Freeze Contract 2, then bootstrap infra
- Author `contracts/openapi.yaml` **with the team** (the endpoints in `00-coordination.md` §2). This
  is a deliverable, not an afterthought — B mocks against it immediately.
- Stand up `../01-environment-setup.md` infra as code: GCP project, Artifact Registry, the tfstate
  bucket, GCS buckets, Cloud SQL. Terraform is testable too:
  - 🔴 `terraform validate` + `terraform plan` in CI must succeed and show the expected resource set.
  - 🟢 Write the `infra/` modules until plan is clean; apply to a dev project.

### Cycle 1 — Ingest API request/response (GCS + Firebase faked)
Build the endpoints from their tests, using `TestClient`.

```python
# tests/test_events_endpoint.py
def test_post_event_returns_signed_urls(client, fake_gcs):
    r = client.post("/v1/events", json=GOLDEN_EVENT_IN,
                    headers={"Authorization": "Bearer test", "Idempotency-Key": "k1"})
    assert r.status_code == 200
    body = r.json()
    assert body["audio_upload"].startswith("https://storage.googleapis.com/")
    assert fake_gcs.signed_calls == ["events/<id>/audio.wav", "events/<id>/sensors.json"]
```

- 🔴 `test_healthz` · `test_post_event_returns_signed_urls` · `test_post_trip_ok` ·
  `test_post_breadcrumb_ok`.
- 🔴 `test_event_validation_rejects_bad_severity` — Pydantic rejects severity 6 → 422 (before it ever
  reaches A's CHECK).
- 🔴 `test_missing_idempotency_key_400` — the header is required on events/breadcrumbs.
- 🟢 Implement the FastAPI handlers + Pydantic models (`EventIn/TripIn/BreadcrumbIn`) matching
  Contract 2; inject a `StoragePort` and `AuthPort` you fake in tests.
- ♻️ Keep GCS + Firebase behind ports so units never hit the network.

### Cycle 2 — Persistence + idempotency (real PostGIS, A's schema)
Now wire handlers to A's tables (Contract 1) and prove idempotency at the API layer.

- 🔴 `test_event_persists` — POST → exactly one row in `events` with the posted fields.
- 🔴 `test_duplicate_idempotency_key_is_noop` — same `Idempotency-Key` twice → one row, `200` both
  times (relies on A's UNIQUE constraint; catch the conflict cleanly).
- 🔴 `test_trip_upsert_idempotent` — re-POSTing a trip with the same `id` doesn't duplicate.
- 🟢 Implement the repository layer against A's migrated schema (run A's `db/schema.sql` in the test
  DB).
- ♻️ This is where the shared `test_idempotency_end_to_end` lives — keep it green.

### Cycle 3 — Signed URLs to real GCS (thin integration)
- 🔴 `test_signed_url_roundtrip` — (integration) generate a signed PUT URL, PUT bytes, GET them back;
  asserts the app's blobs really land in the bucket.
- 🟢 Implement the real `StoragePort` over `google-cloud-storage`.
- ♻️ Confirm large blobs never stream through the app (the app returns a URL; the client PUTs
  directly).

### Cycle 4 — Valhalla + the `MapMatcher` (Contract 3, risk #2)
Deploy Valhalla (`../03-backend-gcp.md` §5) and implement the interface A depends on.

```python
# tests/test_mapmatcher_integration.py   (needs local Valhalla + SF tiles)
def test_known_point_matches_expected_way():
    m = ValhallaMatcher(base_url=LOCAL_VALHALLA)
    edge = m.match_event(lat=37.7793, lon=-122.4193)      # a known SF corner
    assert edge is not None and edge.way_id == KNOWN_WAY_ID
```

- 🔴 `test_known_point_matches_expected_way` · `test_track_returns_ordered_edges` ·
  `test_offroad_point_returns_None`.
- 🔴 `test_matcher_satisfies_contract` — the returned `MatchedEdge` has the exact field types A's
  persistence expects (the shared `test_mapmatch_contract`).
- 🟢 Implement `ValhallaMatcher(MapMatcher)` calling `/trace_attributes`.
- ♻️ Hand A the real matcher at Checkpoint 2; A's exposure/attribution code runs unchanged.

> Risk #2 lives here: a small labelled set of SF points with known correct ways becomes a
> **regression test** for match accuracy — "attribution is good enough" is a passing test, not an
> opinion.

### Cycle 5 — Deploy the API (Cloud Run) + smoke tests
- 🔴 `test_deployed_healthz` — a post-deploy smoke test hits the real Cloud Run URL `/healthz`.
- 🔴 `test_deployed_auth_required` — an unauthenticated event POST is rejected.
- 🟢 Containerize + `gcloud run deploy` (`../03-backend-gcp.md` §2); add to Terraform/CI.
- ♻️ Wire the deploy + smoke tests into CI so every merge is validated.

### Cycle 6 — Inspection UI + export endpoints (uses A's queries)
Wrap A's export callables (`exports.py`) as read-only endpoints and render the MapLibre page
(`../04-inspection-ui.md`).

- 🔴 `test_segments_geojson_endpoint` — `/v1/inspect/segments.geojson` returns valid GeoJSON with
  score properties (calls A's query).
- 🔴 `test_events_geojson_shows_raw_and_snapped` — response includes both raw and snapped points
  (the risk #2 visual).
- 🔴 `test_csv_export_endpoints` — the four CSV exports download with correct headers.
- 🟢 Implement the FastAPI routes over A's callables; build the static MapLibre page that draws
  road_segments colored by `severity_per_mile` and overlays raw-vs-snapped points.
- ♻️ Keep the UI a thin, static client (no proprietary keys — OpenFreeMap/PMTiles per M2 §1) so it's
  trivially hostable.

---

## 3. Your checkpoints
- **Checkpoint 1:** Cycles 0–2 green — API accepts Contract-2 payloads and writes A's schema on local
  PostGIS; Terraform plan clean.
- **Checkpoint 2:** real GCS + real `MapMatcher` wired; B's app hits the real API; A consumes the
  real matcher. All three shared contract tests green.
- **Checkpoint 3:** deployed API + inspection UI show a real SF drive; risks #2 and #3 validated.

---

## 4. Definition of done (Person C)
- [ ] `contracts/openapi.yaml` frozen (Contract 2) and matched by the running app.
- [ ] `pytest` green: endpoint contracts, idempotency on real PostGIS, signed-URL roundtrip,
      MapMatcher integration, deploy smoke tests, export endpoints.
- [ ] `ValhallaMatcher` implements Contract 3 and passes A's `test_mapmatch_contract` unchanged.
- [ ] Risk #2 (attribution) backed by a labelled SF regression test; risk #3 (workflow) validated
      end-to-end at Checkpoint 3.
- [ ] Infra is Terraform + CI; nothing critical created by hand in a console.
- [ ] Inspection UI renders A's export queries with raw-vs-snapped visualization.

---
Coordination & contracts: [`00-coordination.md`](./00-coordination.md). Peers:
[`person-a-database.md`](./person-a-database.md), [`person-b-mobile.md`](./person-b-mobile.md).
