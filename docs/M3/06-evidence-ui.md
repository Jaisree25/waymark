# M3 · 06 — Evidence in the web UI

The final M3 deliverable is **evidence on each incident**: a watchable clip, the AI summary, and the
auto-category, surfaced inside the **existing M2 views** — **Segment detail**, **Route
worst-stretches**, and **Compare**. There are **no new top-level views**; M3 adds an *evidence
surface* to incident objects the UI already renders. Everything degrades gracefully: an incident
with no clip looks exactly like an M2 incident.

> Only **blurred, servable** clips are ever shown. Held / non-servable clips show a small "clip
> withheld pending review" note and no player (matches the privacy gate in `03`).

---

## 1. New components (additive to the M2 React app)

```
web/src/components/evidence/
  ClipPlayer.tsx        # <video> with signed URL, faststart H.264, poster frame
  AiSummary.tsx         # summary text + AI auto-category chip + confidence/notes
  EvidenceBlock.tsx     # composes ClipPlayer + AiSummary; handles absent/held states
  CategoryCompare.tsx   # operator category vs AI category, shared M2 legend
```

```tsx
// EvidenceBlock.tsx (sketch) — renders only when data is present
export function EvidenceBlock({ incident }: { incident: Incident }) {
  if (!incident.clip_status) return null;                 // pure M2 incident, nothing added
  if (incident.clip_status !== "servable" || !incident.clip_url)
    return <WithheldNote status={incident.clip_status} />; // held / assembling / failed
  return (
    <div className="evidence">
      <ClipPlayer url={incident.clip_url} />              {/* short-lived signed URL from 04 */}
      <AiSummary
        summary={incident.ai_summary}
        aiCategory={incident.auto_category}
        operatorCategory={incident.category}              {/* from M2 */}
      />
    </div>
  );
}
```

- **`ClipPlayer`** plays the H.264 `blurred/clip.mp4` via the signed URL (TTL ~10 min from `04`);
  re-fetch the incident if the URL expires. No download button (privacy/retention).
- **`AiSummary`** shows the description, the **AI auto-category chip**, and — when the model flagged
  visibility limits — a small `notes` line ("night, low detail"), consistent with the project's
  honest-uncertainty UX.
- **`CategoryCompare`** shows **operator category vs AI category** using the **same legend/colours**
  as M2 (one shared taxonomy), so agreement/disagreement is visible at a glance.

---

## 2. Where evidence appears (existing views, unchanged structure)

### Segment detail
The incident list (already built in `milestone-2/05-web-ui.md`) gains an **expandable evidence
block** per incident. Collapsed by default (keeps the list scannable); expanding reveals
`EvidenceBlock`. Incidents without clips simply have nothing to expand.

### Route A→B — worst stretches
Each worst-stretch's representative incidents can open their `EvidenceBlock`, so a user reviewing a
risky route can **watch why** a stretch scored high. Same component, same data shape.

### Compare (version-vs-version, Tesla-vs-Waymo)
In the matched-segment comparison, representative incidents on **both sides** can show evidence.
This is powerful for the comparison story — a reader can watch a Tesla incident and a Waymo incident
on the **same matched segment** and judge for themselves, with the AI summary as a caption. The
stratification/condition-mix logic from `milestone-2/06-comparison.md` is unchanged; evidence is
layered on top.

---

## 3. Honest-uncertainty, applied to AI evidence

Consistent with M2's UX ethos:
- The **clip is the source of truth**; the AI summary is captioned as **auto-generated** ("AI
  summary — verify against clip") so it is never mistaken for an authoritative label.
- When operator and AI categories **disagree**, both are shown — the UI does not silently prefer
  one. (Neither feeds the score; the score is M2's operator-driven math, unchanged.)
- **Withheld clips** are shown as withheld, not hidden — the user knows evidence exists but is
  pending privacy review, rather than wondering why a high-severity incident has nothing to watch.

---

## 4. Performance & access
- Clips load **on demand** (when an evidence block is expanded), never eagerly in list views — keeps
  the map/list fast (the M2 performance concern).
- Signed URLs are minted per request by the read API (`04`); the bucket stays private.
- Poster/first-frame thumbnails (generated cheaply in the video job, optional) let the list show a
  small still without loading the full clip.

---

## 5. Build & deploy
No new toolchain — this is the **same React/Vite/MapLibre app** from `milestone-2/05-web-ui.md`,
rebuilt and redeployed to the same host (Firebase Hosting or GCS + Cloud CDN). The only data-shape
change is the **added fields** on incident objects from `04`'s read API, all optional.

```bash
cd web && npm run build && <existing M2 deploy command>
```

---

## Acceptance checks
- [ ] A servable incident in **Segment detail** expands to show a playing **blurred** clip + AI
      summary + AI auto-category chip.
- [ ] The same `EvidenceBlock` works in **Route worst-stretches** and on **both sides** of
      **Compare** (incl. Tesla-vs-Waymo on a matched segment).
- [ ] Incidents **without** a clip render exactly as M2 (no evidence surface, no errors).
- [ ] **Held / non-servable** clips show "withheld pending review" and **no** player or URL.
- [ ] Operator category vs AI category are shown together with the **shared M2 legend**; the AI
      label is captioned as auto-generated.
- [ ] Clips load **on demand**, via short-lived signed URLs, with the bucket private; no download
      affordance.
- [ ] The app builds and deploys with the existing M2 pipeline (no new toolchain).

---

## Milestone 3 — done
With evidence wired into the existing views, the full chain is intact:

> **score → incident → blurred clip → AI summary + auto-category**, end-to-end, for real SF
> incidents — with faces (and best-effort plates) blurred, clips uploaded reliably over Wi-Fi
> without overheating the phone, and scoring/comparison **unchanged** from M2.

This satisfies the M3 exit criteria. Video has been added **additively**: a new capture module, one
`features.video_ref` key, a server-side pipeline, and an evidence surface — with **no rework** to
M1/M2 capture, scoring, or comparison, and with every component open-source-first (Flutter, FFmpeg,
ML Kit, ONNX, vLLM + open-weights VLM) on Google Cloud, exactly as the brief required.
