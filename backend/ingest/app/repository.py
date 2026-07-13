"""Persistence against Person A's schema (Contract 1).

C writes rows through this layer but NEVER owns the DDL — A owns db/schema.sql and migrations.
Idempotency relies on A's UNIQUE constraints (idempotency_key on events/breadcrumbs, PK on trips):
a retried upload conflicts and is a clean no-op (ON CONFLICT DO NOTHING), 200 both times.

The Protocol lets Cycle 1 unit tests inject a fake repo; SqlRepository is the real implementation,
covered by the persistence integration tests against a real local PostGIS.
"""

from __future__ import annotations

import json
from typing import Protocol

from psycopg.types.json import Json
from psycopg_pool import ConnectionPool

from .schemas import BreadcrumbIn, EventIn, TripIn


class Repository(Protocol):
    def upsert_trip(self, trip: TripIn, uid: str) -> None: ...
    def upsert_event(self, event: EventIn, idempotency_key: str) -> None: ...
    def upsert_breadcrumb(self, breadcrumb: BreadcrumbIn, idempotency_key: str) -> None: ...


class SqlRepository(Repository):
    """Real repo over A's migrated schema (psycopg 3), backed by a connection pool.

    Cloud Run reuses one pool for the app's lifetime — never a fresh connect per request (that would
    storm Cloud SQL's connection cap). The pool opens lazily on first use. Each `pool.connection()`
    block commits on clean exit, rolls back on exception, and returns the connection to the pool.
    """

    def __init__(self, database_url: str, *, min_size: int = 1, max_size: int = 10) -> None:
        self._pool = ConnectionPool(database_url, min_size=min_size, max_size=max_size, open=False)
        self._opened = False

    def _tx(self):
        if not self._opened:
            self._pool.open()
            self._opened = True
        return self._pool.connection()

    def close(self) -> None:
        if self._opened:
            self._pool.close()
            self._opened = False

    def upsert_trip(self, trip: TripIn, uid: str) -> None:
        # user_id is the AUTHENTICATED uid, never the client-supplied body field (which could be spoofed).
        with self._tx() as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO trips (id, user_id, provider, fsd_version, supervision, vehicle,
                                   device_info, app_config_version, started_at, ended_at, metrics)
                VALUES (%(id)s, %(user_id)s, %(provider)s, %(fsd_version)s, %(supervision)s,
                        %(vehicle)s, %(device_info)s, %(app_config_version)s, %(started_at)s,
                        %(ended_at)s, %(metrics)s)
                ON CONFLICT (id) DO NOTHING
                """,
                {
                    "id": trip.id,
                    "user_id": uid,
                    "provider": trip.provider,
                    "fsd_version": trip.fsd_version,
                    "supervision": trip.supervision,
                    "vehicle": trip.vehicle,
                    "device_info": Json(trip.device_info),
                    "app_config_version": trip.app_config_version,
                    "started_at": trip.started_at,
                    "ended_at": trip.ended_at,
                    "metrics": Json(trip.metrics),
                },
            )

    def upsert_event(self, event: EventIn, idempotency_key: str) -> None:
        with self._tx() as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO events (id, trip_id, t_trigger, t_pre_seconds, t_post_seconds,
                                    trigger_source, event_type, severity, features,
                                    raw_lat, raw_lon, raw_accuracy_m, idempotency_key)
                VALUES (%(id)s, %(trip_id)s, %(t_trigger)s, %(t_pre)s, %(t_post)s,
                        %(trigger_source)s, %(event_type)s, %(severity)s, %(features)s,
                        %(raw_lat)s, %(raw_lon)s, %(raw_accuracy_m)s, %(idem)s)
                ON CONFLICT (idempotency_key) DO NOTHING
                """,
                {
                    "id": event.id,
                    "trip_id": event.trip_id,
                    "t_trigger": event.t_trigger,
                    "t_pre": event.t_pre_seconds,
                    "t_post": event.t_post_seconds,
                    "trigger_source": event.trigger_source,
                    "event_type": event.event_type,
                    "severity": event.severity,
                    "features": Json(event.features),
                    "raw_lat": event.raw_lat,
                    "raw_lon": event.raw_lon,
                    "raw_accuracy_m": event.raw_accuracy_m,
                    "idem": idempotency_key,
                },
            )

    def upsert_breadcrumb(self, breadcrumb: BreadcrumbIn, idempotency_key: str) -> None:
        with self._tx() as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO breadcrumb_segments (id, trip_id, track, motion_summary, idempotency_key)
                VALUES (%(id)s, %(trip_id)s,
                        ST_SetSRID(ST_GeomFromGeoJSON(%(track)s), 4326)::geography,
                        %(motion_summary)s, %(idem)s)
                ON CONFLICT (idempotency_key) DO NOTHING
                """,
                {
                    "id": breadcrumb.id,
                    "trip_id": breadcrumb.trip_id,
                    "track": json.dumps(breadcrumb.track.model_dump()),
                    "motion_summary": Json(breadcrumb.motion_summary),
                    "idem": idempotency_key,
                },
            )
