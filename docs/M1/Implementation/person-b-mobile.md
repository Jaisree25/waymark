# M1 · Person B (mobile / Flutter) — TDD plan: the capture app

**You own the app end-to-end** (`../02-flutter-app.md`): the voice trigger, the audio+sensor ring
buffer, the trip/breadcrumb logger, the local `drift` store, and the resumable upload client. You
produce the JSON that Person C's ingest API consumes (Contract 2) and PUT blobs to the signed URLs
it returns.

You depend on one external thing — the **ingest API** (Contract 2) — which you hit via a **stub
server** until Checkpoint 2, so you're never blocked on C.

Feasibility ownership: **risk #1 (capture reliability)** and **risk #4 (device limits / thermal)** —
your on-device instrumentation produces those metrics.

---

## 1. TDD setup (do this first)

Flutter's test pyramid: fast **unit tests** for pure logic (most of your TDD), **widget tests** for
UI, and a few **integration tests** on a real device (the parts a simulator can't prove).

```bash
flutter create app && cd app
# test deps
flutter pub add --dev flutter_test mocktail
flutter pub add drift sqlite3_flutter_libs geolocator sensors_plus \
                background_downloader connectivity_plus audioplayers yaml
# sherpa_onnx for the on-device keyword trigger (see ../02-flutter-app.md)
flutter pub add sherpa_onnx
flutter test              # runs unit + widget tests headless
```

Isolate hardware behind interfaces so logic is unit-testable **without** a device:

```dart
// lib/capture/ports.dart  — the seams you fake in tests
abstract class Clock { DateTime now(); }
abstract class MicSource { Stream<AudioFrame> frames(); }        // faked in tests
abstract class SensorSource { Stream<ImuSample> samples(); }
abstract class LocationSource { Stream<Position> positions(); }
abstract class IngestClient {                                    // Contract 2
  Future<UploadUrls> postEvent(EventPayload e, {required String idempotencyKey});
  Future<void> postBreadcrumb(BreadcrumbPayload b, {required String idempotencyKey});
  Future<void> postTrip(TripPayload t);
}
```

> Rule: **red first.** Each cycle starts with a failing `test(...)`. Hardware-dependent behaviour is
> tested through the fakes above; only the final integration cycle touches a real phone.

---

## 2. Build order as red-green-refactor cycles

### Cycle 1 — The ring buffer (pure logic, the heart of capture)
A fixed-duration rolling buffer of audio/sensor frames; on trigger, emit the `[t-pre, t+post]`
window.

```dart
// test/ring_buffer_test.dart
test('keeps only the last N seconds', () {
  final rb = RingBuffer<int>(capacity: Duration(seconds: 30), clock: fakeClock);
  for (var i = 0; i < 100; i++) { fakeClock.advance(Seconds(1)); rb.add(i); }
  expect(rb.window(from: fakeClock.now() - Seconds(30), to: fakeClock.now()).length, 30);
});
test('trigger emits t_pre + t_post window', () { /* … */ });
```

- 🔴 `keeps only the last N seconds` · `evicts oldest` · `window() honours t_pre/t_post`.
- 🟢 Implement `RingBuffer<T>` with a `Clock` (no real time in tests).
- ♻️ Reuse the same generic for audio and IMU buffers.

### Cycle 2 — Voice trigger → event assembly
Wire the (faked) `MicSource` through sherpa_onnx KWS to produce an `Event` with the buffered window.

- 🔴 `test_keyword_fires_event` — feeding a frame stream that the KWS recognizes produces exactly one
  `Event` with `trigger_source='voice'` and a non-empty audio window.
- 🔴 `test_debounce` — two keywords within the debounce window produce one event, not two.
- 🔴 `test_event_payload_matches_contract` — the assembled `EventPayload` serializes to JSON that
  validates against Contract 2's `EventIn` (load `openapi.yaml`, assert).
- 🟢 Implement the trigger pipeline behind `MicSource`; keep sherpa_onnx behind an interface so tests
  use a fake recognizer.
- ♻️ Extract `EventPayload.toJson()` and pin it with a golden-file test.

### Cycle 3 — Trip + breadcrumb logger
Continuous GPS → breadcrumb polyline; trip lifecycle (start/stop).

- 🔴 `test_breadcrumb_accumulates_positions` — feeding a faked `LocationSource` builds a LineString
  in order.
- 🔴 `test_trip_start_stop` — a trip opens on start, closes on stop, and stamps `app_version` /
  `config_version`.
- 🔴 `test_breadcrumb_payload_matches_contract` — serializes to Contract 2's `BreadcrumbIn`.
- 🟢 Implement `TripLogger` / `BreadcrumbLogger` over the faked sources.
- ♻️ Feed positions from a recorded GPX fixture for realism.

### Cycle 4 — Local durable store (`drift`)
Everything is written locally first, then uploaded — the app must survive being killed offline.

- 🔴 `test_event_persists_across_restart` — enqueue an event, reopen the DB, it's still there and
  `pending`.
- 🔴 `test_idempotency_key_stable` — an event's `idempotency_key` is generated once and never changes
  across retries (matches A's UNIQUE constraint).
- 🔴 `test_queue_states` — rows move `pending → uploading → done` and never skip.
- 🟢 Define the `drift` schema + DAO; implement the outbox queue.
- ♻️ Keep the queue logic pure (a state machine) so it's unit-tested without the real DB where
  possible.

### Cycle 5 — Resumable upload client (Contract 2, on the stub)
Post metadata to the ingest API, then PUT blobs to the returned signed URLs; Wi-Fi-preferred,
resumable, idempotent.

```dart
// test/upload_test.dart  — against a fake IngestClient, no network
test('event upload is idempotent on retry', () async {
  final client = FakeIngestClient();                 // records calls
  final up = Uploader(client, net: fakeWifi);
  await up.flush([pendingEvent]);
  await up.flush([pendingEvent]);                     // retry same row
  expect(client.eventsPosted.where((e) => e.id == pendingEvent.id), hasLength(1));
});
```

- 🔴 `event upload is idempotent on retry` (above) · `waits for Wi-Fi when cellular disallowed` ·
  `PUTs blob to the signed URL from the response` · `marks row done only after blob PUT succeeds`.
- 🟢 Implement `Uploader` over `IngestClient` + `background_downloader`; drive network state from a
  fake.
- ♻️ Point the real `IngestClient` at a **stub server** (a tiny local HTTP returning Contract-2
  shapes) so the whole flow runs in CI without C.

### Cycle 6 — On-device feasibility instrumentation (risks #1 & #4)
Metrics are a feature — build them test-first too.

- 🔴 `test_capture_reliability_metric` — given a sequence of triggers and captures, the metric =
  captured ÷ attempted is computed correctly (risk #1).
- 🔴 `test_thermal_sampling` — a faked thermal source over a drive produces the max/avg thermal
  state and any dropped-capture count (risk #4).
- 🟢 Implement the metrics collectors; surface them on a debug screen and in the upload payload's
  `features`/`motion_summary`.
- ♻️ Keep collectors pure so they're asserted in unit tests, then validated on a real drive at
  Checkpoint 3.

### Cycle 7 — Device integration (the part a simulator can't prove)
A small `integration_test/` suite on **real phones** (iPhone via TestFlight per
`../01-environment-setup.md` §1b; Android directly):

- real mic actually triggers on the chosen keyword in cabin-like noise (risk #1),
- a real 20-minute drive doesn't overheat / drop captures (risk #4),
- an event + breadcrumb reach the **real** ingest API (Checkpoint 2).

---

## 3. Your checkpoints
- **Checkpoint 1:** Cycles 1–5 green against fakes + stub server; app runs on a device and queues
  data offline.
- **Checkpoint 2:** swap the stub for C's **real** ingest API; `test_openapi_roundtrip` (shared)
  passes; a queued event lands in A's tables.
- **Checkpoint 3:** real SF drive produces events + breadcrumbs end-to-end; risks #1 and #4 metrics
  collected for the feasibility report.

---

## 4. Definition of done (Person B)
- [ ] `flutter test` green: ring buffer, trigger, loggers, store, uploader, metrics.
- [ ] `EventPayload`/`BreadcrumbPayload` JSON validated against Contract 2 (golden + schema tests).
- [ ] Upload is proven **idempotent, offline-durable, Wi-Fi-preferred** by unit tests, not just by
      hand.
- [ ] iOS **and** Android builds run (iOS via CI per §1b) and pass the device integration suite.
- [ ] Risk #1 and #4 metrics implemented test-first and captured on a real drive.
- [ ] No dependency on C's internals — only on Contract 2.

---
Coordination & contracts: [`00-coordination.md`](./00-coordination.md). Peers:
[`person-a-database.md`](./person-a-database.md), [`person-c-backend-infra.md`](./person-c-backend-infra.md).
