# M1 · 05 — Feasibility testing & the go/no-go report

This is the actual point of M1. The app, backend, and inspector exist to let you **measure** the
five risks on real SF drives and write a report the team can make a go/no-go decision from. Below
is a concrete protocol, the metric definitions, and a report template.

> Safety first, always: the **passenger logs**, never the driver. The driver's only job is to
> supervise FSD and intervene. No part of testing may add driver distraction.

---

## Test campaign shape

- **Vehicle/provider:** Tesla, FSD engaged, San Francisco only.
- **Crew:** the two-person founding team (driver + passenger-logger).
- **Duration:** enough drives to (a) exercise the device over multi-hour sessions and (b) build a
  small but *dense* dataset on a few overlapping SF streets so risk #5 has something to rank.
  Concentrate driving on a handful of corridors rather than spreading thin.
- **Ground-truth route:** define one **known reference route** (a GPX track you trust, or a route
  you drive slowly and annotate) used specifically for the attribution test (#2).

Run a mix of: a scripted **staged-trigger** drive (passenger deliberately says each keyword N
times at marked moments) and **natural** drives (log real FSD discomfort events).

---

## Risk #1 — Capture reliability

**What to measure**
- **Detection rate** = keyword detections ÷ deliberate keyword utterances (staged drive).
- **False-positive rate** = spurious detections ÷ minutes of normal driving/conversation.
- **Fallback-tap rate** = how often the passenger had to use the on-screen tap because voice missed.
- **Window correctness** = does the persisted clip actually contain the moment (`t_pre/t_post`)?

**Protocol**
1. Staged drive: passenger utters each configured keyword a fixed number of times (e.g. 20 each),
   at moments the driver calls out, with HVAC and road noise present. The app's counters
   (`02 §9`) record attempts vs detections.
2. Natural drive with normal conversation + music to provoke false positives; count spurious fires.
3. Spot-check 10 persisted clips: confirm the spoken phrase and the event are inside the window.

**Pass guidance:** detection rate high enough that the fallback tap is rarely needed, false
positives rare enough not to pollute data. If not, tune `kws_score_threshold`/keywords **in
config** and/or add the cabin mic noted in the design — and re-measure. (Tuning is config-only by
construction.)

---

## Risk #2 — Attribution accuracy

**What to measure**
- **Map-match agreement** = fraction of events/breadcrumb points snapped to the *correct* OSM way
  vs. the ground-truth route.
- **Match error** = distance between raw and snapped point; distribution of `raw_accuracy_m`.
- **Exposure correctness** = do `segment_exposure` miles on the reference route match its real
  length?

**Protocol**
1. Drive the known reference route; log events at landmarks whose correct way you can verify.
2. Export `events.csv` + `segment_exposure.csv`; in the notebook (`04 Option B`) compute the
   fraction of events on the right way and the raw→snapped error distribution.
3. Compare summed exposure on the route to its true mileage.

**Pass guidance:** the great majority of events land on the correct way and total exposure is
close to true mileage. If multipath in the metal cabin hurts results, the mitigations are
already designed in (server-side map-matching is in use; store accuracy; in M-future, Tesla
telemetry can cross-check) — quantify and document rather than block.

---

## Risk #3 — Workflow

**What to measure** (qualitative + light quantitative)
- Could the passenger log everything they intended **without looking at the screen**?
- Did the chime give enough confidence to keep eyes up?
- Intended-vs-captured event count (from debrief notes vs. stored events).
- Any moment the app created driver distraction (must be zero).

**Protocol:** structured debrief after each drive against a fixed checklist; tally intended vs
captured. Iterate the keyword grammar / chime in config.

**Pass guidance:** the two-person flow is comfortable and low-distraction over a real drive.

---

## Risk #4 — Device limits

**What to measure** (from each trip's `metrics` blob, `02 §9`)
- **Battery drain** %/hour with car charging on (should net positive or near-flat without video).
- **Peak thermal state** over a multi-hour drive (windshield sun is the worst case).
- **Storage** used per hour (tiny without video — sanity-check it really is).
- **Upload success rate** and bytes on cellular vs Wi-Fi; queue drain time after the drive.

**Protocol:** one deliberately long (2 hr+) drive in sun with charging; record the metrics; then
test upload draining on cellular-only and Wi-Fi-only.

**Pass guidance:** comfortably within an iPhone 11-class device with car charging (the design
expects this because there is no video in M1). Document any throttling needed.

---

## Risk #5 — Sane scoring

**What to measure**
- Does the colored segment map look like *plausible* SF risk to people who drive there?
- Does the min-mileage gate correctly quarantine thin roads (no 1-mile fluke topping anything)?

**Protocol:** after the campaign, open the inspector; the team reviews the risk map and the
`scores.csv` for face validity, specifically checking that gated segments are gray/dashed and
that high-severity ways match lived experience.

**Pass guidance:** the map is believable and the gate behaves. This is a judgment call, by design.

---

## Metric summary table (fill this in)

| Risk | Metric | Target / judgement | Measured | Verdict |
|---|---|---|---|---|
| 1 | detection rate | high; fallback rarely needed | | |
| 1 | false-positive rate | low | | |
| 1 | window correctness | clip contains the moment | | |
| 2 | map-match agreement | most events on correct way | | |
| 2 | exposure error | close to true mileage | | |
| 3 | intended vs captured | ≈ all intended captured | | |
| 3 | driver distraction | zero | | |
| 4 | battery %/hr (charging) | net flat/positive | | |
| 4 | peak thermal | no shutdown/throttle harm | | |
| 4 | storage/hr | tiny (no video) | | |
| 4 | upload success % | high; queue drains | | |
| 5 | map face validity | team agrees plausible | | |
| 5 | gate behaviour | thin roads quarantined | | |

---

## Feasibility report template (`docs/m1-feasibility-report.md`)

```markdown
# M1 Feasibility Report — FSD Benchmark

## Summary & recommendation
GO / NO-GO for M2, in one paragraph, with the single biggest risk called out.

## Campaign
Dates, drives, total miles, corridors, vehicle/FSD version, crew.

## Risk 1 — Capture reliability
Method, numbers (detection %, FP rate, window checks), what we tuned in config, conclusion.

## Risk 2 — Attribution accuracy
Reference route, map-match agreement %, error distribution, exposure error, conclusion.

## Risk 3 — Workflow
Debrief findings, intended-vs-captured, distraction assessment, grammar/chime changes.

## Risk 4 — Device limits
Battery/thermal/storage/upload numbers from the long drive, throttling notes.

## Risk 5 — Sane scoring
The SF risk map (screenshot), gate behaviour, team face-validity verdict.

## Decisions captured (feed M2)
- config values that worked (thresholds, t_pre/t_post, gate)
- which SF sub-area maximizes overlap (open item from design §13.5)
- any hardware add-ons needed (cabin mic, mount)

## Open risks carried into M2
List, with mitigations.
```

---

## Go / no-go criteria

**GO to M2** when: capture, attribution, workflow, and device behaviour are measured and judged
good enough (or gaps are understood with concrete mitigations), **and** a small real SF dataset
produces a road-risk map the team finds plausible.

**NO-GO / iterate** when a core risk fails *and* the mitigation isn't config-tunable — e.g. voice
trigger unusable even after threshold/keyword/mic changes, or map-matching error large enough to
misattribute most events. In that case the slice has done its job cheaply: you learned before
building the full product.

---

## Acceptance checks for this file
- [ ] Every row of the metric table has a measured value and a verdict.
- [ ] The feasibility report is written and circulated.
- [ ] A recorded go/no-go decision exists, with the config values and SF sub-area chosen for M2.
