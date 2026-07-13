// Cycle 5 — the breadcrumb and trip outbox tables (added in schema v3). Same
// durable, idempotent-on-id persistence as the event outbox.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/store/app_database.dart';
import 'package:fsd_app/store/queue_state_machine.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 10, 12, 0, 0);

  BreadcrumbPayload breadcrumb(String id) => BreadcrumbPayload(
        id: id,
        tripId: 'trip-1',
        track: const {
          'type': 'LineString',
          'coordinates': [
            [-122.41, 37.77],
            [-122.42, 37.78],
          ],
        },
      );

  TripPayload trip(String id) => TripPayload(
        id: id,
        userId: 'firebase-uid-1',
        provider: 'tesla',
        supervision: true,
        appConfigVersion: '1.0.0',
        startedAt: t0,
      );

  test('breadcrumb outbox: enqueue + read back, idempotent on id', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await db.enqueueBreadcrumb(breadcrumb('bc-1'), createdAt: t0);
    await db.enqueueBreadcrumb(breadcrumb('bc-1'), createdAt: t0); // idempotent

    final rows = await db.allBreadcrumbs();
    expect(rows, hasLength(1));
    expect(rows.single.id, 'bc-1');
    expect(rows.single.tripId, 'trip-1');
    expect(rows.single.status, QueueStatus.pending.name);
  });

  test('trip outbox: enqueue + read back, idempotent on id', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await db.enqueueTrip(trip('trip-1'), createdAt: t0);
    await db.enqueueTrip(trip('trip-1'), createdAt: t0); // idempotent

    final rows = await db.allTrips();
    expect(rows, hasLength(1));
    expect(rows.single.id, 'trip-1');
    expect(rows.single.status, QueueStatus.pending.name);
  });
}
