# M2 · 05 — Web UI (the three-view viewer)

A **read-only**, map-centric React app that renders the pre-computed scores from `03`/`04`. It
implements the three required views — **Zones**, **Route A→B**, **Ranking** — plus the **Segment
detail** panel and the honest-uncertainty UX. (The **Compare** view is in
[`06-comparison.md`](./06-comparison.md); it lives in the same app.)

Stack (all OSS): **React + TypeScript + Vite**, **MapLibre GL JS** for the map, **uPlot** for the
trend sparkline and route risk profile, **TanStack Query** for data fetching, Tailwind for layout.
Basemap from an OSS source (OpenFreeMap or self-hosted Protomaps PMTiles). The UI mostly **renders
and filters**; all aggregation already happened server-side.

---

## 1. App shell + data layer

```
web/src/
├── main.tsx
├── api.ts                 # typed fetchers for /v1/scores/*, /v1/segment, /v1/route, /v1/ranking, /v1/compare
├── map/
│   ├── MapView.tsx        # MapLibre instance, layers, legend
│   ├── layers.ts          # line layer (roads) + fill layer (districts) paint expressions
│   └── confidence.ts      # texture encoding (solid/dashed/faded) — separate channel from color
├── views/
│   ├── Zones.tsx          # district → corridor → segment drill-down
│   ├── Route.tsx          # A→B scoring + worst stretches + risk profile
│   ├── Ranking.tsx        # sortable leaderboard with gate quarantine
│   └── Compare.tsx        # (06)
├── panels/
│   └── SegmentDetail.tsx  # the §9.4 trio + trend + category breakdown + incident list
└── ui/
    ├── ConfidenceKey.tsx  # legend for textures
    └── UncertaintyBadge.tsx # provisional / insufficient banners
```

`api.ts` mirrors the read endpoints; every response type carries `{ risk_rate, ci_low, ci_high,
miles, incident_count, confidence_tier, risk_band, safety_score }`.

---

## 2. The map: two independent visual channels

The single most important UI rule (design §9.2): **color answers "how risky," texture answers
"how sure," and they are independent.** A thin-data road must never render as confident green/red.

```ts
// layers.ts — road line layer
export const roadLinePaint = {
  // COLOR = safety score band (fixed, version-stamped)
  'line-color': ['match', ['get','risk_band'],
     0,'#1a9850', 1,'#91cf60', 2,'#fee08b', 3,'#fc8d59', 4,'#d73027',
     /* default */ '#999999'],
  'line-width': 4,
  // TEXTURE = confidence, encoded SEPARATELY
  'line-dasharray': ['match', ['get','confidence_tier'],
     'solid', ['literal',[1,0]],
     'provisional', ['literal',[3,2]],
     'insufficient', ['literal',[1,3]],   // faint dotted
     ['literal',[1,0]]],
  'line-opacity': ['match', ['get','confidence_tier'],
     'insufficient', 0.4, 'provisional', 0.75, 1.0]
};
```

District fills use the same band colors at low opacity; the legend shows the green→red scale with
its `rate_ref` anchor **and** a separate key for the confidence textures (`ConfidenceKey.tsx`).

---

## 3. Zones view (city → district → corridor → segment)

Three nested zoom levels matching the hierarchy (design §9.3):
- **District:** SF split into neighborhood polygons, each tinted by its exposure-weighted score;
  a ranked district list beside the map. Answers "which part of the city is worst."
- **Corridor:** click into a district → named roads, each length-weighted; selecting one reveals
  its **worst sub-stretches**. Answers "how is this road overall."
- **Segment:** zoom to individual OSM ways, each with its own rate + CI. Answers "is this block risky."

A breadcrumb (City › District › Corridor › Segment) drives navigation; the detail panel always
reflects the selected unit. A **condition-bucket filter** (all / day / night / wet / rush…) swaps
the `bucket` query param so the map recolors per condition — possible only because conditions are
on both events *and* miles (`03 §2`).

---

## 4. Segment / corridor / district detail panel

`SegmentDetail.tsx` shows (design §9.4):
- **Headline risk rate** with CI + sample size — the honest trio, always together.
- **Safety score** (0–100) + color swatch (the glanceable, in-city value).
- **Trend** — risk rate across FSD versions / over time as a uPlot sparkline (history comes from
  retained `scores` snapshots).
- **Incident breakdown by category** (lane departure, phantom brake, hesitation…) as a small bar list.
- **Incident list** — each event: timestamp, severity, category, conditions. (M3 adds a clip
  thumbnail here.)
- **Confidence note** — explicit banner when provisional/gated ("based on 6 miles — provisional").

---

## 5. Route A→B view

`Route.tsx` (design §9.5): user enters origin + destination → `/v1/route` (which routes via
Valhalla and length-weights the ways' scores):
- **Route score** (0–100) + **route risk rate** (quotable absolute number), each with propagated CI.
- **Worst stretches** — ranked list of the specific ways dragging the route down, each clickable
  to its detail panel.
- **Risk profile** — an "elevation-style" strip chart (uPlot) along route distance showing the
  score rising/falling stretch by stretch, so the user sees *where* risk concentrates.
- **Alternative routes** — if Valhalla returns options, score each so the user can pick the safer one.

---

## 6. Ranking / leaderboard view

`Ranking.tsx` (design §9.6): tables answering "which provider/version/road/district is best," with
the non-negotiable guardrails:
- Columns: unit name, **risk rate (incidents/mile)**, CI, sample size (miles), safety score.
- **Sorted by risk rate**, but units **below the gate** are pushed into a visually separated
  "not enough data yet" section — a 1-mile fluke can never top the table.
- Scopes: city-wide, per district, per major route, per provider, per FSD version.

---

## 7. Honest-uncertainty UX (non-negotiable, applies everywhere)

Enforced across all views (design §9.9):
- **No confident color on thin data** — confidence is the separate texture channel (§2).
- **Exposure gating** — ranking/comparison claims withheld ("collecting data") until the gate clears.
- **Provisional badges** — early outputs carry a visible "provisional · calibration m2" stamp.
- **CIs always visible** — wide intervals are shown wide, never hidden.
- **Methodology link** — every score links to a plain-language "how is this computed" page (the
  M2 simplified version of Appendix A). This is what makes a public benchmark defensible.

`UncertaintyBadge.tsx` and a shared `<RateWithCI>` component make it impossible to render a bare
point estimate by accident.

---

## 8. Build, deploy, host

```bash
cd web
npm run build                       # → dist/
firebase deploy --only hosting      # Firebase Hosting (CDN-backed, easy)
# — or — GCS + Cloud CDN:
gsutil -m rsync -r dist gs://${PROJECT}-web && # configure a load balancer + Cloud CDN in Terraform
```

The viewer calls the read-only API on Cloud Run. Lock CORS to the hosting origin; the read API is
public (it serves a public benchmark) but rate-limited.

---

## 9. Acceptance checks for this file
- [ ] The map colors SF roads by risk band and **independently** textures them by confidence;
      a thin-data road is visibly uncertain, never confidently colored.
- [ ] Zones drills City → District → Corridor → Segment with a working breadcrumb and condition filter.
- [ ] Route A→B returns a score, worst stretches, and an elevation-style risk profile.
- [ ] Ranking sorts by risk rate and quarantines gated units in a separate section.
- [ ] No view can display a point estimate without its CI + sample size + tier.
- [ ] Every score links to the methodology page.

Next: [`06-comparison.md`](./06-comparison.md).
