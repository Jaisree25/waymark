# M2 · 06 — Comparison (version-vs-version + Tesla vs Waymo)

The headline public result of V1. M2 ships two comparisons, both built on the **stratified,
like-with-like** rate logic from `04 §7` — **not** a regression (that's post-V1):

1. **Tesla FSD version-vs-version** (the first benchmark progression step).
2. **Tesla vs Waymo** on matched SF segments, with **confounder handling by stratification** and
   the **condition mix shown**.

This is mostly a backend aggregation query + a UI view; the math already exists in the scoring
package.

---

## 1. The principle: match, don't model (for M2)

A fair comparison must avoid blaming a provider for *where* and *when* it happened to drive. The
design's full answer is a mixed-effects negative-binomial regression with a `(1|way)` random
effect and covariates. M2's honest, lower-risk stand-in achieves the same intent by construction:

- Compare two providers/versions **only on OSM ways both drove** (same geography), and
- **only within the same condition bucket** (same weather/time/lighting), then
- **pool** the within-slice differences into a single **rate ratio**.

Because every comparison term is a same-way, same-condition pair, confounders are held fixed
**without a model**. The cost is statistical efficiency (you discard unmatched miles), which is
fine for a first public result and is exactly why the regression upgrade is left as a recompute.

---

## 2. Backend: the comparison query

Add `/v1/compare` to the read API (`03 §5`). It assembles per-slice severity + miles for each side
and calls `scoring.stratify.matched_rate_ratio`:

```python
@app.get("/v1/compare")
async def compare(kind: str,                      # "version" | "provider"
                  a: str, b: str,                 # e.g. version "v12.3" vs "v12.5"; or "tesla" vs "waymo"
                  scope: str = "city",            # city | route | district
                  bucket: str = "all"):
    slices_a = await load_slices(kind, a, scope)  # {(way_id, condition_bucket): (severity, miles)}
    slices_b = await load_slices(kind, b, scope)
    rr, (rate_a, rate_b), n_matched = matched_rate_ratio(slices_a, slices_b)
    mix = condition_mix(slices_a, slices_b)       # which buckets matched, and their share of matched miles
    return {
      "kind": kind, "a": a, "b": b, "scope": scope,
      "rate_a": rate_a, "rate_b": rate_b, "rate_ratio": rr,
      "rate_ratio_ci": rr_ci(slices_a, slices_b),  # CI from the two count-based SEs
      "matched_segments": n_matched,
      "matched_miles_a": sum_miles(slices_a, matched=True),
      "matched_miles_b": sum_miles(slices_b, matched=True),
      "condition_mix": mix,
      "gated": n_matched == 0 or below_gate(slices_a, slices_b),
      "calibration_version": "m2"
    }
```

Guardrails baked in:
- Slices below the **gate** are excluded; if nothing clears the gate, the endpoint returns
  `gated: true` and the UI shows "collecting data" (no premature verdict).
- A **rate-ratio CI** is returned so the UI never shows a bare ratio.
- The **condition mix** is returned so the UI can prove like-with-like.

> For Tesla vs Waymo, the design also notes a **supervision-modality** difference (Tesla is
> supervised, Waymo driverless). In M2 we **disclose** this explicitly in the UI rather than model
> it; controlling it formally is part of the post-V1 regression. Stratifying by condition still
> holds weather/time/geography fixed.

---

## 3. Version-vs-version (Tesla)

Same machinery with `kind="version"`, `a`/`b` = two FSD builds, provider fixed to Tesla. The
detail panel's **trend sparkline** (`05 §4`) already shows the rate across versions; this view
turns a chosen pair into a single matched rate ratio + CI ("v12.5 had X% fewer severity-weighted
incidents/mile than v12.3 on matched SF segments, in matched conditions").

This is the **first** published progression step and needs only Tesla data, so it can ship as soon
as two versions have enough overlapping mileage — earlier than the cross-provider result.

---

## 4. Tesla vs Waymo (the cross-provider result)

`kind="provider"`, `a="tesla"`, `b="waymo"`, on matched SF segments. Requirements that the rest of
the system already satisfies:
- **Identical instrument:** both logged by the same Flutter app (Waymo-passenger mode, `02 §4`).
- **Matched geography + conditions:** enforced by `matched_rate_ratio` slicing.
- **Enough overlapping miles:** the M2 data-volume risk — mitigated by concentrating driving in the
  small high-overlap SF sub-area chosen at the end of M1.

The verdict is a **rate ratio with a CI**, on matched segments, with the condition mix shown — an
honest comparative comfort/safety index, framed (per the design's legal note) as a comparative
index, never an official safety rating.

---

## 5. UI: the Compare view

`web/src/views/Compare.tsx`:
- **Selector:** pick comparison kind (version/provider), the two sides, and scope (city / a chosen
  route / a district).
- **Headline:** `rate_a` vs `rate_b` and the **rate ratio with CI** — e.g. "Tesla 0.06/mi vs Waymo
  0.10/mi on 37 matched segments; RR 0.6 (95% CI 0.4–0.9)."
- **Side-by-side map:** the matched SF segments, each colored by each provider's rate (two small
  maps or a swipe), so the geography of the comparison is visible.
- **Condition-mix strip:** a small stacked bar showing which buckets the matched miles came from
  (e.g. 60% day-dry, 25% night-dry, 15% wet) — this is the "like-with-like shown" requirement.
- **Honest-uncertainty everywhere:** if gated → "collecting data"; CI always shown; a
  "provisional · calibration m2" badge; supervision-modality disclosure for Tesla-vs-Waymo; link to
  methodology.

---

## 6. Publishing the first results (the M2 deliverable)

The two deliverables are:
1. **Tesla FSD version-vs-version risk map of SF** — the Zones map filtered to Tesla, with the
   version trend and a chosen version-pair comparison.
2. **Tesla vs Waymo on matched segments** — the Compare view above, with condition-stratified
   rates.

Each is screenshot-able straight from the UI and backed by the read API, so a reviewer can trace
every number to stored events + miles.

---

## 7. Acceptance checks for this file
- [ ] `/v1/compare` returns a rate ratio + CI + matched-segment count + condition mix, and gates
      itself when data is thin.
- [ ] Comparisons run only on ways both sides drove, within the same condition bucket.
- [ ] The Compare view shows both rates, the ratio with CI, the matched geography, and the
      condition-mix strip; it discloses the Tesla/Waymo supervision-modality difference.
- [ ] Version-vs-version works with Tesla-only data and ships before the cross-provider result.
- [ ] Nothing here imports a regression library (post-V1); upgrading to NB/Bayesian later is a
      recompute over the same stored slices.

---

## Milestone 2 done
When all six files' acceptance checks pass, the **exit criteria** hold: a user can open the web
UI, see SF zones, score a route, and view a Tesla-vs-Waymo comparison on matched segments — each
with sample size and confidence, thin-data units gated, and the Tesla version trend visible. The
complete non-video benchmark is public-usable. Proceed to **Milestone 3 — Video**.
