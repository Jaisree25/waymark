-- Contract-1 schema MIRROR — for Person C's persistence tests only.
-- The canonical owner is Person A (db/schema.sql), which doesn't exist yet. This is a verbatim copy
-- of the frozen DDL in docs/M1/03-backend-gcp.md §1 so C can TDD the repository against a real
-- PostGIS without blocking on A. When A commits db/schema.sql, point the test fixture at it and
-- delete this file. Do not diverge from the contract here.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE trips (
  id                 uuid PRIMARY KEY,
  user_id            text NOT NULL,
  provider           text NOT NULL,
  fsd_version        text,
  supervision        boolean NOT NULL,
  vehicle            text,
  device_info        jsonb NOT NULL DEFAULT '{}',
  app_config_version text NOT NULL,
  started_at         timestamptz NOT NULL,
  ended_at           timestamptz,
  metrics            jsonb NOT NULL DEFAULT '{}',
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE events (
  id             uuid PRIMARY KEY,
  trip_id        uuid NOT NULL REFERENCES trips(id),
  t_trigger      timestamptz NOT NULL,
  t_pre_seconds  real NOT NULL,
  t_post_seconds real NOT NULL,
  trigger_source text NOT NULL,
  event_type     text NOT NULL DEFAULT 'incident',
  severity       int,
  features       jsonb NOT NULL DEFAULT '{}',
  geom           geography(Point,4326),
  raw_lat        double precision,
  raw_lon        double precision,
  raw_accuracy_m double precision,
  way_id         bigint,
  audio_uri      text,
  sensor_uri     text,
  idempotency_key text UNIQUE,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE breadcrumb_segments (
  id              uuid PRIMARY KEY,
  trip_id         uuid NOT NULL REFERENCES trips(id),
  track           geography(LineString,4326),
  matched_track   geography(LineString,4326),
  motion_summary  jsonb NOT NULL DEFAULT '{}',
  idempotency_key text UNIQUE,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE segment_exposure (
  way_id     bigint NOT NULL,
  trip_id    uuid NOT NULL REFERENCES trips(id),
  miles      double precision NOT NULL,
  PRIMARY KEY (way_id, trip_id)
);

CREATE TABLE road_segments (
  way_id     bigint PRIMARY KEY,
  geom       geography(LineString,4326),
  length_mi  double precision,
  road_class text,
  name       text
);

CREATE TABLE scores (
  way_id            bigint NOT NULL,
  provider          text NOT NULL DEFAULT 'tesla',
  version           text NOT NULL DEFAULT 'all',
  severity_per_mile double precision,
  total_severity    double precision,
  total_miles       double precision,
  incident_count    int,
  gated             boolean NOT NULL,
  calibration_version text NOT NULL DEFAULT 'm1',
  as_of             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (way_id, provider, version, as_of)
);

CREATE INDEX ON events USING gist (geom);
CREATE INDEX ON events (way_id);
CREATE INDEX ON road_segments USING gist (geom);
