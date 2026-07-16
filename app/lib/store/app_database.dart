// lib/store/app_database.dart
//
// Cycle 4 — the durable local store (drift/SQLite). Every event is written here
// as 'pending' BEFORE any upload attempt; rows then advance ONLY through the
// pure queue state machine. This is the offline-first guarantee: the app can be
// killed mid-trip and the queue is intact on restart.
//
// The generated app_database.g.dart is committed alongside this file — CI runs
// `flutter test` with no codegen step. Regenerate with:
//   dart run build_runner build --delete-conflicting-outputs

import 'dart:convert';

import 'package:drift/drift.dart';

import '../capture/ports.dart';
import 'outbox_tables.dart';
import 'queue_state_machine.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [OutboxEvents, OutboxBreadcrumbs, OutboxTrips])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e, {this.clock = const SystemClock()});

  final Clock clock;

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // v1 → v2: add outbox_events.updated_at. SQLite can't ADD COLUMN with
          // a non-constant default (CURRENT_TIMESTAMP), so recreate the table via
          // TableMigration and backfill existing rows' updated_at from created_at.
          if (from < 2) {
            await m.alterTable(
              TableMigration(
                outboxEvents,
                newColumns: [outboxEvents.updatedAt],
                columnTransformer: {
                  outboxEvents.updatedAt: outboxEvents.createdAt,
                },
              ),
            );
          }
          // v2 → v3: add the breadcrumb and trip outbox tables.
          if (from < 3) {
            await m.createTable(outboxBreadcrumbs);
            await m.createTable(outboxTrips);
          }
        },
      );

  /// Enqueue an event as 'pending'. Idempotent on the event UUID: a second
  /// enqueue of the same id is ignored (insertOrIgnore), so the idempotency key
  /// and created_at are set once at event creation and never regenerated.
  Future<void> enqueueEvent(EventPayload event, {DateTime? createdAt}) {
    return into(outboxEvents).insert(
      OutboxEventsCompanion.insert(
        id: event.id,
        payloadJson: jsonEncode(event.toJson()),
        createdAt:
            createdAt == null ? const Value.absent() : Value(createdAt),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// The row for [id], or null.
  Future<OutboxEvent?> eventEntry(String id) =>
      (select(outboxEvents)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// All event rows.
  Future<List<OutboxEvent>> allEvents() => select(outboxEvents).get();

  /// Event rows still awaiting upload.
  Future<List<OutboxEvent>> pendingEvents() => (select(outboxEvents)
        ..where((t) => t.status.equals(QueueStatus.pending.name)))
      .get();

  /// Enqueue a breadcrumb segment as 'pending' (idempotent on its UUID).
  Future<void> enqueueBreadcrumb(BreadcrumbPayload b, {DateTime? createdAt}) {
    return into(outboxBreadcrumbs).insert(
      OutboxBreadcrumbsCompanion.insert(
        id: b.id,
        tripId: b.tripId,
        payloadJson: jsonEncode(b.toJson()),
        createdAt: createdAt == null ? const Value.absent() : Value(createdAt),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// All breadcrumb rows.
  Future<List<OutboxBreadcrumb>> allBreadcrumbs() =>
      select(outboxBreadcrumbs).get();

  /// Breadcrumb rows still awaiting upload.
  Future<List<OutboxBreadcrumb>> pendingBreadcrumbs() =>
      (select(outboxBreadcrumbs)
            ..where((t) => t.status.equals(QueueStatus.pending.name)))
          .get();

  /// Enqueue a trip as 'pending' (idempotent on its UUID).
  Future<void> enqueueTrip(TripPayload t, {DateTime? createdAt}) {
    return into(outboxTrips).insert(
      OutboxTripsCompanion.insert(
        id: t.id,
        payloadJson: jsonEncode(t.toJson()),
        createdAt: createdAt == null ? const Value.absent() : Value(createdAt),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// All trip rows.
  Future<List<OutboxTrip>> allTrips() => select(outboxTrips).get();

  /// The trip row for [id], or null.
  Future<OutboxTrip?> tripEntry(String id) =>
      (select(outboxTrips)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Finalize a trip on end: set `ended_at` AND `metrics` in one atomic write to
  /// the existing row (UPDATE, not insert — one row per trip). No-op if missing.
  Future<void> updateTripOnEnd(
    String tripId,
    DateTime endedAt,
    Map<String, dynamic> metrics,
  ) async {
    final row = await tripEntry(tripId);
    if (row == null) return;
    final json = jsonDecode(row.payloadJson) as Map<String, dynamic>;
    json['ended_at'] = endedAt.toUtc().toIso8601String();
    json['metrics'] = metrics;
    await (update(outboxTrips)..where((t) => t.id.equals(tripId)))
        .write(OutboxTripsCompanion(payloadJson: Value(jsonEncode(json))));
  }

  /// Advance a row through the queue state machine. Throws if the row is missing
  /// or the transition is illegal — the DB never persists an out-of-order state.
  /// On [QueueEvent.uploadFailed] the attempt count is bumped and [error] stored.
  Future<void> applyEvent(String id, QueueEvent event, {String? error}) async {
    final row = await eventEntry(id);
    if (row == null) {
      throw StateError('no outbox event for id=$id');
    }
    final next = transition(QueueStatus.values.byName(row.status), event);

    await (update(outboxEvents)..where((t) => t.id.equals(id))).write(
      OutboxEventsCompanion(
        status: Value(next.name),
        attempts: event == QueueEvent.uploadFailed
            ? Value(row.attempts + 1)
            : const Value.absent(),
        lastError: event == QueueEvent.uploadFailed
            ? Value(error)
            : const Value.absent(),
        updatedAt: Value(clock.now().toUtc()),
      ),
    );
  }
}
