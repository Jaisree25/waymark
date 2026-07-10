"""Persistence against Person A's schema (Contract 1).

C writes rows through this layer but NEVER owns the DDL — A owns db/schema.sql and migrations.
Idempotency relies on A's UNIQUE constraints (idempotency_key, trip id); we catch the conflict
cleanly and treat a duplicate as a no-op (200 both times).

Implementation intentionally deferred to Cycle 2 (real PostGIS). The Protocol lets Cycle 1 unit
tests inject a fake repo so endpoint shapes can be tested before the DB is wired.
"""

from __future__ import annotations

from typing import Protocol

from .schemas import BreadcrumbIn, EventIn, TripIn


class Repository(Protocol):
    def upsert_trip(self, trip: TripIn, uid: str) -> None: ...
    def upsert_event(self, event: EventIn, idempotency_key: str) -> None: ...
    def upsert_breadcrumb(self, breadcrumb: BreadcrumbIn, idempotency_key: str) -> None: ...


class SqlRepository(Repository):
    """Real repo over A's migrated schema (psycopg/SQLAlchemy). Filled in Cycle 2."""

    def __init__(self, database_url: str) -> None:
        self._database_url = database_url

    def upsert_trip(self, trip: TripIn, uid: str) -> None:
        raise NotImplementedError("Cycle 2 — implement against A's schema on real PostGIS")

    def upsert_event(self, event: EventIn, idempotency_key: str) -> None:
        raise NotImplementedError("Cycle 2 — INSERT ... ON CONFLICT (idempotency_key) DO NOTHING")

    def upsert_breadcrumb(self, breadcrumb: BreadcrumbIn, idempotency_key: str) -> None:
        raise NotImplementedError("Cycle 2 — implement against A's schema on real PostGIS")
