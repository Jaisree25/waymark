# M3 · 05 — AI summarization

The summarizer turns a clip's **sampled frames** plus the event's **structured context** (severity,
category if the operator gave one, conditions, provider/version) into two things:

1. a short, **human-readable description** of what happened, and
2. an **auto-classification** into the **same incident taxonomy** M2 already uses.

The primary model is an **open-weights vision-language model** served by **vLLM** (open-source
constraint), with a **managed Gemini** path only as a fallback. Summaries are always
**human-verifiable** because the blurred clip is attached in the UI — the AI describes, it does not
adjudicate.

> Scope reminder: M3 scoring/comparison is **unchanged**. The auto-category is *displayed* evidence;
> it does **not** feed the score. (Learned multi-modal severity weighting stays post-V1.)

---

## 1. Model & serving (open-weights first)

- **Primary:** an open VLM such as **Qwen2.5-VL-7B-Instruct** (or the current best open VLM at build
  time — verify), served by **vLLM** with an OpenAI-compatible API (`/v1/chat/completions`,
  multi-image messages). Host per `01-environment-setup.md` (GCE L4 Option A or Vertex Option B).
- **Batching:** the video job collects all newly-servable clips and summarizes them in one batch run
  so the GPU is busy briefly then released (cost). This matches the nightly-job cadence.
- **Fallback:** **Gemini** (managed multimodal) behind the same internal `summarize()` interface,
  used only when the self-hosted endpoint is unavailable or returns low-confidence/empty output.
  Record `model` per summary so results are auditable and comparable.

```python
# backend/video/summarize.py  (sketch)
def summarize_clip(clip_id: str, frames: list[Path]) -> bool:
    ctx = db.event_context(clip_id)                     # severity, category?, conditions, provider, version
    imgs = pick_frames(frames, k=cfg.vlm_max_frames)    # e.g. 6–10 evenly spaced frames
    try:
        out = call_vllm(PROMPT, ctx, imgs)              # primary open-weights VLM
    except VlmUnavailable:
        out = call_gemini(PROMPT, ctx, imgs)            # managed fallback
    parsed = parse_summary_json(out)                    # {summary, category, confidence}
    db.upsert_summary(clip_id, model=out.model, summary=parsed.summary,
                      auto_category=map_to_taxonomy(parsed.category), raw=out.raw)
    return True
```

---

## 2. Prompt design (context-grounded, taxonomy-constrained)

The prompt gives the model the **structured context** so its description is consistent with what the
operator logged, and **constrains the category** to the existing taxonomy so output is mappable.

```text
SYSTEM:
You describe a short forward-facing dashcam clip from a self-driving evaluation drive.
You are given several frames in time order and structured context. Faces and plates are blurred;
do not attempt to identify people or vehicles. Be factual and concise. Do not speculate beyond
what is visible. Output STRICT JSON only, no prose outside it.

USER (context):
- Provider: {provider}  Version: {version}
- Operator severity (1–5): {severity}
- Operator category (may be empty): {category_or_blank}
- Conditions: {lighting}, {weather}, time {local_time}
- Frames: {N} images in chronological order follow.

Return JSON:
{
  "summary": "<=40 words, what the car/road/other actors did during the clip>",
  "category": "<one of: {TAXONOMY_LIST}>",
  "confidence": <0.0-1.0>,
  "notes": "<optional: visibility limits, e.g. 'glare', 'night, low detail'>"
}
```

Design notes:
- **Strict JSON** output → reliable parsing (the M2 backend already favours hand-checkable,
  structured data). Reject + retry once if it doesn't parse; on second failure, store the raw text
  and mark `auto_category=null`.
- **Constrain `category`** to the literal M2 taxonomy list (interpolated) so it maps 1:1; anything
  off-list maps to `other`.
- **Context-grounding** (severity/conditions) makes the description align with the operator's log,
  and lets the model note when **visibility limits** its confidence (night/glare) — surfaced in the
  UI as honesty, consistent with the project's uncertainty ethos.
- **Frame count** (`vlm_max_frames`) is config — start small (6–10) to control tokens/latency/cost.

---

## 3. Auto-classification → existing taxonomy

`map_to_taxonomy()` is a thin, **exact-match** mapping from the constrained model output to the M2
incident categories (the same enum used by the operator's manual `category`). No new vocabulary, no
fuzzy ML mapping — if the model returns a value outside the enum, it becomes `other`. This keeps the
UI able to show **operator category vs AI category** side by side using one shared legend.

---

## 4. Human-verifiability & safety

- The **blurred clip is always attached** in the UI next to the summary, so a reader can verify the
  AI's description against the footage. The AI is **descriptive evidence**, not a scoring input.
- Summaries are stored in `clip_summaries` with the **full raw model output** (`raw_json`) for
  audit, and the `model` field, so a later/better VLM is a clean **re-summarization** over stored
  clips — a recomputation, not re-collection (the no-rework rule, applied to AI).
- The model is instructed **not to identify** individuals/vehicles (and frames are blurred anyway),
  reinforcing the privacy posture from `03`.

---

## 5. Cost & throughput controls (all config)
- `vlm_max_frames` — frames per clip (primary cost lever).
- Batch size + GPU on/off (Option A) or scale-to-zero (Option B).
- Skip summarization for **held** clips (only servable clips are summarized).
- Retry policy: 1 reparse retry, then Gemini fallback, then `auto_category=null` with the clip still
  servable (clip without summary is still useful evidence).

---

## Acceptance checks
- [ ] The open-weights VLM, served by vLLM, returns **strict JSON** with `summary`, `category`
      (from the M2 taxonomy), `confidence`, and optional `notes` for a real clip's frames.
- [ ] `category` is mapped 1:1 into the existing M2 incident taxonomy; off-list → `other`.
- [ ] The prompt includes severity/category/conditions/provider/version context and the model's
      description is consistent with it.
- [ ] Gemini fallback engages when the primary endpoint is unavailable; `model` is recorded per
      summary.
- [ ] `clip_summaries` stores `summary`, `auto_category`, `model`, and full `raw_json`; re-running
      the summarizer with a different model overwrites cleanly (recomputation).
- [ ] Summarization runs only on **servable** clips and in **batch**; the GPU is released between
      batches.
- [ ] A clip whose summary fails twice is **still servable** with `auto_category=null` (evidence
      without a description).

---
**Next:** [`06-evidence-ui.md`](./06-evidence-ui.md) — surfacing the clip + summary + auto-category
in the existing M2 web views.
