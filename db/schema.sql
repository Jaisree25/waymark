-- Contract 1 — the M1 database schema. Owned by Person A; depended on by B and C.
--
-- FROZEN: this file is the single source of truth for the data model (00-coordination.md §1).
-- Changing it invalidates other people's mocks, so a change here is a TEAM decision, never
-- unilateral. C's ingest repository and B's payloads are written against these exact shapes.
--
-- This is also migration 001: M1 has a single init migration, so schema.sql IS the migration
-- rather than a snapshot that can silently drift from one. Subsequent changes land as numbered
-- files in db/migrations/ and get folded in here.
--
-- Design rules this encodes (from the brief, so M1 → M2 → M3 never rework earlier data):
--   * core + attributes bag — a fixed core per table plus `features`/`metrics`/`motion_summary`
--     jsonb bags, so M2/M3 add keys without a destructive migration.
--   * store raw AND snapped — events keep raw_lat/raw_lon/raw_accuracy_m next to the snapped
--     geom/way_id. The raw→snapped delta is the risk #2 attribution check.
--   * idempotency — UNIQUE idempotency_key makes retried uploads a safe no-op.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE trips (
  id                 uuid PRIMARY KEY,
  user_id            text NOT NULL,            -- Firebase uid (authenticated, never client-supplied)
  provider           text NOT NULL,            -- 'tesla' (M1)
  fsd_version        text,
  supervision        boolean NOT NULL,
  vehicle            text,
  device_info        jsonb NOT NULL DEFAULT '{}',
  app_config_version text NOT NULL,
  started_at         timestamptz NOT NULL,
  ended_at           timestamptz,
  metrics            jsonb NOT NULL DEFAULT '{}',  -- battery/thermal/upload (risk #4)
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE events (
  id             uuid PRIMARY KEY,
  trip_id        uuid NOT NULL REFERENCES trips(id),
  t_trigger      timestamptz NOT NULL,
  t_pre_seconds  real NOT NULL,
  t_post_seconds real NOT NULL,
  trigger_source text NOT NULL,                 -- voice | tap | imu
  event_type     text NOT NULL DEFAULT 'incident',
  severity       int,                           -- 1..5 (voice), M1; NULL until rated
  features       jsonb NOT NULL DEFAULT '{}',   -- the attributes bag (empty-ish in M1)
  geom           geography(Point,4326),         -- snapped point after map-match (NULL until matched)
  raw_lat        double precision,              -- pre-match, for QA (risk #2)
  raw_lon        double precision,
  raw_accuracy_m double precision,
  way_id         bigint,                        -- OSM way after map-match (NULL until matched)
  audio_uri      text,                          -- gs://… (NULL until uploaded)
  sensor_uri     text,
  idempotency_key text UNIQUE,
  created_at     timestamptz NOT NULL DEFAULT now(),
  -- Guard the 1..5 rating at the DB, not just in C's Pydantic layer: the DB is the last line of
  -- defence and the only one a direct writer can't bypass. NULL stays legal (unrated).
  CONSTRAINT events_severity_range CHECK (severity IS NULL OR severity BETWEEN 1 AND 5)
);

CREATE TABLE breadcrumb_segments (
  id              uuid PRIMARY KEY,
  trip_id         uuid NOT NULL REFERENCES trips(id),
  track           geography(LineString,4326),   -- raw polyline
  matched_track   geography(LineString,4326),   -- after map-match
  motion_summary  jsonb NOT NULL DEFAULT '{}',
  idempotency_key text UNIQUE,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- exposure (miles) attributed to OSM ways, derived from matched breadcrumbs
CREATE TABLE segment_exposure (
  way_id     bigint NOT NULL,
  trip_id    uuid NOT NULL REFERENCES trips(id),
  miles      double precision NOT NULL,
  PRIMARY KEY (way_id, trip_id),
  CONSTRAINT segment_exposure_miles_positive CHECK (miles >= 0)
);

-- OSM ways we care about (loaded from the SF extract; geometry for rendering)
CREATE TABLE road_segments (
  way_id     bigint PRIMARY KEY,
  geom       geography(LineString,4326),
  length_mi  double precision,
  road_class text,
  name       text
);

-- nightly output
CREATE TABLE scores (
  way_id            bigint NOT NULL,
  provider          text NOT NULL DEFAULT 'tesla',
  version           text NOT NULL DEFAULT 'all',
  severity_per_mile double precision,
  total_severity    double precision,
  total_miles       double precision,
  incident_count    int,
  gated             boolean NOT NULL,            -- below the min-mileage gate?
  calibration_version text NOT NULL DEFAULT 'm1',
  as_of             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (way_id, provider, version, as_of)
);

CREATE INDEX ON events USING gist (geom);
CREATE INDEX ON events (way_id);
CREATE INDEX ON road_segments USING gist (geom);
