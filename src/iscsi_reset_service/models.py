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
    name: str = ""
    type: str = "DISK"
    locked: bool | None = None


@dataclass(slots=True)
class DatasetState:
    id: str
    origin: str | None
    user_properties: dict[str, str] = field(default_factory=dict)
    type: str = "FILESYSTEM"
    locked: bool | None = None


@dataclass(slots=True)
class TargetLunState:
    target_iqn: str
    extent_id: int
    lun: int


@dataclass(frozen=True, slots=True)
class PortalState:
    id: int
    comment: str
    listen: tuple[tuple[str, int], ...]


@dataclass(frozen=True, slots=True)
class InitiatorGroupState:
    id: int
    comment: str
    initiators: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class TargetState:
    id: int
    iqn: str
    alias: str | None
    mode: str
    portal_ids: tuple[int, ...]
    initiator_ids: tuple[int, ...]
    auth_networks: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class TargetExtentState:
    id: int
    target_id: int
    target_iqn: str
    extent_id: int
    lun: int


@dataclass(slots=True)
class ConfigurationDiscovery:
    basename: str
    listen_port: int
    portals: list[PortalState]
    targets: list[TargetState]
    initiator_groups: list[InitiatorGroupState]
    extents: list[ExtentState]
    associations: list[TargetExtentState]
    datasets: list[DatasetState]
    sessions: list[SessionState]

    def as_dict(self) -> dict[str, object]:
        return {
            "basename": self.basename,
            "listen_port": self.listen_port,
            "portals": [
                {
                    "id": item.id,
                    "comment": item.comment,
                    "listen": [
                        {"address": address, "port": port}
                        for address, port in item.listen
                    ],
                }
                for item in self.portals
            ],
            "targets": [
                {
                    "id": item.id,
                    "iqn": item.iqn,
                    "alias": item.alias,
                    "mode": item.mode,
                    "portal_ids": list(item.portal_ids),
                    "initiator_ids": list(item.initiator_ids),
                    "auth_networks": list(item.auth_networks),
                }
                for item in self.targets
            ],
            "initiator_groups": [
                {
                    "id": item.id,
                    "comment": item.comment,
                    "initiators": list(item.initiators),
                }
                for item in self.initiator_groups
            ],
            "extents": [
                {
                    "id": item.id,
                    "name": item.name,
                    "type": item.type,
                    "disk": item.disk,
                    "naa": item.naa,
                    "serial": item.serial,
                    "enabled": item.enabled,
                    "locked": item.locked,
                }
                for item in self.extents
            ],
            "associations": [
                {
                    "id": item.id,
                    "target_id": item.target_id,
                    "target_iqn": item.target_iqn,
                    "extent_id": item.extent_id,
                    "lun": item.lun,
                }
                for item in self.associations
            ],
            "datasets": [
                {
                    "id": item.id,
                    "type": item.type,
                    "locked": item.locked,
                }
                for item in self.datasets
            ],
            "sessions": [
                {
                    "initiator_iqn": item.initiator_iqn,
                    "initiator_addr": item.initiator_addr,
                    "target_iqn": item.target_iqn,
                }
                for item in self.sessions
            ],
        }


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
