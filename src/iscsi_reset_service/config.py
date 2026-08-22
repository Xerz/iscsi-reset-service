from __future__ import annotations

import hashlib
import ipaddress
import json
import re
from pathlib import Path
from typing import Annotated, Any, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import yaml
from pydantic import BaseModel, ConfigDict, Field, IPvAnyAddress, model_validator

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,47}$")
IQN_RE = re.compile(r"^iqn\.[0-9]{4}-[0-9]{2}\.[^\s:]+:.+$", re.IGNORECASE)
TOKEN_DIGEST_RE = re.compile(r"^hmac-sha256:[0-9a-f]{64}$")
DATASET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$")
PREFIX_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")


class UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects ambiguous duplicate mapping keys."""


def _construct_unique_mapping(
    loader: UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[Any, Any]:
    loader.flatten_mapping(node)
    result: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in result
        except TypeError as exc:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found an unhashable mapping key",
                key_node.start_mark,
            ) from exc
        if duplicate:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key: {key}",
                key_node.start_mark,
            )
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_unique_mapping,
)


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class PortalConfig(StrictModel):
    address: IPvAnyAddress
    port: Annotated[int, Field(ge=1, le=65535)] = 3260

    @model_validator(mode="after")
    def require_ipv4(self) -> PortalConfig:
        if self.address.version != 4:
            raise ValueError("portal.address must be IPv4")
        return self


class ReleaseManagementConfig(StrictModel):
    prefix: str = "games"
    timezone: str = "Asia/Yekaterinburg"

    @model_validator(mode="after")
    def validate_release_management(self) -> ReleaseManagementConfig:
        if not PREFIX_RE.fullmatch(self.prefix):
            raise ValueError("release_management.prefix is invalid")
        try:
            ZoneInfo(self.timezone)
        except ZoneInfoNotFoundError as exc:
            raise ValueError("release_management.timezone is unknown") from exc
        return self


class PublisherVolumeConfig(StrictModel):
    dataset: str
    extent_id: Annotated[int, Field(gt=0)]
    lun: Annotated[int, Field(ge=0, le=16383)]

    @model_validator(mode="after")
    def validate_dataset(self) -> PublisherVolumeConfig:
        self.dataset = self.dataset.rstrip("/")
        if not DATASET_RE.fullmatch(self.dataset) or "@" in self.dataset:
            raise ValueError("publisher volume dataset must be a ZFS dataset path")
        return self


class PublisherConfig(StrictModel):
    source_ip: IPvAnyAddress
    initiator_iqn: str
    target_iqn: str
    volumes: dict[str, PublisherVolumeConfig]

    @model_validator(mode="after")
    def validate_publisher(self) -> PublisherConfig:
        if self.source_ip.version != 4:
            raise ValueError("publisher.source_ip must be IPv4")
        self.initiator_iqn = self.initiator_iqn.lower()
        self.target_iqn = self.target_iqn.lower()
        if not IQN_RE.fullmatch(self.initiator_iqn):
            raise ValueError("invalid publisher.initiator_iqn")
        if not IQN_RE.fullmatch(self.target_iqn):
            raise ValueError("invalid publisher.target_iqn")
        if not self.volumes:
            raise ValueError("publisher must contain at least one volume")
        luns: set[int] = set()
        for name, volume in self.volumes.items():
            if not NAME_RE.fullmatch(name):
                raise ValueError(f"invalid publisher volume name: {name}")
            if volume.lun in luns:
                raise ValueError(f"duplicate publisher LUN: {volume.lun}")
            luns.add(volume.lun)
        return self


class VolumeConfig(StrictModel):
    extent_id: Annotated[int, Field(gt=0)]
    lun: Annotated[int, Field(ge=0, le=16383)]
    drive_letter: Annotated[str, Field(pattern=r"^[D-Zd-z]$")]
    label: Annotated[str, Field(min_length=1, max_length=32)]
    clone_parent: str | None = None
    windows_unique_id_override: str | None = None

    @model_validator(mode="after")
    def normalize(self) -> VolumeConfig:
        self.drive_letter = self.drive_letter.upper()
        if self.clone_parent:
            self.clone_parent = self.clone_parent.rstrip("/")
            if not DATASET_RE.fullmatch(self.clone_parent) or "@" in self.clone_parent:
                raise ValueError("clone_parent must be a ZFS dataset path")
        if self.windows_unique_id_override:
            self.windows_unique_id_override = normalize_disk_id(
                self.windows_unique_id_override
            )
        return self


class ClientConfig(StrictModel):
    source_ip: IPvAnyAddress
    initiator_iqn: str
    target_iqn: str
    token_digest: str
    clone_parent: str | None = None
    volumes: dict[str, VolumeConfig]

    @model_validator(mode="after")
    def validate_client(self) -> ClientConfig:
        if self.source_ip.version != 4:
            raise ValueError("client source_ip must be IPv4")
        self.initiator_iqn = self.initiator_iqn.lower()
        self.target_iqn = self.target_iqn.lower()
        if not IQN_RE.fullmatch(self.initiator_iqn):
            raise ValueError("invalid initiator_iqn")
        if not IQN_RE.fullmatch(self.target_iqn):
            raise ValueError("invalid target_iqn")
        if not TOKEN_DIGEST_RE.fullmatch(self.token_digest):
            raise ValueError("token_digest must be hmac-sha256:<64 lowercase hex chars>")
        if self.clone_parent:
            self.clone_parent = self.clone_parent.rstrip("/")
            if not DATASET_RE.fullmatch(self.clone_parent) or "@" in self.clone_parent:
                raise ValueError("clone_parent must be a ZFS dataset path")
        if not self.volumes:
            raise ValueError("client must contain at least one volume")
        for name, volume in self.volumes.items():
            if not NAME_RE.fullmatch(name):
                raise ValueError(f"invalid client volume name: {name}")
            if not (volume.clone_parent or self.clone_parent):
                raise ValueError(f"volume {name} needs clone_parent")
        return self

    def parent_for(self, volume_name: str) -> str:
        volume = self.volumes[volume_name]
        parent = volume.clone_parent or self.clone_parent
        if parent is None:
            raise RuntimeError(f"missing clone parent for {volume_name}")
        return parent


class ServiceConfig(StrictModel):
    schema_version: Literal[3]
    allowed_source_cidr: str
    portal: PortalConfig
    release_management: ReleaseManagementConfig
    publisher: PublisherConfig
    clients: dict[str, ClientConfig]

    @model_validator(mode="after")
    def validate_relations(self) -> ServiceConfig:
        try:
            network = ipaddress.ip_network(self.allowed_source_cidr, strict=True)
        except ValueError as exc:
            raise ValueError("allowed_source_cidr must be a canonical network") from exc
        if network.version != 4:
            raise ValueError("allowed_source_cidr must be IPv4")
        if self.portal.address not in network:
            raise ValueError("portal address is outside allowed_source_cidr")
        if self.publisher.source_ip not in network:
            raise ValueError("publisher.source_ip is outside allowed_source_cidr")
        if self.publisher.source_ip == self.portal.address:
            raise ValueError("publisher.source_ip uses the portal address")
        if not self.clients:
            raise ValueError("at least one client is required")

        shared_publisher_clients: list[str] = []
        for client_name, client in self.clients.items():
            matches_publisher_ip = client.source_ip == self.publisher.source_ip
            matches_publisher_iqn = (
                client.initiator_iqn == self.publisher.initiator_iqn
            )
            if matches_publisher_ip != matches_publisher_iqn:
                raise ValueError(
                    f"client {client_name} must match both publisher source_ip and "
                    "initiator_iqn, or neither"
                )
            if matches_publisher_ip:
                shared_publisher_clients.append(client_name)
        if len(shared_publisher_clients) > 1:
            raise ValueError(
                "only one client may share publisher source_ip and initiator_iqn"
            )

        seen: dict[str, set[object]] = {
            "source_ip": set(),
            "initiator_iqn": set(),
            "target_iqn": {self.publisher.target_iqn},
            "token_digest": set(),
            "extent_id": {volume.extent_id for volume in self.publisher.volumes.values()},
        }
        if len(seen["extent_id"]) != len(self.publisher.volumes):
            raise ValueError("duplicate publisher extent_id")

        for client_name, client in self.clients.items():
            if not NAME_RE.fullmatch(client_name):
                raise ValueError(f"invalid client name: {client_name}")
            if client.source_ip not in network:
                raise ValueError(f"client {client_name} is outside allowed_source_cidr")
            if client.source_ip == self.portal.address:
                raise ValueError(f"client {client_name} uses the portal address")
            for field in ("source_ip", "initiator_iqn", "target_iqn", "token_digest"):
                value = getattr(client, field)
                if value in seen[field]:
                    raise ValueError(f"duplicate {field}: {value}")
                seen[field].add(value)

            luns: set[int] = set()
            letters: set[str] = set()
            for volume_name, volume in client.volumes.items():
                master = self.publisher.volumes.get(volume_name)
                if master is None:
                    raise ValueError(
                        f"client {client_name} volume {volume_name} has no publisher master"
                    )
                if volume.extent_id in seen["extent_id"]:
                    raise ValueError(f"duplicate extent_id: {volume.extent_id}")
                seen["extent_id"].add(volume.extent_id)
                if volume.lun in luns:
                    raise ValueError(f"duplicate LUN for {client_name}: {volume.lun}")
                luns.add(volume.lun)
                if volume.drive_letter in letters:
                    raise ValueError(
                        f"duplicate drive letter for {client_name}: {volume.drive_letter}"
                    )
                letters.add(volume.drive_letter)
                snapshot_pool = master.dataset.split("/", 1)[0]
                clone_pool = client.parent_for(volume_name).split("/", 1)[0]
                if snapshot_pool != clone_pool:
                    raise ValueError(
                        f"{client_name}/{volume_name} clone_parent must be in pool "
                        f"{snapshot_pool}"
                    )
        return self

    @property
    def network(self) -> ipaddress.IPv4Network:
        return ipaddress.ip_network(self.allowed_source_cidr, strict=True)

    @property
    def shared_publisher_client(self) -> str | None:
        for client_name, client in self.clients.items():
            if (
                client.source_ip == self.publisher.source_ip
                and client.initiator_iqn == self.publisher.initiator_iqn
            ):
                return client_name
        return None

    @property
    def revision(self) -> str:
        payload = json.dumps(
            self.model_dump(mode="json"), sort_keys=True, separators=(",", ":")
        )
        return hashlib.sha256(payload.encode()).hexdigest()[:16]

    def clone_dataset(self, client_name: str, volume_name: str, release_name: str) -> str:
        parent = self.clients[client_name].parent_for(volume_name)
        return f"{parent}/{volume_name}__{release_name}"

    def snapshot_path(self, volume_name: str, release_name: str) -> str:
        return f"{self.publisher.volumes[volume_name].dataset}@{release_name}"


def normalize_disk_id(value: str) -> str:
    normalized = re.sub(r"\s+", "", value).lower()
    return normalized[2:] if normalized.startswith("0x") else normalized


def parse_config_yaml(source: str) -> ServiceConfig:
    try:
        raw = yaml.load(source, Loader=UniqueKeyLoader)
    except yaml.YAMLError as exc:
        problem = getattr(exc, "problem", None) or "invalid YAML"
        raise ValueError(str(problem)) from exc
    if not isinstance(raw, dict):
        raise ValueError("configuration root must be a mapping")
    if raw.get("schema_version") in {1, 2}:
        raise ValueError(
            "schema_version 1 and 2 are unsupported; create a schema_version 3 "
            "configuration without admin_api"
        )
    return ServiceConfig.model_validate(raw)


def dump_config(config: ServiceConfig) -> str:
    return yaml.safe_dump(
        config.model_dump(mode="json"),
        allow_unicode=True,
        default_flow_style=False,
        sort_keys=False,
    )


def load_config(path: str | Path) -> ServiceConfig:
    source = Path(path)
    return parse_config_yaml(source.read_text(encoding="utf-8"))
