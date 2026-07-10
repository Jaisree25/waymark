# Milestone 2 — Required features (no video)

**Goal:** the **complete, public-usable non-video benchmark** — rich event capture, the full M2
scoring model, confounder-aware comparison, and the three end-user web views. M2 builds *on* M1
with **no rework**: new event fields are keys in the same `features` attributes bag, new behaviour
is new keys in the same config file, and the richer scoring is a **recomputation** of data M1
already stored.

> Scope discipline: M2 is "pure (low-risk) product engineering." It is CRUD, sums/divisions,
> `GROUP BY`s, and map rendering — **no ML and no video**. The empirical-Bayes shrinkage, learned
> severity weights, and regression-based comparison from the system design are explicitly
> **post-V1** and are *not* built here. M2's comparison is the honest, simpler **stratified
> like-with-like** rate comparison.

## In scope
- **App:** full event capture (1–5 severity **plus** optional emotion tags, intervention flag +
  type, incident category, free voice note); **conditions auto-attached** (weather, time-of-day,
  lighting) to **both events and breadcrumb miles**; hardened offline queue + resumable
  Wi-Fi-preferred upload; **provider modes** (Tesla-supervise, Waymo-passenger); multi-contributor.
- **Backend:** aggregate `severity ÷ miles` per **(segment, provider, version)** *and per
  condition bucket*; compute **intervention rate**; roll up to **corridor** and **district**;
  scoring with **min-mileage gate + confidence tiers** and fixed risk bands.
- **Web UI (read-only):** **Zones**, **Route A→B**, **Ranking**, **Segment detail**, and
  **Compare** (Tesla version-vs-version, then Tesla vs Waymo on matched SF segments with
  stratified confounder handling and the condition mix shown). Honest-uncertainty UX throughout.

## Out of scope (deferred)
Video, AI summaries, biometrics, Tesla Fleet API, learned severity weights, Bayesian/regression
analytics. All deferred deliberately; the **raw data is stored so they can be added later** as
recomputations.

## Key deliverables
1. The **three-view web product** live for SF.
2. First published results: **Tesla FSD version-vs-version** risk map of SF, then **Tesla vs
   Waymo** on matched segments with **condition-stratified** rates.

## Exit criteria
A user can open the web UI, see SF zones, score a route, and view a Tesla-vs-Waymo comparison on
matched segments — each with sample size and confidence, and with thin-data units gated.
Version-vs-version trend is visible for Tesla.

## The real risk for M2 is *data volume*, not code
Technically M2 is low-risk. The gate and meaningful comparisons need **enough miles**, which
depends on driving, not code. Mitigation: concentrate driving in a **small, high-overlap SF
area** (the sub-area chosen at the end of M1) to build density fast. Until thresholds are met the
gate honestly shows "collecting data" — that is correct behaviour, not a defect. Waymo is logged
by riding as a passenger with the **same app** in Waymo-passenger mode — the identical instrument
is what keeps the comparison fair.

---

## Build order

```
01 Env deltas ─► 02 App (rich capture, ─► 03 Backend (rich   ─► 04 Scoring   ─► 05 Web UI ─► 06 Comparison
   (web stack,      conditions, provider     aggregation,        engine          (3 views)    (version & Tesla
    weather, libs)   modes, multi-user)       rollups, tiers)     (the math)                   vs Waymo)
```

`04 Scoring` is a shared Python package consumed by `03` (the nightly job) and surfaced by `05`
(the read-only API). `06` is mostly a UI + a stratified-aggregation query built on `04`.

## File index

| File | What it covers |
|---|---|
| [`01-environment-setup.md`](./01-environment-setup.md) | Deltas vs M1: Node/React/Vite web toolchain, weather API, extra Python/GCP bits |
| [`02-flutter-app.md`](./02-flutter-app.md) | Rich capture, conditions auto-attach, provider modes, multi-contributor, hardened upload — all additive |
| [`03-backend-gcp.md`](./03-backend-gcp.md) | Schema additions, condition enrichment, per-bucket aggregation, corridor/district rollups, read API |
| [`04-scoring-engine.md`](./04-scoring-engine.md) | The M2 math: severity÷mile, gate, confidence tiers, risk bands, intervention rate, stratification |
| [`05-web-ui.md`](./05-web-ui.md) | React + MapLibre: Zones, Route A→B, Ranking, Segment detail; honest-uncertainty UX; hosting |
| [`06-comparison.md`](./06-comparison.md) | Tesla version-vs-version + Tesla vs Waymo stratified comparison & condition-mix display |

## No-rework guarantees honoured here
- New event fields (emotion/intervention/category/note) are **keys in `features` JSONB** + one
  promoted `event_type='intervention'` value — M1 rows remain valid.
- New behaviour (conditions, provider modes, gates, tiers) are **new config keys** in
  `config.v2.json` — capture code is unchanged structurally.
- Richer scoring runs over **M1's stored raw events + breadcrumbs** — a recomputation, not a
  re-collection.
