from __future__ import annotations

import ipaddress
from datetime import UTC, datetime
from typing import Any

from iscsi_reset_service.backends.base import StorageBackend
from iscsi_reset_service.config import (
    ClientConfig,
    PublisherConfig,
    ServiceConfig,
    normalize_disk_id,
)
from iscsi_reset_service.models import ConfigurationDiscovery, SessionState
from iscsi_reset_service.release_store import ReleaseRecord, ReleaseStore

MANAGED_PROPERTY = "org.openai:iscsi-reset-managed"
CLIENT_PROPERTY = "org.openai:iscsi-reset-client"
VOLUME_PROPERTY = "org.openai:iscsi-reset-volume"
RELEASE_PROPERTY = "org.openai:iscsi-reset-release"


class ManagementInspector:
    """Build a read-only, storage-observed view for the management UI."""

    def __init__(
        self,
        config: ServiceConfig,
        backend: StorageBackend,
        store: ReleaseStore,
    ) -> None:
        self.config = config
        self.backend = backend
        self.store = store

    async def dashboard(
        self,
        *,
        saved_revision: str | None,
        restart_required: bool,
    ) -> dict[str, Any]:
        self.store.check(require_active=False)
        await self.backend.ping()
        discovery = await self.backend.discover_configuration()
        sessions = discovery.sessions
        releases = {item.name: item for item in self.store.list()}
        active = self.store.active_release()

        publisher = await self._publisher(sessions, discovery)
        clients = [
            await self._client(name, client, sessions, releases, active)
            for name, client in sorted(self.config.clients.items())
        ]
        all_updated = active is not None and bool(clients) and all(
            item["update_status"] == "updated" for item in clients
        )
        clone_dependencies = await self._clone_dependencies()
        release_rows = await self._releases(
            releases,
            clients,
            clone_dependencies,
            all_updated,
        )
        incomplete = next(
            (item for item in releases.values() if item.status == "incomplete"),
            None,
        )
        topology_ready = not publisher["errors"]
        disconnected = publisher["connection_status"] == "disconnected"
        extents_ready = publisher["extents_enabled"]
        can_continue = bool(
            incomplete and disconnected and topology_ready and not restart_required
        )
        can_create = bool(
            not incomplete
            and disconnected
            and topology_ready
            and extents_ready
            and not restart_required
        )
        reasons: list[str] = []
        if restart_required:
            reasons.append("saved configuration requires Custom App restart")
        if publisher["connection_status"] == "connected":
            reasons.append("Publisher is connected")
        elif publisher["connection_status"] == "conflict":
            reasons.append("Publisher session identity conflict")
        reasons.extend(publisher["errors"])
        if not extents_ready and incomplete is None:
            reasons.append("publisher extents are disabled")
        if incomplete:
            reasons.append(f"incomplete release must be continued: {incomplete.name}")

        return {
            "schema_version": 1,
            "generated_at": datetime.now(UTC).isoformat(),
            "startup_revision": self.config.revision,
            "saved_revision": saved_revision,
            "restart_required": restart_required,
            "active_release": active.name if active else None,
            "all_clients_updated": all_updated,
            "dependencies": {"truenas": "ok", "sqlite": "ok"},
            "publisher": publisher,
            "clients": clients,
            "releases": release_rows,
            "release_action": {
                "kind": "continue" if incomplete else "create",
                "release": incomplete.name if incomplete else None,
                "can_stage": can_continue if incomplete else can_create,
                "reasons": reasons,
            },
        }

    async def _publisher(
        self,
        sessions: list[SessionState],
        discovery: ConfigurationDiscovery,
    ) -> dict[str, Any]:
        publisher = self.config.publisher
        connection_status, matching = _connection_status(publisher, sessions)
        errors = _publisher_discovery_errors(self.config, discovery)
        actual_luns = {
            (item.extent_id, item.lun)
            for item in await self.backend.target_luns(publisher.target_iqn)
        }
        expected_luns = {
            (item.extent_id, item.lun) for item in publisher.volumes.values()
        }
        if actual_luns != expected_luns:
            errors.append("publisher target-to-LUN mapping mismatch")

        extents_enabled = True
        volumes: list[dict[str, Any]] = []
        for name, volume in sorted(
            publisher.volumes.items(), key=lambda item: item[1].lun
        ):
            extent = await self.backend.get_extent(volume.extent_id)
            volume_errors: list[str] = []
            if extent.disk != volume.dataset:
                volume_errors.append(
                    f"extent points to {extent.disk}, expected {volume.dataset}"
                )
            if not normalize_disk_id(extent.naa):
                volume_errors.append("extent has no NAA")
            if not extent.enabled:
                extents_enabled = False
            errors.extend(f"{name}: {message}" for message in volume_errors)
            volumes.append(
                {
                    "name": name,
                    "extent_id": volume.extent_id,
                    "lun": volume.lun,
                    "dataset": extent.disk,
                    "naa": normalize_disk_id(extent.naa),
                    "serial": extent.serial,
                    "enabled": extent.enabled,
                    "errors": volume_errors,
                }
            )
        return {
            "connection_status": connection_status,
            "matching_sessions": [_session_dict(item) for item in matching],
            "extents_enabled": extents_enabled,
            "topology_valid": not errors,
            "errors": errors,
            "volumes": volumes,
        }

    async def _client(
        self,
        name: str,
        client: ClientConfig,
        sessions: list[SessionState],
        releases: dict[str, ReleaseRecord],
        active: ReleaseRecord | None,
    ) -> dict[str, Any]:
        connection_status, matching = _connection_status(client, sessions)
        errors: list[str] = []
        actual_luns = {
            (item.extent_id, item.lun)
            for item in await self.backend.target_luns(client.target_iqn)
        }
        expected_luns = {(item.extent_id, item.lun) for item in client.volumes.values()}
        if actual_luns != expected_luns:
            errors.append("target-to-LUN mapping mismatch")

        observed_releases: set[str] = set()
        volumes: list[dict[str, Any]] = []
        for volume_name, volume in sorted(
            client.volumes.items(), key=lambda item: item[1].lun
        ):
            extent = await self.backend.get_extent(volume.extent_id)
            dataset = await self.backend.dataset(extent.disk) if extent.disk else None
            volume_errors: list[str] = []
            release_name: str | None = None
            if dataset is None:
                volume_errors.append("extent dataset does not exist")
            else:
                properties = dataset.user_properties
                release_name = properties.get(RELEASE_PROPERTY)
                if release_name:
                    observed_releases.add(release_name)
                expected_properties = {
                    MANAGED_PROPERTY: "yes",
                    CLIENT_PROPERTY: name,
                    VOLUME_PROPERTY: volume_name,
                }
                for key, value in expected_properties.items():
                    if properties.get(key) != value:
                        volume_errors.append(f"managed property mismatch: {key}")
                record = releases.get(release_name or "")
                if record is None:
                    volume_errors.append("clone release is unknown")
                else:
                    expected_origin = record.snapshots.get(volume_name)
                    if dataset.origin != expected_origin:
                        volume_errors.append("clone origin does not match release snapshot")
                if not await self.backend.snapshot_exists(f"{extent.disk}@clean"):
                    volume_errors.append("clone has no @clean snapshot")
            if not extent.enabled:
                volume_errors.append("extent is disabled")
            if volume_errors:
                errors.extend(f"{volume_name}: {message}" for message in volume_errors)
            volumes.append(
                {
                    "name": volume_name,
                    "extent_id": volume.extent_id,
                    "lun": volume.lun,
                    "dataset": extent.disk,
                    "release": release_name,
                    "enabled": extent.enabled,
                    "errors": volume_errors,
                }
            )

        mapped_release = (
            next(iter(observed_releases))
            if not errors and len(observed_releases) == 1
            else None
        )
        if not observed_releases:
            update_status = "unprepared"
        elif errors or len(observed_releases) > 1:
            update_status = "partial"
        elif active and mapped_release == active.name:
            update_status = "updated"
        else:
            update_status = "outdated"
        return {
            "name": name,
            "connection_status": connection_status,
            "matching_sessions": [_session_dict(item) for item in matching],
            "mapped_release": mapped_release,
            "observed_releases": sorted(observed_releases),
            "update_status": update_status,
            "errors": errors,
            "volumes": volumes,
        }

    async def _clone_dependencies(self) -> dict[str, list[str]]:
        parents = {
            client.parent_for(volume_name)
            for client in self.config.clients.values()
            for volume_name in client.volumes
        }
        seen: set[str] = set()
        dependencies: dict[str, list[str]] = {}
        for parent in sorted(parents):
            for dataset in await self.backend.list_datasets(parent):
                if dataset.id in seen:
                    continue
                seen.add(dataset.id)
                if dataset.user_properties.get(MANAGED_PROPERTY) != "yes":
                    continue
                release_name = dataset.user_properties.get(RELEASE_PROPERTY)
                if release_name:
                    dependencies.setdefault(release_name, []).append(dataset.id)
        return dependencies

    async def _releases(
        self,
        releases: dict[str, ReleaseRecord],
        clients: list[dict[str, Any]],
        dependencies: dict[str, list[str]],
        all_updated: bool,
    ) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for record in releases.values():
            snapshots = []
            for volume_name, snapshot in sorted(record.snapshots.items()):
                snapshots.append(
                    {
                        "volume": volume_name,
                        "snapshot": snapshot,
                        "exists": await self.backend.snapshot_exists(snapshot),
                    }
                )
            mapped_clients = sorted(
                item["name"]
                for item in clients
                if record.name in item["observed_releases"]
            )
            unused = bool(
                all_updated
                and not record.active
                and record.status != "incomplete"
                and not mapped_clients
            )
            rows.append(
                {
                    "name": record.name,
                    "status": record.status,
                    "active": record.active,
                    "created_at": record.created_at,
                    "completed_at": record.completed_at,
                    "snapshots": snapshots,
                    "mapped_clients": mapped_clients,
                    "clone_dependencies": sorted(dependencies.get(record.name, [])),
                    "unused_by_current_mappings": unused,
                }
            )
        return rows


def _connection_status(
    identity: PublisherConfig | ClientConfig,
    sessions: list[SessionState],
) -> tuple[str, list[SessionState]]:
    source_ip = str(identity.source_ip)
    iqn = identity.initiator_iqn.lower()
    target = identity.target_iqn.lower()
    matching = [
        item
        for item in sessions
        if item.initiator_addr == source_ip
        or item.initiator_iqn.lower() == iqn
        or item.target_iqn.lower() == target
    ]
    if not matching:
        return "disconnected", []
    if len(matching) == 1:
        item = matching[0]
        exact = (
            item.initiator_addr == source_ip
            and item.initiator_iqn.lower() == iqn
            and item.target_iqn.lower() == target
        )
        if exact:
            return "connected", matching
    return "conflict", matching


def _publisher_discovery_errors(
    config: ServiceConfig,
    discovery: ConfigurationDiscovery,
) -> list[str]:
    publisher = config.publisher
    portals = {item.id: item for item in discovery.portals}
    target = next(
        (item for item in discovery.targets if item.iqn == publisher.target_iqn),
        None,
    )
    if target is None:
        return ["publisher target does not exist in discovery"]

    errors: list[str] = []
    if target.mode not in {"ISCSI", "BOTH"}:
        errors.append("publisher target does not expose iSCSI mode")
    listen = {
        pair
        for portal_id in target.portal_ids
        for pair in portals.get(portal_id, _empty_portal()).listen
    }
    if (str(config.portal.address), config.portal.port) not in listen:
        errors.append("publisher target is not attached to the configured portal")

    initiators = {item.id: item for item in discovery.initiator_groups}
    entries = [
        entry
        for group_id in target.initiator_ids
        for entry in initiators.get(group_id, _empty_initiator()).initiators
    ]
    iqns = {entry.lower() for entry in entries if entry.lower().startswith("iqn.")}
    if publisher.initiator_iqn not in iqns:
        errors.append("publisher target does not authorize the exact initiator IQN")

    networks = [*target.auth_networks]
    networks.extend(entry for entry in entries if not entry.lower().startswith("iqn."))
    expected_network = ipaddress.ip_network(f"{publisher.source_ip}/32")
    parsed_networks = set()
    for value in networks:
        try:
            parsed_networks.add(ipaddress.ip_network(value, strict=False))
        except ValueError:
            continue
    if expected_network not in parsed_networks:
        errors.append("publisher target does not authorize the exact source IP /32")

    associations = {
        (item.extent_id, item.lun)
        for item in discovery.associations
        if item.target_iqn == publisher.target_iqn
    }
    expected_associations = {
        (item.extent_id, item.lun) for item in publisher.volumes.values()
    }
    if associations != expected_associations:
        errors.append("publisher discovery target-to-LUN mapping mismatch")

    extents = {item.id: item for item in discovery.extents}
    datasets = {item.id: item for item in discovery.datasets}
    for name, volume in publisher.volumes.items():
        extent = extents.get(volume.extent_id)
        if (
            extent is None
            or extent.type != "DISK"
            or extent.locked is not False
            or extent.disk != volume.dataset
        ):
            errors.append(f"{name}: discovery extent is not the configured unlocked zvol")
            continue
        dataset = datasets.get(volume.dataset)
        if dataset is None or dataset.type != "VOLUME" or dataset.locked is not False:
            errors.append(f"{name}: master dataset is not an unlocked zvol")
    return errors


def _empty_portal() -> Any:
    class EmptyPortal:
        listen: tuple[tuple[str, int], ...] = ()

    return EmptyPortal()


def _empty_initiator() -> Any:
    class EmptyInitiator:
        initiators: tuple[str, ...] = ()

    return EmptyInitiator()


def _session_dict(session: SessionState) -> dict[str, str]:
    return {
        "initiator_iqn": session.initiator_iqn,
        "initiator_addr": session.initiator_addr,
        "target_iqn": session.target_iqn,
    }
