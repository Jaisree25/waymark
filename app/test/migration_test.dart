// Cycle 4.5 — schema migration tests. Establishes the migration pattern with the
// first real migration (v1 → v2 adds updated_at). We hand-build the OLD schema
// with raw sqlite3, then open with the current AppDatabase and assert the
// migration ran: existing rows survive and the new column exists.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/store/app_database.dart';
import 'package:fsd_app/store/queue_state_machine.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('migration v1 → v2: adds updated_at and preserves existing event rows',
      () async {
    final dir = await Directory.systemTemp.createTemp('fsd_migrate_v1v2');
    final file = File(p.join(dir.path, 'outbox.sqlite'));

    // Build a v1 database by hand — the schema before updated_at existed.
    final raw = sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE outbox_events (
        id TEXT NOT NULL PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'pending',
        payload_json TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL
      );
    ''');
    raw.execute(
      "INSERT INTO outbox_events (id, status, payload_json, created_at) "
      "VALUES ('evt-1', 'pending', '{}', '2026-07-10T12:00:00.000Z');",
    );
    raw.execute('PRAGMA user_version = 1;'); // drift tracks schemaVersion here
    raw.close();

    // Open with the current schema (v2) → the migration runs on upgrade.
    final db = AppDatabase(NativeDatabase(file));
    final row = await db.eventEntry('evt-1');

    expect(row, isNotNull);
    expect(row!.status, QueueStatus.pending.name); // row survived
    expect(row.updatedAt, isNotNull); // new column present and populated
    await db.close();

    await dir.delete(recursive: true);
  });

  test('migration v2 → v3: adds breadcrumb/trip outbox tables, keeps events',
      () async {
    final dir = await Directory.systemTemp.createTemp('fsd_migrate_v2v3');
    final file = File(p.join(dir.path, 'outbox.sqlite'));

    // Build a v2 database by hand — outbox_events WITH updated_at, no others.
    final raw = sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE outbox_events (
        id TEXT NOT NULL PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'pending',
        payload_json TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    raw.execute(
      "INSERT INTO outbox_events (id, status, payload_json, created_at, updated_at) "
      "VALUES ('evt-1', 'pending', '{}', "
      "'2026-07-10T12:00:00.000Z', '2026-07-10T12:00:00.000Z');",
    );
    raw.execute('PRAGMA user_version = 2;');
    raw.close();

    // Open with the current schema (v3) → onUpgrade creates the new tables.
    final db = AppDatabase(NativeDatabase(file));

    // The existing event row survives.
    expect(await db.eventEntry('evt-1'), isNotNull);

    // The new breadcrumb/trip tables exist and are usable.
    await db.enqueueBreadcrumb(
      const BreadcrumbPayload(
        id: 'bc-1',
        tripId: 'trip-1',
        track: {
          'type': 'LineString',
          'coordinates': [
            [0, 0],
            [1, 1],
          ],
        },
      ),
      createdAt: DateTime.utc(2026, 7, 10, 12),
    );
    await db.enqueueTrip(
      TripPayload(
        id: 'trip-1',
        userId: 'firebase-uid-1',
        provider: 'tesla',
        supervision: true,
        appConfigVersion: '1.0.0',
        startedAt: DateTime.utc(2026, 7, 10, 12),
      ),
      createdAt: DateTime.utc(2026, 7, 10, 12),
    );
    expect(await db.allBreadcrumbs(), hasLength(1));
    expect(await db.allTrips(), hasLength(1));

    await db.close();
    await dir.delete(recursive: true);
  });
}
