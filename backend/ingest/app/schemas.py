"""Pydantic v2 models matching Contract 2 (contracts/openapi.yaml).

These validate the app's JSON BEFORE it ever reaches A's schema (e.g. severity 1..5 → 422 here,
not a DB CHECK violation). Keep them in lockstep with the OpenAPI file — that file is the contract.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field


class TripIn(BaseModel):
    id: str
    user_id: str
    provider: str = "tesla"
    fsd_version: str | None = None
    supervision: bool
    vehicle: str | None = None
    device_info: dict[str, Any] = Field(default_factory=dict)
    app_config_version: str
    started_at: datetime
    ended_at: datetime | None = None
    metrics: dict[str, Any] = Field(default_factory=dict)


class EventIn(BaseModel):
    id: str
    trip_id: str
    t_trigger: datetime
    t_pre_seconds: float
    t_post_seconds: float
    trigger_source: Literal["voice", "tap", "imu"]
    event_type: str = "incident"
    severity: int | None = Field(default=None, ge=1, le=5)  # rejects 6 → 422 before A's CHECK
    features: dict[str, Any] = Field(default_factory=dict)  # attributes bag — carried through verbatim
    raw_lat: float | None = None
    raw_lon: float | None = None
    raw_accuracy_m: float | None = None


class GeoJSONLineString(BaseModel):
    type: Literal["LineString"]
    coordinates: list[list[float]]


class BreadcrumbIn(BaseModel):
    id: str
    trip_id: str
    track: GeoJSONLineString
    motion_summary: dict[str, Any] = Field(default_factory=dict)


class OkResponse(BaseModel):
    ok: bool = True


class EventUploadResponse(BaseModel):
    audio_upload: str
    sensor_upload: str
