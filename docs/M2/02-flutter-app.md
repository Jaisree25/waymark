# M2 · 02 — Flutter app (rich capture, additive only)

Everything here is **additive** to the M1 app. The capture pipeline, ring buffer, breadcrumb
logger, local store, and upload service from `milestone-1/02-flutter-app.md` are unchanged in
structure — M2 adds **event fields** (written into the same `features` bag), **provider modes**,
**conditions stamping inputs**, **multi-contributor** support, and a **hardened** upload queue.

---

## 1. Config grows, code structure doesn't

`assets/config/config.v2.json` extends v1 with new keys (the app loads whichever version is
bundled; the loader is the same `ConfigService`):

```jsonc
{
  "config_version": "2.0.0",
  "trigger": {
    "keywords": [
      "log it", "log scary", "log dangerous", "log jerky",
      "mark level one", "mark level two", "mark level three", "mark level four", "mark level five",
      "note lane departure", "note phantom brake", "note hesitation", "note unsafe gap",
      "intervention", "took over", "had to brake"        // ← intervention grammar (privileged)
    ],
    "kws_model_dir": "assets/models/kws",
    "kws_score_threshold": 1.5,
    "confirm_chime": true
  },
  "grammar_map": {                                         // keyword → structured fields
    "log scary":        {"emotion": ["scary"]},
    "log dangerous":    {"emotion": ["dangerous"]},
    "log jerky":        {"emotion": ["jerky"]},
    "mark level one":   {"severity": 1}, "mark level two": {"severity": 2},
    "mark level three": {"severity": 3}, "mark level four": {"severity": 4}, "mark level five": {"severity": 5},
    "note lane departure": {"category": "lane_departure"},
    "note phantom brake":  {"category": "phantom_brake"},
    "note hesitation":     {"category": "intersection_hesitation"},
    "note unsafe gap":     {"category": "unsafe_gap"},
    "intervention": {"event_type": "intervention", "override_kind": null},
    "took over":    {"event_type": "intervention", "override_kind": "steering"},
    "had to brake": {"event_type": "intervention", "override_kind": "brake"}
  },
  "intervention": {
    "imu_autodetect": true,
    "hard_brake_g": 0.45,            // longitudinal decel threshold → candidate intervention
    "sharp_steer_dps": 60            // yaw-rate threshold → candidate
  },
  "conditions": { "attach_lighting": true, "attach_weather": true, "attach_time_of_day": true },
  "providers": {
    "tesla":  {"mode": "supervise", "ask_fsd_version": true},
    "waymo":  {"mode": "passenger", "ask_fsd_version": false}
  },
  "scoring": { "min_mileage_gate_miles": 10.0, "severity_scale_max": 5 },
  "upload": { "wifi_preferred": true, "allow_cellular": false, "max_retries": 12,
              "backoff_base_seconds": 5, "resumable": true }
}
```

The capture code reads `grammar_map[keyword]` and merges the structured fields into the event —
so adding a category later is a config edit, not a code change.

---

## 2. Rich event capture (writes into the same `features` bag)

On trigger, build the event from the M1 core **plus** the structured fields the keyword implied,
plus a free voice note (the spoken audio is already captured by the ring buffer; transcription is
optional/local later). All of the new fields live in `features` except the two promoted to first
class:

- **severity** stays a core column (1–5).
- **event_type** is promoted to recognize `'intervention'` (already a column in M1's schema).

```dart
// merging grammar into an event
final g = cfg.grammarMap[keyword] ?? const {};
final features = <String, dynamic>{
  if (g['emotion'] != null) 'emotion': g['emotion'],          // ["scary"]
  if (g['category'] != null) 'category': g['category'],
  if (voiceNotePath != null) 'voice_note_ref': voiceNotePath, // local until uploaded
};
final event = EventDraft(
  id: uuid.v4(),
  eventType: g['event_type'] ?? 'incident',
  severity: g['severity'],
  triggerSource: 'voice',
  features: features,           // ← attributes bag; backend stores as JSONB unchanged
);
```

### Interventions are privileged (three redundant capture paths)
1. **Voice** (`"intervention"` / `"took over"` / `"had to brake"`) → `event_type='intervention'`.
2. **IMU auto-detect:** the sensor stream already feeds the ring buffer; add a lightweight detector
   that fires a *candidate* intervention when longitudinal decel > `hard_brake_g` or yaw-rate >
   `sharp_steer_dps`. Candidate interventions are stored with `confirmed_by_human=false` in
   `features` for later review.
3. (Tesla telemetry hard-events are **M-future**, not M2 — leave the hook, don't build it.)

Storing interventions deliberately from day one (M2) is what lets the post-V1 severity-weight
calibration stabilize quickly — but M2 itself only *records* them and uses **intervention rate**
as a headline metric (see `04`).

---

## 3. Conditions: stamp the *inputs*, enrich server-side

The phone does **not** call a weather API (offline-first, battery). It stamps every event **and**
every breadcrumb segment with the inputs the server needs to derive conditions:
- precise **timestamp** (already present),
- **lat/lon** (already present),
so the backend can attach **lighting** (from `astral`) and **weather** (Open-Meteo) at ingest.

Crucially, conditions must land on **both events and breadcrumb miles** so per-condition exposure
exists (you can't compute a wet-weather rate without wet-weather miles). The app guarantees this
simply by ensuring breadcrumb segments carry timestamps + coordinates at ~1 Hz (they already do).

> Why server-side: it keeps weather logic, caching, and the conditions taxonomy in one place that
> can be **recomputed** if the taxonomy changes — consistent with "store raw, upgrade by recompute."

---

## 4. Provider modes (Tesla-supervise / Waymo-passenger)

A single toggle at trip start sets the provider; capture mechanics are **identical** across modes
(that's the scientific point — the phone is the same instrument). Mode only changes metadata:

```dart
final provider = selectedProvider;                 // 'tesla' | 'waymo'
final pcfg = cfg.providers[provider]!;
final trip = TripDraft(
  provider: provider,
  supervision: pcfg.mode == 'supervise',
  fsdVersion: pcfg.askFsdVersion ? promptForFsdVersion() : null,
);
```

For Waymo there is no human takeover, so the IMU hard-event remains the intervention anchor and
`override_kind = null`. Same capture screen, same ring buffer, same breadcrumb.

---

## 5. Multi-contributor support

M2 supports more than one phone/car. Concretely:
- Each install signs in with its own Firebase account → every trip carries `user_id`.
- The local store is per-device (unchanged); the backend merges contributions by way ID.
- Add a tiny **per-rater id** carry-through in event `features` (`"rater": uid`) so the post-V1
  per-rater emotion z-scoring has what it needs (collect now, use later).

No conflict logic is needed: contributions are independent events/miles on shared OSM ways.

---

## 6. Hardened offline queue + resumable upload

M1's `background_downloader` queue gains:
- **Resumable** large uploads enabled (`resumable: true` in config) — matters more as voice notes
  + more events accumulate.
- **Stronger retry/backoff** (`max_retries: 12`, exponential) for flaky cellular.
- **Wi-Fi-preferred** stays the default; a user toggle allows cellular.
- A **queue health screen** (extends M1's debug screen): pending/uploading/failed counts, bytes
  by network type, oldest pending age — so a logger can see the data is making it home.

The `sync_state` machine (`pending → uploading → acked → done`, `failed/retry`) is unchanged;
M2 just exercises it harder and surfaces it.

---

## 7. App structure deltas

```
lib/
├── capture/
│   ├── grammar.dart          # NEW: keyword → structured fields (reads grammar_map)
│   ├── intervention_imu.dart # NEW: IMU auto-detect of candidate interventions
│   └── ... (M1 files unchanged)
├── ui/
│   ├── trip_setup_screen.dart# NEW: provider toggle, FSD version prompt
│   └── queue_health_screen.dart # NEW: upload/queue visibility
└── ... (M1 data/upload/config unchanged in shape)
```

---

## 8. Acceptance checks for this file
- [ ] Saying `"log scary"` / `"note phantom brake"` / `"mark level four"` produces an event whose
      `features` bag carries the right emotion/category and whose severity is set — with **no schema migration**.
- [ ] `"took over"` produces `event_type='intervention'` with `override_kind`; a hard brake with no
      voice produces a candidate intervention (`confirmed_by_human=false`).
- [ ] Trips can be logged in both Tesla-supervise and Waymo-passenger modes from the same screen.
- [ ] Two different phones/accounts contribute events to the same SF ways.
- [ ] The queue health screen shows pending/failed counts and survives airplane-mode → reconnect.

Next: [`03-backend-gcp.md`](./03-backend-gcp.md).
