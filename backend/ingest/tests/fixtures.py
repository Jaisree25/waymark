"""Golden payloads matching Contract 2. Shared across contract tests."""

from __future__ import annotations

GOLDEN_EVENT_ID = "11111111-1111-1111-1111-111111111111"
GOLDEN_TRIP_ID = "22222222-2222-2222-2222-222222222222"

GOLDEN_TRIP_IN = {
    "id": GOLDEN_TRIP_ID,
    "user_id": "test-uid",
    "provider": "tesla",
    "supervision": True,
    "app_config_version": "cfg-1",
    "started_at": "2026-07-10T18:00:00Z",
}

GOLDEN_EVENT_IN = {
    "id": GOLDEN_EVENT_ID,
    "trip_id": GOLDEN_TRIP_ID,
    "t_trigger": "2026-07-10T18:05:00Z",
    "t_pre_seconds": 8.0,
    "t_post_seconds": 4.0,
    "trigger_source": "voice",
    "severity": 3,
    "features": {},
    "raw_lat": 37.7793,
    "raw_lon": -122.4193,
    "raw_accuracy_m": 6.5,
}

GOLDEN_BREADCRUMB_IN = {
    "id": "33333333-3333-3333-3333-333333333333",
    "trip_id": GOLDEN_TRIP_ID,
    "track": {"type": "LineString", "coordinates": [[-122.4193, 37.7793], [-122.4183, 37.7799]]},
    "motion_summary": {},
}

AUTH_HEADERS = {"Authorization": "Bearer test"}
