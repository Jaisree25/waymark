# backend/jobs — the nightly pipeline (Person A)

## The problem it solves

Raw events and breadcrumbs don't answer the question anyone actually asks: *is this road riskier
than that one?* This job turns them into a per-road number, nightly:

```
severity_per_mile(way) = Σ event.severity  /  Σ exposure miles
gated                  = total_miles < config.scoring.min_mileage_gate_miles
```

That's the whole M1 model. **Deliberately plain SQL — no ML, no smoothing, no priors.** The slice
exists to test whether the *pipeline* produces a sane number, and a simple number you can verify by
hand is the only kind you can trust that judgement on. This is feasibility **risk #5**.

## What's here

| File | What it is |
|---|---|
| [`nightly.py`](./nightly.py) | **The entrypoint**: attribute → build exposure → aggregate. |
| [`aggregate.py`](./aggregate.py) | Step 3 alone: one SQL aggregation → a `scores` snapshot. |
| [`config/scoring.json`](./config/scoring.json) | The versioned gate + calibration version. |
| [`Dockerfile`](./Dockerfile) | The Cloud Run Job image (C wires it in as `aggregate_image`). |
| [`tests/`](./tests/) | 30 tests on a **real** PostGIS, with a fake matcher. |

## Intent / design rules

- **The gate is config, not code.** `min_mileage_gate_miles` lives in `config/scoring.json`
  (override with `SCORING_CONFIG`). Retuning it is a config edit + re-run — never a code change or a
  migration. It mirrors the app config's `scoring` block; keep the two in step.
- **"No data" must never look like "no risk".** This drives the two least obvious decisions here:
  a road with **exposure but no events** scores a real `0.0`, while a road with **events but no
  miles** scores `NULL` — undefined, not zero and not infinity. And a road with 1 mile driven scores
  `0.0` but is **gated**, so the UI grays it instead of painting it reassuringly green.
- **Scores are an audit trail, not a current value.** Each run appends a snapshot stamped `as_of` +
  `calibration_version`, so an old score stays interpretable under a later tuning.
- **One run, one `as_of`.** The stamp is read once (`clock_timestamp()`) and passed as a parameter,
  so a snapshot can't tear across ways. It's `clock_timestamp()` and not `now()` because `now()` is
  the *transaction* timestamp — two runs in one transaction would collide on the `scores` PK.
- **Three steps, in order.** `nightly.py` attributes events → builds exposure → aggregates. Step 3
  alone is meaningless: with no exposure every way has a zero denominator, gates out, and scores
  NULL. `test_aggregation_alone_would_have_gated_everything` pins exactly that.
- **Map-matching happens here, not at ingest**, so a slow or down Valhalla can never reject an
  upload. The phone's data lands immediately as raw; attribution catches up overnight.
- **The pipeline depends on the interface, not Valhalla.** `run_nightly` takes a Contract 3
  `MapMatcher`; only `main()` knows `ValhallaMatcher` exists. So the whole chain is tested with a
  fake and no Valhalla running.
- **Re-running is safe, and re-running matters.** Every step is idempotent, and exposure is rebuilt
  for *all* trips each night rather than only new ones — uploads are resumable, so a trip's
  breadcrumbs can arrive across several nights, and skipping trips that already had rows would
  freeze them at partial mileage and permanently overstate their risk. That costs O(all trips) in
  Valhalla calls: the first thing to make incremental as data grows.

## Test / run steps

Tests need a real PostGIS (aggregation *is* SQL, so faking the DB would test nothing). They read A's
canonical `db/schema.sql`, so schema drift breaks a test rather than production:

```bash
docker run -d --name fsd-pg-test -p 5433:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd_test postgis/postgis:16-3.4

cd backend/jobs && pytest              # 19 tests
DATABASE_URL=postgresql://app:app@127.0.0.1:5433/fsd_test python aggregate.py
```

The core fixture is hand-checkable on purpose: severities 3 and 5 over 4 miles → `8 / 4 = 2.0`.
"Is the score sane?" should be a passing test, not a vibe.

## Ownership note

Person A owns the scoring. C only wires the built image into Cloud Run Jobs + Scheduler
(`infra/modules/stack`, gated behind `enable_aggregate` until this image is published).
