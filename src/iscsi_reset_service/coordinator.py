from __future__ import annotations

import asyncio
import logging

from iscsi_reset_service.backends.base import BackendError, StorageBackend
from iscsi_reset_service.config import ClientConfig, ServiceConfig, normalize_disk_id
from iscsi_reset_service.errors import (
    ClientBusyError,
    NotReadyError,
    ServiceError,
    SessionActiveError,
)
from iscsi_reset_service.models import (
    ClientResponse,
    ExtentState,
    PortalResponse,
    ValidateResponse,
    VolumeResponse,
)
from iscsi_reset_service.release_store import ReleaseRecord, ReleaseStore, ReleaseStoreError

LOGGER = logging.getLogger("iscsi_reset_service.coordinator")

MANAGED_PROPERTIES = {
    "org.openai:iscsi-reset-managed": "yes",
}


class ResetCoordinator:
    def __init__(
        self, config: ServiceConfig, backend: StorageBackend, store: ReleaseStore
    ) -> None:
        self.config = config
        self.backend = backend
        self.store = store
        self._locks = {name: asyncio.Lock() for name in config.clients}

    async def public_client(self, client_name: str) -> ClientResponse:
        client = self.config.clients[client_name]
        await self._verify_target_luns(client)
        volumes: list[VolumeResponse] = []
        for volume_name, volume in sorted(client.volumes.items(), key=lambda item: item[1].lun):
            extent = await self.backend.get_extent(volume.extent_id)
            disk_id = volume.windows_unique_id_override or normalize_disk_id(extent.naa)
            if not disk_id:
                raise NotReadyError(f"Extent {volume.extent_id} has no stable NAA identifier")
            volumes.append(
                VolumeResponse(
                    name=volume_name,
                    lun=volume.lun,
                    disk_unique_id=disk_id,
                    drive_letter=volume.drive_letter,
                    label=volume.label,
                )
            )
        return ClientResponse(
            portal=PortalResponse(
                address=str(self.config.portal.address), port=self.config.portal.port
            ),
            target_iqn=client.target_iqn,
            volumes=volumes,
        )

    async def validate(self, client_name: str) -> ValidateResponse:
        checks: list[str] = ["configuration loaded"]
        errors: list[str] = []
        client = self.config.clients[client_name]
        try:
            release = self._active_release()
            release_name = release.name
            await self.backend.ping()
            checks.append("TrueNAS API reachable")
            await self._verify_target_luns(client)
            checks.append("target-to-LUN associations match configuration")
            sessions = await self._matching_sessions(client)
            if sessions:
                errors.append("SESSION_ACTIVE")
            else:
                checks.append("no matching iSCSI session")
            for volume_name, volume in client.volumes.items():
                snapshot = release.snapshots[volume_name]
                if not await self.backend.snapshot_exists(snapshot):
                    errors.append(f"missing release snapshot: {snapshot}")
                else:
                    checks.append(f"release snapshot exists: {volume_name}")
                extent = await self.backend.get_extent(volume.extent_id)
                if not (volume.windows_unique_id_override or normalize_disk_id(extent.naa)):
                    errors.append(f"extent {volume.extent_id} has no NAA")
                desired = self.config.clone_dataset(client_name, volume_name, release_name)
                existing = await self.backend.dataset(desired)
                if existing:
                    self._verify_clone(
                        existing.origin,
                        existing.user_properties,
                        client_name,
                        volume_name,
                        release_name,
                        snapshot,
                    )
                    if not await self.backend.snapshot_exists(f"{desired}@clean"):
                        errors.append(f"existing clone has no @clean: {desired}")
                    else:
                        checks.append(f"existing clone is reusable: {volume_name}")
        except ServiceError as exc:
            errors.append(exc.code)
        except (BackendError, ReleaseStoreError, ValueError) as exc:
            errors.append(str(exc))
        return ValidateResponse(ready=not errors, checks=checks, errors=errors)

    async def prepare(self, client_name: str) -> ClientResponse:
        lock = self._locks[client_name]
        if lock.locked():
            raise ClientBusyError()
        await lock.acquire()
        mutation_started = False
        client = self.config.clients[client_name]
        try:
            await self._require_no_session(client)
            await self._verify_target_luns(client)
            original_extents = await self._get_extents(client)

            mutation_started = True
            await self._set_all_enabled(client, False)
            await self._verify_all_enabled(client, False)
            await self._require_no_session(client)

            release = self._active_release()
            release_name = release.name
            desired_paths: dict[str, str] = {}
            for volume_name in client.volumes:
                snapshot = release.snapshots[volume_name]
                desired = self.config.clone_dataset(client_name, volume_name, release_name)
                desired_paths[volume_name] = desired
                await self._ensure_release_clone(
                    client_name, volume_name, release_name, snapshot, desired
                )

            for volume_name, volume in client.volumes.items():
                before = original_extents[volume_name]
                updated = await self.backend.update_extent(
                    volume.extent_id, enabled=False, disk=desired_paths[volume_name]
                )
                if normalize_disk_id(updated.naa) != normalize_disk_id(before.naa):
                    raise NotReadyError(f"NAA changed while updating extent {volume.extent_id}")
                if updated.serial != before.serial:
                    raise NotReadyError(f"serial changed while updating extent {volume.extent_id}")
                if updated.disk != desired_paths[volume_name] or updated.enabled:
                    raise NotReadyError(f"extent {volume.extent_id} did not accept the new zvol")

            for volume_name in client.volumes:
                await self.backend.rollback_snapshot(f"{desired_paths[volume_name]}@clean")

            await self._verify_target_luns(client)
            await self._set_all_enabled(client, True)
            await self._verify_final_extents(client, desired_paths, original_extents)
            if await self._matching_sessions(client):
                await self._best_effort_disable(client)
                raise SessionActiveError()

            LOGGER.info(
                "client_ready client=%s release=%s config_revision=%s",
                client_name,
                release_name,
                self.config.revision,
            )
            return await self.public_client(client_name)
        except ServiceError:
            if mutation_started:
                await self._best_effort_disable(client)
            raise
        except Exception as exc:
            LOGGER.exception("prepare_failed client=%s", client_name)
            if mutation_started:
                await self._best_effort_disable(client)
            if isinstance(exc, BackendError):
                raise NotReadyError(str(exc)) from exc
            raise NotReadyError() from exc
        finally:
            lock.release()

    async def _ensure_release_clone(
        self,
        client_name: str,
        volume_name: str,
        release_name: str,
        source_snapshot: str,
        destination: str,
    ) -> None:
        if not await self.backend.snapshot_exists(source_snapshot):
            raise NotReadyError(f"Release snapshot does not exist: {source_snapshot}")
        properties = {
            **MANAGED_PROPERTIES,
            "org.openai:iscsi-reset-client": client_name,
            "org.openai:iscsi-reset-volume": volume_name,
            "org.openai:iscsi-reset-release": release_name,
        }
        existing = await self.backend.dataset(destination)
        if existing is None:
            await self.backend.clone_snapshot(source_snapshot, destination, properties)
            existing = await self.backend.dataset(destination)
            if existing is None:
                raise NotReadyError(f"Clone was not created: {destination}")
        self._verify_clone(
            existing.origin,
            existing.user_properties,
            client_name,
            volume_name,
            release_name,
            source_snapshot,
        )
        clean = f"{destination}@clean"
        if not await self.backend.snapshot_exists(clean):
            await self.backend.create_snapshot(destination, "clean")
        if not await self.backend.snapshot_exists(clean):
            raise NotReadyError(f"Clean snapshot was not created: {clean}")

    @staticmethod
    def _verify_clone(
        origin: str | None,
        properties: dict[str, str],
        client_name: str,
        volume_name: str,
        release_name: str,
        source_snapshot: str,
    ) -> None:
        expected = {
            **MANAGED_PROPERTIES,
            "org.openai:iscsi-reset-client": client_name,
            "org.openai:iscsi-reset-volume": volume_name,
            "org.openai:iscsi-reset-release": release_name,
        }
        if origin != source_snapshot:
            raise NotReadyError(f"Existing clone origin mismatch for {client_name}/{volume_name}")
        for key, value in expected.items():
            if properties.get(key) != value:
                raise NotReadyError(f"Existing clone property mismatch: {key}")

    async def _get_extents(self, client: ClientConfig) -> dict[str, ExtentState]:
        return {
            name: await self.backend.get_extent(volume.extent_id)
            for name, volume in client.volumes.items()
        }

    async def _set_all_enabled(self, client: ClientConfig, enabled: bool) -> None:
        for volume in client.volumes.values():
            await self.backend.update_extent(volume.extent_id, enabled=enabled)

    async def _best_effort_disable(self, client: ClientConfig) -> None:
        for volume in client.volumes.values():
            try:
                await self.backend.update_extent(volume.extent_id, enabled=False)
            except Exception:
                LOGGER.exception("failed_to_disable_extent extent_id=%s", volume.extent_id)

    async def _verify_all_enabled(self, client: ClientConfig, enabled: bool) -> None:
        for volume in client.volumes.values():
            extent = await self.backend.get_extent(volume.extent_id)
            if extent.enabled is not enabled:
                raise NotReadyError(
                    f"extent {volume.extent_id} enabled={extent.enabled}, expected {enabled}"
                )

    async def _verify_final_extents(
        self,
        client: ClientConfig,
        desired_paths: dict[str, str],
        originals: dict[str, ExtentState],
    ) -> None:
        for volume_name, volume in client.volumes.items():
            extent = await self.backend.get_extent(volume.extent_id)
            if not extent.enabled or extent.disk != desired_paths[volume_name]:
                raise NotReadyError(f"extent {volume.extent_id} is not ready")
            if normalize_disk_id(extent.naa) != normalize_disk_id(originals[volume_name].naa):
                raise NotReadyError(f"extent {volume.extent_id} NAA changed")
            if extent.serial != originals[volume_name].serial:
                raise NotReadyError(f"extent {volume.extent_id} serial changed")

    async def _matching_sessions(self, client: ClientConfig) -> list[object]:
        matches = []
        for session in await self.backend.list_sessions():
            if (
                session.initiator_iqn.lower() == client.initiator_iqn
                or session.initiator_addr == str(client.source_ip)
                or session.target_iqn.lower() == client.target_iqn
            ):
                matches.append(session)
        return matches

    async def _require_no_session(self, client: ClientConfig) -> None:
        if await self._matching_sessions(client):
            raise SessionActiveError()

    async def _verify_target_luns(self, client: ClientConfig) -> None:
        actual = {
            (item.extent_id, item.lun) for item in await self.backend.target_luns(client.target_iqn)
        }
        expected = {(item.extent_id, item.lun) for item in client.volumes.values()}
        if actual != expected:
            raise NotReadyError(f"Target-to-LUN mapping mismatch for {client.target_iqn}")

    async def audit_stale_clones(self) -> list[str]:
        release_name = self._active_release().name
        desired: set[str] = set()
        attached: set[str] = set()
        prefixes: set[str] = set()
        for client_name, client in self.config.clients.items():
            for volume_name, volume in client.volumes.items():
                prefixes.add(client.parent_for(volume_name))
                desired.add(self.config.clone_dataset(client_name, volume_name, release_name))
                attached.add((await self.backend.get_extent(volume.extent_id)).disk)
        datasets = []
        for prefix in prefixes:
            datasets.extend(await self.backend.list_datasets(prefix))
        return sorted(
            {
                item.id
                for item in datasets
                if item.user_properties.get("org.openai:iscsi-reset-managed") == "yes"
                and item.id not in desired
                and item.id not in attached
            }
        )

    def _active_release(self) -> ReleaseRecord:
        try:
            release = self.store.active_release()
        except ReleaseStoreError as exc:
            raise NotReadyError(str(exc)) from exc
        if release is None:
            raise NotReadyError("No active release has been published")
        if release.status != "staged":
            raise NotReadyError(f"Active release is not staged: {release.name}")
        expected = set(self.config.publisher.volumes)
        if set(release.snapshots) != expected:
            raise NotReadyError(f"Active release volume set is incomplete: {release.name}")
        for volume_name, snapshot in release.snapshots.items():
            if snapshot != self.config.snapshot_path(volume_name, release.name):
                raise NotReadyError(
                    f"Active release snapshot mapping is invalid: {release.name}/{volume_name}"
                )
        return release
