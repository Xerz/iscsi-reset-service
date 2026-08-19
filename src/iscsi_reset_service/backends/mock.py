from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

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


class MockBackend(StorageBackend):
    """Deterministic in-memory TrueNAS replacement used by tests and simulations."""

    def __init__(self, state: dict[str, Any] | None = None) -> None:
        state = copy.deepcopy(state or {})
        raw_extents = state.get("extents", {})
        extent_disks = {
            _normalize_zvol(str(value.get("disk", "")))
            for value in raw_extents.values()
        }
        self.snapshots: set[str] = set(state.get("snapshots", []))
        self.datasets: dict[str, DatasetState] = {
            name: DatasetState(
                id=name,
                origin=value.get("origin"),
                user_properties=dict(value.get("user_properties", {})),
                type=str(
                    value.get("type", "VOLUME" if name in extent_disks else "FILESYSTEM")
                ).upper(),
                locked=bool(value.get("locked", False)),
            )
            for name, value in state.get("datasets", {}).items()
        }
        self.extents: dict[int, ExtentState] = {
            int(key): ExtentState(
                id=int(key),
                disk=_normalize_zvol(value["disk"]),
                naa=value["naa"],
                serial=value.get("serial"),
                enabled=bool(value.get("enabled", True)),
                name=str(value.get("name", f"extent-{key}")),
                type=str(value.get("type", "DISK")).upper(),
                locked=value.get("locked", False),
            )
            for key, value in raw_extents.items()
        }
        self.sessions: list[SessionState] = [
            SessionState(**item) for item in state.get("sessions", [])
        ]
        self.luns: dict[str, list[TargetLunState]] = {
            target.lower(): [
                TargetLunState(
                    target_iqn=target.lower(),
                    extent_id=int(item["extent_id"]),
                    lun=int(item["lun"]),
                )
                for item in values
            ]
            for target, values in state.get("target_luns", {}).items()
        }
        discovery = state.get("discovery", {})
        self.basename = str(discovery.get("basename", _infer_basename(self.luns)))
        self.listen_port = int(discovery.get("listen_port", 3260))
        portal_rows = discovery.get(
            "portals",
            [
                {
                    "id": 1,
                    "comment": "mock portal",
                    "listen": [{"address": "10.20.40.10", "port": self.listen_port}],
                }
            ],
        )
        self.portals = [
            PortalState(
                id=int(row["id"]),
                comment=str(row.get("comment", "")),
                listen=tuple(
                    (
                        str(item.get("address", item.get("ip", ""))),
                        int(item.get("port", self.listen_port)),
                    )
                    for item in row.get("listen", [])
                ),
            )
            for row in portal_rows
        ]
        initiator_rows = discovery.get("initiator_groups", [])
        self.initiator_groups = [
            InitiatorGroupState(
                id=int(row["id"]),
                comment=str(row.get("comment", "")),
                initiators=tuple(str(item).lower() for item in row.get("initiators", [])),
            )
            for row in initiator_rows
        ]
        target_rows = discovery.get("targets")
        if target_rows is None:
            target_rows = [
                {
                    "id": index,
                    "iqn": iqn,
                    "alias": iqn.rsplit(":", 1)[-1],
                    "mode": "ISCSI",
                    "portal_ids": [self.portals[0].id] if self.portals else [],
                    "initiator_ids": [],
                    "auth_networks": [],
                }
                for index, iqn in enumerate(sorted(self.luns), start=1)
            ]
        self.targets = [
            TargetState(
                id=int(row["id"]),
                iqn=str(row["iqn"]).lower(),
                alias=str(row["alias"]) if row.get("alias") else None,
                mode=str(row.get("mode", "ISCSI")).upper(),
                portal_ids=tuple(int(item) for item in row.get("portal_ids", [])),
                initiator_ids=tuple(int(item) for item in row.get("initiator_ids", [])),
                auth_networks=tuple(str(item) for item in row.get("auth_networks", [])),
            )
            for row in target_rows
        ]
        target_ids = {item.iqn: item.id for item in self.targets}
        self.associations = [
            TargetExtentState(
                id=index,
                target_id=target_ids[target_iqn],
                target_iqn=target_iqn,
                extent_id=item.extent_id,
                lun=item.lun,
            )
            for index, (target_iqn, item) in enumerate(
                (
                    (target_iqn, item)
                    for target_iqn, items in sorted(self.luns.items())
                    for item in items
                    if target_iqn in target_ids
                ),
                start=1,
            )
        ]
        self.failpoints: dict[str, int] = {
            name: int(count) for name, count in state.get("failpoints", {}).items()
        }
        self.fail_at_calls: dict[str, set[int]] = {
            name: {int(item) for item in calls}
            for name, calls in state.get("fail_at_calls", {}).items()
        }
        self._operation_counts: dict[str, int] = {}
        self.calls: list[str] = []
        self._state_path: Path | None = None

    @classmethod
    def from_file(cls, path: str | Path) -> MockBackend:
        source = Path(path)
        backend = cls(json.loads(source.read_text(encoding="utf-8")))
        backend._state_path = source
        return backend

    def _refresh(self) -> None:
        if self._state_path is None:
            return
        fresh = MockBackend(json.loads(self._state_path.read_text(encoding="utf-8")))
        self.snapshots = fresh.snapshots
        self.datasets = fresh.datasets
        self.extents = fresh.extents
        self.sessions = fresh.sessions
        self.luns = fresh.luns
        self.basename = fresh.basename
        self.listen_port = fresh.listen_port
        self.portals = fresh.portals
        self.initiator_groups = fresh.initiator_groups
        self.targets = fresh.targets
        self.associations = fresh.associations

    def _save(self) -> None:
        if self._state_path is None:
            return
        state = {
            "snapshots": sorted(self.snapshots),
            "datasets": {
                name: {
                    "origin": value.origin,
                    "user_properties": value.user_properties,
                    "type": value.type,
                    "locked": value.locked,
                }
                for name, value in self.datasets.items()
            },
            "extents": {
                str(key): {
                    "disk": value.disk,
                    "naa": value.naa,
                    "serial": value.serial,
                    "enabled": value.enabled,
                    "name": value.name,
                    "type": value.type,
                    "locked": value.locked,
                }
                for key, value in self.extents.items()
            },
            "sessions": [
                {
                    "initiator_iqn": value.initiator_iqn,
                    "initiator_addr": value.initiator_addr,
                    "target_iqn": value.target_iqn,
                }
                for value in self.sessions
            ],
            "target_luns": {
                target: [
                    {"extent_id": value.extent_id, "lun": value.lun}
                    for value in values
                ]
                for target, values in self.luns.items()
            },
            "discovery": {
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
                "initiator_groups": [
                    {
                        "id": item.id,
                        "comment": item.comment,
                        "initiators": list(item.initiators),
                    }
                    for item in self.initiator_groups
                ],
                "targets": [
                    {
                        "id": item.id,
                        "iqn": item.iqn,
                        "alias": item.alias,
                        "portal_ids": list(item.portal_ids),
                        "initiator_ids": list(item.initiator_ids),
                        "auth_networks": list(item.auth_networks),
                    }
                    for item in self.targets
                ],
            },
            "failpoints": self.failpoints,
            "fail_at_calls": {
                name: sorted(values) for name, values in self.fail_at_calls.items()
            },
        }
        temporary = self._state_path.with_suffix(f"{self._state_path.suffix}.tmp")
        temporary.write_text(json.dumps(state, indent=2), encoding="utf-8")
        temporary.replace(self._state_path)

    def _call(self, operation: str) -> None:
        self.calls.append(operation)
        candidates = (operation, operation.split(":", 1)[0])
        for candidate in candidates:
            self._operation_counts[candidate] = self._operation_counts.get(candidate, 0) + 1
            if self._operation_counts[candidate] in self.fail_at_calls.get(candidate, set()):
                raise BackendError(
                    f"mock failpoint: {candidate} call {self._operation_counts[candidate]}"
                )
            remaining = self.failpoints.get(candidate, 0)
            if remaining > 0:
                self.failpoints[candidate] = remaining - 1
                raise BackendError(f"mock failpoint: {candidate}")

    async def ping(self) -> None:
        self._call("ping")

    async def close(self) -> None:
        return None

    async def list_sessions(self) -> list[SessionState]:
        self._refresh()
        self._call("list_sessions")
        return copy.deepcopy(self.sessions)

    async def discover_configuration(self) -> ConfigurationDiscovery:
        self._refresh()
        self._call("discover_configuration")
        return ConfigurationDiscovery(
            basename=self.basename,
            listen_port=self.listen_port,
            portals=copy.deepcopy(self.portals),
            targets=copy.deepcopy(self.targets),
            initiator_groups=copy.deepcopy(self.initiator_groups),
            extents=copy.deepcopy(list(self.extents.values())),
            associations=copy.deepcopy(self.associations),
            datasets=copy.deepcopy(list(self.datasets.values())),
            sessions=copy.deepcopy(self.sessions),
        )

    async def snapshot_exists(self, snapshot: str) -> bool:
        self._refresh()
        self._call(f"snapshot_exists:{snapshot}")
        return snapshot in self.snapshots

    async def dataset(self, dataset: str) -> DatasetState | None:
        self._refresh()
        self._call(f"dataset:{dataset}")
        value = self.datasets.get(dataset)
        return copy.deepcopy(value) if value else None

    async def clone_snapshot(
        self, snapshot: str, destination: str, properties: dict[str, str]
    ) -> None:
        self._refresh()
        self._call(f"clone_snapshot:{destination}")
        if snapshot not in self.snapshots:
            raise BackendError(f"snapshot does not exist: {snapshot}")
        if destination in self.datasets:
            raise BackendError(f"dataset already exists: {destination}")
        self.datasets[destination] = DatasetState(destination, snapshot, dict(properties))
        self._save()

    async def create_snapshot(self, dataset: str, name: str) -> None:
        self._refresh()
        self._call(f"create_snapshot:{dataset}@{name}")
        if dataset not in self.datasets:
            raise BackendError(f"dataset does not exist: {dataset}")
        snapshot = f"{dataset}@{name}"
        if snapshot in self.snapshots:
            raise BackendError(f"snapshot already exists: {snapshot}")
        self.snapshots.add(snapshot)
        self._save()

    async def rollback_snapshot(self, snapshot: str) -> None:
        self._refresh()
        self._call(f"rollback_snapshot:{snapshot}")
        if snapshot not in self.snapshots:
            raise BackendError(f"snapshot does not exist: {snapshot}")

    async def get_extent(self, extent_id: int) -> ExtentState:
        self._refresh()
        self._call(f"get_extent:{extent_id}")
        try:
            return copy.deepcopy(self.extents[extent_id])
        except KeyError as exc:
            raise BackendError(f"extent does not exist: {extent_id}") from exc

    async def update_extent(
        self, extent_id: int, *, enabled: bool | None = None, disk: str | None = None
    ) -> ExtentState:
        self._refresh()
        operation = (
            f"update_extent_disk:{extent_id}" if disk is not None else f"update_extent:{extent_id}"
        )
        self._call(operation)
        if extent_id not in self.extents:
            raise BackendError(f"extent does not exist: {extent_id}")
        extent = self.extents[extent_id]
        if enabled is not None:
            extent.enabled = enabled
        if disk is not None:
            extent.disk = _normalize_zvol(disk)
        self._save()
        return copy.deepcopy(extent)

    async def target_luns(self, target_iqn: str) -> list[TargetLunState]:
        self._refresh()
        self._call(f"target_luns:{target_iqn.lower()}")
        return copy.deepcopy(self.luns.get(target_iqn.lower(), []))

    async def list_datasets(self, prefix: str) -> list[DatasetState]:
        self._refresh()
        self._call(f"list_datasets:{prefix}")
        return [
            copy.deepcopy(value)
            for name, value in self.datasets.items()
            if name == prefix or name.startswith(f"{prefix}/")
        ]


def _normalize_zvol(value: str) -> str:
    return value[5:] if value.startswith("zvol/") else value


def _infer_basename(luns: dict[str, list[TargetLunState]]) -> str:
    if not luns:
        return "iqn.2026-08.mock.games"
    return sorted(luns)[0].rsplit(":", 1)[0]
