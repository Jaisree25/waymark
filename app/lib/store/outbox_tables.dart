// lib/store/outbox_tables.dart
//
// Cycle 4 — the durable outbox schema (drift). One row per event upload; rows
// advance ONLY through the pure queue state machine (queue_state_machine.dart).
//
// Columns follow the agreed set: id (event UUID = idempotency key), status,
// payload_json, attempts, last_error, created_at. Blobs (audio/sensor bytes)
// are NEVER stored here — they go to GCS via signed URL.
//
// NOTE: the breadcrumb/trip outbox tables are added test-first in Cycle 5 when
// the uploader needs them.

import 'package:drift/drift.dart';

@DataClassName('OutboxEvent')
class OutboxEvents extends Table {
  /// The event UUID — also the Contract-2 idempotency key (PK).
  TextColumn get id => text()();

  /// pending | uploading | done (see QueueStatus).
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// The serialized Contract-2 EventIn JSON (metadata only, no blobs).
  TextColumn get payloadJson => text()();

  /// Retry count — surfaced in Cycle 6's queue-health screen.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// Last failure reason, if any.
  TextColumn get lastError => text().nullable()();

  /// When the row was enqueued (defaults to now; overridable for tests).
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// When the row last changed state — Cycle 6's "last attempted" display.
  /// Refreshed on every transition; defaults to now on insert. (Added in v2.)
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The breadcrumb outbox (added in schema v3). Same durable, idempotent-on-id
/// persistence as events; carries `trip_id` for grouping.
@DataClassName('OutboxBreadcrumb')
class OutboxBreadcrumbs extends Table {
  TextColumn get id => text()();
  TextColumn get tripId => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get payloadJson => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The trip outbox (added in schema v3).
@DataClassName('OutboxTrip')
class OutboxTrips extends Table {
  TextColumn get id => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get payloadJson => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
