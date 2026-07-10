# M2 · 04 — Scoring engine (the M2 math)

A small, well-tested Python package (`backend/scoring/`) that the nightly job imports and the read
API surfaces. It is deliberately the **simple, honest** version of the model — exactly what the
milestone scopes:

> M2 scoring = `severity ÷ mile`, **min-mileage gate**, **intervention rate**, **condition
> buckets**, **corridor/district rollups**, and **confidence tiers** with **fixed risk bands**.
>
> **Not** in M2 (post-V1, recomputable from stored data): empirical-Bayes / Gamma–Poisson
> shrinkage, learned severity weights, recency decay, and the negative-binomial / Bayesian
> regression comparison. We leave clean seams for them but do **not** build them.

Keeping these out is a feature: it removes ML risk from a milestone whose only real risk is data
volume, while the stored raw data guarantees the richer models can be added later as a
recomputation.

---

## 1. Package layout

```
backend/scoring/
├── __init__.py
├── rates.py        # severity-per-mile, intervention rate
├── gate.py         # min-mileage gate + confidence tiers
├── bands.py        # fixed risk bands → color index + display score
├── rollups.py      # corridor (length-weighted) + district (exposure-weighted)
├── stratify.py     # like-with-like condition matching (used by 06 comparison)
└── tests/          # pytest; hand-checkable fixtures
```

Pure functions over plain inputs (dicts / pandas frames) so they're trivially testable and reused
by both the job and any future recompute.

---

## 2. Severity-per-mile (the headline rate)

For a unit (way) and a slice `(provider, version, condition_bucket)`:

```python
# rates.py
def severity_per_mile(total_severity: float, total_miles: float) -> float | None:
    if total_miles <= 0: return None
    return total_severity / total_miles
```

- `total_severity` = sum of event `severity` (1–5) over the slice. (M2 uses the **raw voiced
  severity**; learned weights are post-V1.)
- `total_miles` = exposure from breadcrumb map-matching for the *same* slice (so a wet-weather rate
  divides wet-weather severity by wet-weather miles).

A simple **Poisson/normal-approx confidence interval** on the rate is enough for M2 honesty (full
posteriors are post-V1):
```python
import math
def rate_ci(total_severity, total_miles, z=1.96):
    if total_miles <= 0: return (None, None)
    rate = total_severity / total_miles
    se = math.sqrt(total_severity) / total_miles      # count-based SE on a rate
    return (max(0.0, rate - z*se), rate + z*se)
```
This widens automatically when miles/counts are small — which, with the gate and tiers, is the M2
way of "never show a bare point estimate."

---

## 3. Intervention rate (privileged objective metric)

```python
def intervention_rate(n_interventions: int, total_miles: float) -> float | None:
    return None if total_miles <= 0 else n_interventions / total_miles
```
Interventions (voice `"took over"` etc., or IMU-detected candidates from `02`) are counted per
slice. In M2 this is reported as its own headline number (driver disengagements per mile) — an
**action, not an opinion** — alongside severity-per-mile. (Using interventions to *train* severity
weights is post-V1.)

---

## 4. Gate + confidence tiers

```python
# gate.py
def confidence_tier(total_miles, cfg) -> str:
    if total_miles < cfg.gate_miles:        return "insufficient"   # gated out of rankings/compare
    if total_miles < cfg.solid_miles:       return "provisional"
    return "solid"

def is_gated(total_miles, cfg) -> bool:
    return total_miles < cfg.gate_miles
```
Thresholds (`gate_miles`, `solid_miles`) come from config so they're tunable without code. Gated
units render gray/dashed and are quarantined from rankings and comparisons (design §9.9).

---

## 5. Fixed risk bands + display score

The map color is a **stable, version-stamped** band, not a live percentile, so a road's color
never drifts with no new data. M2 uses **fixed bands** (the simple, honest version of the design's
`rate_ref`; per-road-class percentile `rate_ref` is a post-V1 refinement):

```python
# bands.py
# config-driven, version-stamped band edges in incidents/mile, e.g.:
#   BANDS = [0.00, 0.05, 0.10, 0.15, 0.20]  → 5 bands, ≥0.20 is worst
def risk_band(rate, band_edges) -> int:
    for i, edge in enumerate(band_edges):
        if rate < edge: return i
    return len(band_edges)

def display_score(rate, rate_ref) -> float:        # 0–100, higher = safer (display only)
    return 100.0 * (1.0 - min(rate / rate_ref, 1.0))
```
- **Color/score is display-only.** Every comparison uses the **raw rate**, never the score — keep
  these layers strictly separate (design §8.5). The band edges and `rate_ref` are **frozen and
  version-stamped** (`calibration_version='m2'`).

---

## 6. Rollups (corridor + district)

```python
# rollups.py
def corridor_rate(member_rates, member_lengths):           # length-weighted
    num = sum(r*L for r, L in zip(member_rates, member_lengths) if r is not None)
    den = sum(L   for r, L in zip(member_rates, member_lengths) if r is not None)
    return num/den if den else None

def district_rate(member_rates, member_miles):             # exposure-weighted
    num = sum(r*m for r, m in zip(member_rates, member_miles) if r is not None)
    den = sum(m   for r, m in zip(member_rates, member_miles) if r is not None)
    return num/den if den else None
```
Corridor and district scores are **derived from way scores**, never modeled separately (design
§8.1). A user-entered **route** is the *same* length-weighted computation over a different set of
ways (so `03`'s `/v1/route` calls `corridor_rate` on the route's ways and also returns the
**worst stretches** = the member ways with the highest rates).

CIs propagate by combining the member SEs (variance of a weighted sum); good enough for M2 and
honest about uncertainty.

---

## 7. Stratified, like-with-like comparison (foundation for `06`)

The honest M2 alternative to a regression: compare providers/versions **only within matched
slices** so confounders are held fixed by construction.

```python
# stratify.py
def matched_rate_ratio(slices_a, slices_b):
    """
    slices_*: dict keyed by (way_id, condition_bucket) -> (severity, miles)
    Compare A vs B only on keys present in BOTH, both above the gate, then pool.
    """
    common = [k for k in slices_a if k in slices_b
              if slices_a[k].miles >= GATE and slices_b[k].miles >= GATE]
    sev_a = sum(slices_a[k].severity for k in common); mi_a = sum(slices_a[k].miles for k in common)
    sev_b = sum(slices_b[k].severity for k in common); mi_b = sum(slices_b[k].miles for k in common)
    rate_a, rate_b = sev_a/mi_a, sev_b/mi_b
    return rate_a / rate_b, (rate_a, rate_b), len(common)   # RR + the two pooled rates + #matched
```

This enforces "same road, same conditions" — the M2 stand-in for the design's `(1|way)` random
effect and covariate control. It also returns the **condition mix** (the buckets that matched) so
the UI can show like-with-like. `06` builds the Tesla-vs-Waymo and version-vs-version views on top
of this.

> Why this is the right M2 choice: it gives a defensible, explainable number now, on matched SF
> segments, with no model risk; the negative-binomial / Bayesian upgrade is a drop-in later
> because the raw per-slice severities and miles are all stored.

---

## 8. Tests (make the math hand-checkable)

`tests/` should include tiny fixtures whose answers you can verify by hand, mirroring the design's
worked examples:
- a 5-segment toy set → check `severity_per_mile`, banding, gate.
- a corridor of 3 ways with known lengths → check length-weighted rollup.
- two providers on 3 matched segments (the design's S1/S2/S3 table) → check `matched_rate_ratio`.

```bash
cd backend && pytest scoring/tests -q
```

---

## 9. Acceptance checks for this file
- [ ] `severity_per_mile`, `intervention_rate`, gate, tiers, bands, and rollups are pure, tested functions.
- [ ] Display score/color is provably never used in any comparison path (grep + a test).
- [ ] `matched_rate_ratio` compares only on slices present in both and above the gate, and returns
      the matched condition mix.
- [ ] Band edges + `rate_ref` are config-driven and version-stamped.
- [ ] No `statsmodels`/`pymc` import exists anywhere in M2 (post-V1 only).

Next: [`05-web-ui.md`](./05-web-ui.md).
