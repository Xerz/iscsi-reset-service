from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

from pydantic import BaseModel, ConfigDict


@dataclass(slots=True)
class SessionState:
    initiator_iqn: str
    initiator_addr: str
    target_iqn: str


@dataclass(slots=True)
class ExtentState:
    id: int
    disk: str
    naa: str
    serial: str | None
    enabled: bool


@dataclass(slots=True)
class DatasetState:
    id: str
    origin: str | None
    user_properties: dict[str, str] = field(default_factory=dict)


@dataclass(slots=True)
class TargetLunState:
    target_iqn: str
    extent_id: int
    lun: int


class ApiModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PortalResponse(ApiModel):
    address: str
    port: int


class VolumeResponse(ApiModel):
    name: str
    lun: int
    disk_unique_id: str
    drive_letter: str
    label: str


class ClientResponse(ApiModel):
    schema_version: Literal[1] = 1
    status: Literal["ready"] = "ready"
    portal: PortalResponse
    target_iqn: str
    volumes: list[VolumeResponse]


class ValidateResponse(ApiModel):
    schema_version: Literal[1] = 1
    ready: bool
    checks: list[str]
    errors: list[str]


class HealthResponse(ApiModel):
    status: str
    version: str
    config_revision: str


class ErrorBody(ApiModel):
    code: str
    message: str
    request_id: str


class ErrorResponse(ApiModel):
    error: ErrorBody


class PublisherVolumeResponse(ApiModel):
    name: str
    lun: int
    disk_unique_id: str


class PublisherResponse(ApiModel):
    schema_version: Literal[1] = 1
    portal: PortalResponse
    target_iqn: str
    volumes: list[PublisherVolumeResponse]


class ReleaseResponse(ApiModel):
    name: str
    status: Literal["incomplete", "staged"]
    active: bool
    created_at: str
    completed_at: str | None
    snapshots: dict[str, str]


class ReleaseListResponse(ApiModel):
    schema_version: Literal[1] = 1
    active_release: str | None
    releases: list[ReleaseResponse]


class ReleaseValidateResponse(ApiModel):
    schema_version: Literal[1] = 1
    ready: bool
    checks: list[str]
    errors: list[str]


class ReleaseStageResponse(ApiModel):
    schema_version: Literal[1] = 1
    status: Literal["staged"] = "staged"
    release: str
    snapshots: dict[str, str]


class ActivateRequest(ApiModel):
    confirmation: str


class ReleaseActivateResponse(ApiModel):
    schema_version: Literal[1] = 1
    status: Literal["active"] = "active"
    release: str
