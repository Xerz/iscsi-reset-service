from __future__ import annotations

import asyncio
import json
import ssl
import uuid
from typing import Any

from websockets.asyncio.client import ClientConnection, connect

from iscsi_reset_service.backends.base import BackendError, StorageBackend
from iscsi_reset_service.models import (
    ConfigurationDiscovery,
    DatasetState,
    ExtentState,
    InitiatorGroupState,
    PortalState,
    SessionState,
    TargetExtentState,
    TargetLunState,
    TargetState,
)


class TrueNASRpcClient:
    def __init__(
        self,
        url: str,
        username: str,
        api_key: str,
        *,
        tls_verify: bool,
        insecure_ack: str | None,
        timeout: float = 30.0,
    ) -> None:
        if not url.startswith("wss://"):
            raise ValueError("TrueNAS API URL must use wss://")
        if not tls_verify and insecure_ack != "I_ACCEPT_MITM_RISK":
            raise ValueError(
                "TRUENAS_TLS_INSECURE_ACK=I_ACCEPT_MITM_RISK is required "
                "when TLS verification is off"
            )
        self.url = url
        self.username = username
        self.api_key = api_key
        self.timeout = timeout
        self.ssl_context = ssl.create_default_context()
        if not tls_verify:
            self.ssl_context.check_hostname = False
            self.ssl_context.verify_mode = ssl.CERT_NONE
        self._connection: ClientConnection | None = None
        self._lock = asyncio.Lock()

    async def close(self) -> None:
        if self._connection is not None:
            await self._connection.close()
            self._connection = None

    async def _open(self) -> ClientConnection:
        connection = await connect(
            self.url,
            ssl=self.ssl_context,
            open_timeout=self.timeout,
            close_timeout=5,
            ping_interval=20,
            ping_timeout=20,
            max_size=8 * 1024 * 1024,
        )
        self._connection = connection
        response = await self._exchange(
            connection,
            "auth.login_ex",
            [
                {
                    "mechanism": "API_KEY_PLAIN",
                    "username": self.username,
                    "api_key": self.api_key,
                }
            ],
        )
        if not isinstance(response, dict) or response.get("response_type") != "SUCCESS":
            await self.close()
            raise BackendError("TrueNAS API authentication failed")
        return connection

    async def _exchange(
        self, connection: ClientConnection, method: str, params: list[Any]
    ) -> Any:
        request_id = str(uuid.uuid4())
        request = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        await asyncio.wait_for(connection.send(json.dumps(request)), self.timeout)
        while True:
            raw = await asyncio.wait_for(connection.recv(), self.timeout)
            message = json.loads(raw)
            if message.get("id") != request_id:
                continue
            if "error" in message:
                error = message["error"]
                raise BackendError(
                    f"TrueNAS method {method} failed: {error.get('message', 'unknown error')}"
                )
            return message.get("result")

    async def call(self, method: str, params: list[Any] | None = None) -> Any:
        async with self._lock:
            params = params or []
            for attempt in range(2):
                try:
                    connection = self._connection or await self._open()
                    return await self._exchange(connection, method, params)
                except BackendError:
                    raise
                except Exception as exc:
                    await self.close()
                    if attempt == 1:
                        raise BackendError(f"TrueNAS connection failed during {method}") from exc
            raise AssertionError("unreachable")


class TrueNASBackend(StorageBackend):
    def __init__(self, rpc: TrueNASRpcClient) -> None:
        self.rpc = rpc

    async def ping(self) -> None:
        await self.rpc.call("core.ping")

    async def close(self) -> None:
        await self.rpc.close()

    async def list_sessions(self) -> list[SessionState]:
        rows = await self.rpc.call("iscsi.global.sessions", [[], {}])
        sessions: list[SessionState] = []
        for row in rows:
            sessions.append(
                SessionState(
                    initiator_iqn=str(row.get("initiator", "")).lower(),
                    initiator_addr=str(row.get("initiator_addr", "")).split(":", 1)[0],
                    target_iqn=str(row.get("target", "")).lower(),
                )
            )
        return sessions

    async def discover_configuration(self) -> ConfigurationDiscovery:
        global_config = await self.rpc.call("iscsi.global.config")
        basename = str(global_config.get("basename", "")).lower().rstrip(":")
        listen_port = int(global_config.get("listen_port", 3260))
        portal_rows = await self.rpc.call("iscsi.portal.query", [[], {}])
        target_rows = await self.rpc.call("iscsi.target.query", [[], {}])
        extent_rows = await self.rpc.call(
            "iscsi.extent.query",
            [[], {"extra": {"retrieve_locked_info": True}}],
        )
        association_rows = await self.rpc.call("iscsi.targetextent.query", [[], {}])
        initiator_rows = await self.rpc.call("iscsi.initiator.query", [[], {}])
        dataset_rows = await self.rpc.call(
            "pool.dataset.query",
            [
                [],
                {
                    "extra": {
                        "flat": True,
                        "retrieve_children": True,
                        "properties": ["keystatus"],
                        "retrieve_user_props": False,
                    }
                },
            ],
        )

        portals = [
            PortalState(
                id=int(row["id"]),
                comment=str(row.get("comment", "")),
                listen=tuple(
                    (
                        str(item.get("ip", "")),
                        int(item.get("port", listen_port)),
                    )
                    for item in row.get("listen", [])
                    if item.get("ip")
                ),
            )
            for row in portal_rows
        ]
        initiator_groups = [
            InitiatorGroupState(
                id=int(row["id"]),
                comment=str(row.get("comment", "")),
                initiators=tuple(str(item).lower() for item in row.get("initiators", [])),
            )
            for row in initiator_rows
        ]
        targets: list[TargetState] = []
        target_iqns: dict[int, str] = {}
        for row in target_rows:
            target_id = int(row["id"])
            iqn = _full_iqn(basename, str(row.get("name", "")))
            target_iqns[target_id] = iqn
            groups = row.get("groups", []) or []
            targets.append(
                TargetState(
                    id=target_id,
                    iqn=iqn,
                    alias=str(row["alias"]) if row.get("alias") else None,
                    mode=str(row.get("mode", "ISCSI")).upper(),
                    portal_ids=tuple(
                        sorted({int(group["portal"]) for group in groups})
                    ),
                    initiator_ids=tuple(
                        sorted(
                            {
                                int(group["initiator"])
                                for group in groups
                                if group.get("initiator") is not None
                            }
                        )
                    ),
                    auth_networks=tuple(
                        sorted(
                            {
                                str(network)
                                for group in groups
                                for network in group.get("auth_networks", [])
                            }
                        )
                    ),
                )
            )
        associations = [
            TargetExtentState(
                id=int(row["id"]),
                target_id=int(row["target"]),
                target_iqn=target_iqns.get(int(row["target"]), ""),
                extent_id=int(row["extent"]),
                lun=int(row["lunid"]),
            )
            for row in association_rows
            if int(row["target"]) in target_iqns
        ]
        return ConfigurationDiscovery(
            basename=basename,
            listen_port=listen_port,
            portals=portals,
            targets=targets,
            initiator_groups=initiator_groups,
            extents=[_extent_state(row) for row in extent_rows],
            associations=associations,
            datasets=[_dataset_state(row) for row in dataset_rows],
            sessions=await self.list_sessions(),
        )

    async def snapshot_exists(self, snapshot: str) -> bool:
        rows = await self.rpc.call(
            "pool.snapshot.query", [[[
                "id", "=", snapshot
            ]], {"select": ["id"], "limit": 1}]
        )
        return bool(rows)

    async def dataset(self, dataset: str) -> DatasetState | None:
        rows = await self.rpc.call(
            "pool.dataset.query",
            [
                [["id", "=", dataset]],
                {
                    "extra": {
                        "flat": True,
                        "retrieve_children": False,
                        "properties": ["origin"],
                        "retrieve_user_props": True,
                    },
                    "limit": 1,
                },
            ],
        )
        if not rows:
            return None
        return _dataset_state(rows[0])

    async def clone_snapshot(
        self, snapshot: str, destination: str, properties: dict[str, str]
    ) -> None:
        await self.rpc.call(
            "pool.snapshot.clone",
            [{"snapshot": snapshot, "dataset_dst": destination, "dataset_properties": properties}],
        )

    async def create_snapshot(self, dataset: str, name: str) -> None:
        await self.rpc.call(
            "pool.snapshot.create",
            [{"dataset": dataset, "name": name, "recursive": False, "vmware_sync": False}],
        )

    async def rollback_snapshot(self, snapshot: str) -> None:
        await self.rpc.call(
            "pool.snapshot.rollback",
            [
                snapshot,
                {
                    "recursive": False,
                    "recursive_clones": False,
                    "force": False,
                    "recursive_rollback": False,
                },
            ],
        )

    async def get_extent(self, extent_id: int) -> ExtentState:
        try:
            row = await self.rpc.call("iscsi.extent.get_instance", [extent_id, {}])
        except BackendError as exc:
            raise BackendError(f"extent does not exist: {extent_id}") from exc
        return _extent_state(row)

    async def update_extent(
        self, extent_id: int, *, enabled: bool | None = None, disk: str | None = None
    ) -> ExtentState:
        changes: dict[str, Any] = {}
        if enabled is not None:
            changes["enabled"] = enabled
        if disk is not None:
            changes["type"] = "DISK"
            changes["disk"] = f"zvol/{_normalize_zvol(disk)}"
        row = await self.rpc.call("iscsi.extent.update", [extent_id, changes])
        return _extent_state(row)

    async def target_luns(self, target_iqn: str) -> list[TargetLunState]:
        global_config = await self.rpc.call("iscsi.global.config")
        basename = str(global_config.get("basename", "")).lower().rstrip(":")
        targets = await self.rpc.call("iscsi.target.query", [[], {}])
        target = None
        for row in targets:
            name = str(row.get("name", "")).lower()
            full_name = name if name.startswith("iqn.") else f"{basename}:{name}"
            if full_name == target_iqn.lower():
                target = row
                break
        if target is None:
            raise BackendError(f"target does not exist: {target_iqn}")
        associations = await self.rpc.call(
            "iscsi.targetextent.query", [[[
                "target", "=", int(target["id"])
            ]], {}]
        )
        return [
            TargetLunState(
                target_iqn=target_iqn.lower(),
                extent_id=int(row["extent"]),
                lun=int(row["lunid"]),
            )
            for row in associations
        ]

    async def list_datasets(self, prefix: str) -> list[DatasetState]:
        rows = await self.rpc.call(
            "pool.dataset.query",
            [
                [["id", "^", prefix]],
                {
                    "extra": {
                        "flat": True,
                        "retrieve_children": True,
                        "properties": ["origin"],
                        "retrieve_user_props": True,
                    }
                },
            ],
        )
        return [_dataset_state(row) for row in rows]


def _normalize_zvol(value: str | None) -> str:
    value = value or ""
    return value[5:] if value.startswith("zvol/") else value


def _extent_state(row: dict[str, Any]) -> ExtentState:
    return ExtentState(
        id=int(row["id"]),
        disk=_normalize_zvol(row.get("disk")),
        naa=str(row.get("naa", "")),
        serial=str(row["serial"]) if row.get("serial") is not None else None,
        enabled=bool(row.get("enabled", False)),
        name=str(row.get("name", "")),
        type=str(row.get("type", "DISK")).upper(),
        locked=(bool(row["locked"]) if row.get("locked") is not None else None),
    )


def _property_value(value: Any) -> str | None:
    if isinstance(value, dict):
        raw = value.get("rawvalue", value.get("value"))
        return str(raw) if raw not in (None, "-") else None
    return str(value) if value not in (None, "-") else None


def _dataset_state(row: dict[str, Any]) -> DatasetState:
    properties = row.get("properties", {}) or {}
    origin = _property_value(properties.get("origin", row.get("origin")))
    user_properties: dict[str, str] = {}
    for key, value in row.items():
        if ":" in key:
            parsed = _property_value(value)
            if parsed is not None:
                user_properties[key] = parsed
    for key, value in properties.items():
        if ":" in key:
            parsed = _property_value(value)
            if parsed is not None:
                user_properties[key] = parsed

    # User-defined ZFS properties have appeared as both a mapping and a list
    # in TrueNAS dataset responses. Accept either representation and verify
    # the exact values later in the coordinator.
    raw_user_properties = row.get("user_properties", {}) or {}
    if isinstance(raw_user_properties, dict):
        for key, value in raw_user_properties.items():
            parsed = _property_value(value)
            if parsed is not None:
                user_properties[str(key)] = parsed
    elif isinstance(raw_user_properties, list):
        for item in raw_user_properties:
            if not isinstance(item, dict):
                continue
            key = item.get("key") or item.get("name")
            parsed = _property_value(item)
            if key is not None and parsed is not None:
                user_properties[str(key)] = parsed
    return DatasetState(
        id=str(row["id"]),
        origin=origin,
        user_properties=user_properties,
        type=str(row.get("type", "FILESYSTEM")).upper(),
        locked=(bool(row["locked"]) if row.get("locked") is not None else None),
    )


def _full_iqn(basename: str, name: str) -> str:
    normalized = name.lower().strip()
    return normalized if normalized.startswith("iqn.") else f"{basename}:{normalized}"
