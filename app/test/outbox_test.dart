// Cycle 4 (part 2) — the drift outbox as durable persistence of the queue state.
// NativeDatabase.memory() for fast, isolated cases; the restart test uses a real
// temp file because only closing + reopening a NEW connection to the SAME file
// proves durability.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/store/app_database.dart';
import 'package:fsd_app/store/queue_state_machine.dart';
import 'package:path/path.dart' as p;

import 'support/fakes.dart';

EventPayload eventFixture(String id) => EventPayload(
      id: id,
      tripId: '22222222-2222-4222-8222-222222222222',
      tTrigger: DateTime.utc(2026, 7, 10, 17, 30, 0),
      tPreSeconds: 15,
      tPostSeconds: 8,
      triggerSource: 'voice',
      severity: 4,
      rawLat: 37.77,
      rawLon: -122.41,
      rawAccuracyM: 5,
    );

void main() {
  final t0 = DateTime.utc(2026, 7, 10, 12, 0, 0);

  test('test_event_persists_across_restart', () async {
    final dir = await Directory.systemTemp.createTemp('fsd_outbox');
    final file = File(p.join(dir.path, 'outbox.sqlite'));
    final payload = eventFixture('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

    // Write, then close — simulating the app being killed while offline.
    var db = AppDatabase(NativeDatabase(file));
    await db.enqueueEvent(payload, createdAt: t0);
    await db.close();

    // Reopen a NEW connection to the SAME file ("restart").
    db = AppDatabase(NativeDatabase(file));
    final row = await db.eventEntry(payload.id);
    expect(row, isNotNull);
    expect(row!.status, QueueStatus.pending.name);
    await db.close();

    await dir.delete(recursive: true);
  });

  test('test_idempotency_key_stable', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final payload = eventFixture('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    await db.enqueueEvent(payload, createdAt: t0);
    // Re-enqueue the same event (same UUID) — as a retry would.
    await db.enqueueEvent(payload, createdAt: t0.add(const Duration(minutes: 1)));

    final rows = await db.allEvents();
    expect(rows, hasLength(1)); // exactly one row
    expect(rows.single.id, payload.id); // key unchanged (== event UUID)
    expect(rows.single.id, payload.idempotencyKey);
    // The original row is preserved — the key/created_at are NOT regenerated.
    expect(rows.single.createdAt, t0);
  });

  test('test_queue_states: pending → uploading → done, never skipping', () async {
    // Inject a fake clock so updated_at is deterministic on each transition.
    final clock = FakeClock(DateTime.utc(2026, 7, 10, 12, 0, 0));
    final db = AppDatabase(NativeDatabase.memory(), clock: clock);
    addTearDown(db.close);

    final payload = eventFixture('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
    await db.enqueueEvent(payload, createdAt: t0);
    expect((await db.eventEntry(payload.id))!.status, QueueStatus.pending.name);

    await db.applyEvent(payload.id, QueueEvent.uploadStarted);
    final started = (await db.eventEntry(payload.id))!;
    expect(started.status, QueueStatus.uploading.name);
    // updated_at is stamped from the injected clock, not wall time.
    expect(started.updatedAt, clock.now());

    await db.applyEvent(payload.id, QueueEvent.uploadSucceeded);
    expect((await db.eventEntry(payload.id))!.status, QueueStatus.done.name);

    // Skipping a state (pending → done) is rejected and leaves the row untouched.
    final p2 = eventFixture('dddddddd-dddd-4ddd-8ddd-dddddddddddd');
    await db.enqueueEvent(p2, createdAt: t0);
    await expectLater(
      db.applyEvent(p2.id, QueueEvent.uploadSucceeded),
      throwsStateError,
    );
    expect((await db.eventEntry(p2.id))!.status, QueueStatus.pending.name);
  });

  test('retry path: uploading → pending bumps attempts and records last_error',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final payload = eventFixture('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee');
    await db.enqueueEvent(payload, createdAt: t0);
    await db.applyEvent(payload.id, QueueEvent.uploadStarted);
    await db.applyEvent(payload.id, QueueEvent.uploadFailed, error: 'network down');

    final row = (await db.eventEntry(payload.id))!;
    expect(row.status, QueueStatus.pending.name);
    expect(row.attempts, 1);
    expect(row.lastError, 'network down');
  });
}
