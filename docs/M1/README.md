# Milestone 1 — Feasibility / core slice (no video)

**Goal:** build the *thinnest end-to-end vertical slice* — phone → upload queue → backend →
data inspector — to answer the five questions that could sink the project, before investing in
the full product. This milestone is about **learning, not polish**.

## The five risk questions M1 must answer

| # | Risk | How M1 measures it |
|---|---|---|
| 1 | **Capture reliability** — does voice-trigger + ring buffer reliably catch the moment in a moving, noisy car? | hit-rate / false-positive-rate over a counted set of staged + real events |
| 2 | **Attribution accuracy** — does phone GPS + map-matching land events/miles on the *correct* OSM way? | map-match agreement vs. a known ground-truth route |
| 3 | **Workflow** — does the two-person flow (driver supervises FSD, passenger logs by voice) work over a real drive? | structured debrief + completion rate of intended logs |
| 4 | **Device limits** — battery, thermal, storage, offline-upload over a multi-hour drive (no video → should be modest) | drain %/hr, peak temp, disk used/hr, upload success % on cellular |
| 5 | **Sane scoring** — does `severity ÷ mile` with a min-mileage gate produce *believable* rankings on a small dataset? | team review of the SF risk map for face validity |

## In scope
- **Flutter app (iPhone 11+ / equivalent Android):** voice trigger + **audio+sensor ring
  buffer (no video)**; 1–5 severity by voice; full-trip GPS breadcrumb; trip metadata (provider,
  FSD version, supervision flag); IMU capture (stored for evaluation); durable local store;
  background upload. **All parameters in a config file from day one.**
- **Backend (GCP):** ingest API; map-match events + breadcrumb to **OSM way IDs**; store; nightly
  aggregation `severity ÷ miles` per segment with the **min-mileage gate**.
- **Inspection UI:** minimal — a map coloring driven segments by risk + a raw event/trip table /
  CSV export. Enough to *inspect data quality*, not a product.
- **Scope limits:** Tesla only, San Francisco only, the single founding two-person team.

## Out of scope (deferred to M2/M3)
Emotion/intervention/category capture, conditions/weather, provider comparison,
corridor/district rollups, the polished 3-view web UI, video, biometrics.

## Key deliverables
1. Working **app + backend + inspector**.
2. A **feasibility report** with measured results for each of the five questions.
3. A small real **SF dataset** + a risk map the team agrees looks plausible.

## Exit criteria → go/no-go for M2
Capture, attribution, workflow, and device behaviour are measured and judged "good enough" (or
gaps are understood with mitigations). A small real SF dataset produces a road-risk map the team
finds plausible.

---

## Build order

```
01 Environment setup   ──►  02 Flutter app  ──►  03 Backend (GCP)  ──►  04 Inspector  ──►  05 Feasibility tests
   (machines, GCP,            (capture +          (ingest + map-          (inspect data    (run the drives,
    tools, accounts)           queue + config)     match + aggregate)      quality)         write the report)
```

Do `01` once. `02` and `03` can proceed in parallel after `01` once the ingest contract (the
event/trip JSON) in `03` is agreed. `04` needs `03`. `05` needs everything.

## File index

| File | What it covers |
|---|---|
| [`01-environment-setup.md`](./01-environment-setup.md) | Dev machines, Flutter SDK, Python, Docker, Terraform, gcloud, GCP project bootstrap, accounts |
| [`02-flutter-app.md`](./02-flutter-app.md) | App architecture, packages, voice trigger, ring buffer, GPS/IMU, config, local store, upload |
| [`03-backend-gcp.md`](./03-backend-gcp.md) | FastAPI ingest, Cloud SQL/PostGIS, GCS, Valhalla map-matching, schema, nightly aggregation, Terraform |
| [`04-inspection-ui.md`](./04-inspection-ui.md) | Minimal MapLibre inspector + raw table + CSV export endpoint |
| [`05-feasibility-testing.md`](./05-feasibility-testing.md) | Test protocols for the 5 questions, metrics, the report template, go/no-go |

## Cross-milestone guarantees honoured here
- **Config-driven** from the first commit (`assets/config/config.v1.json`).
- **Core + attributes bag** schema (the `features` JSONB exists in M1 even though it is nearly
  empty) so M2/M3 add keys, not migrations.
- **Raw events + full breadcrumb stored** so M2's richer scoring is a recomputation.
