from __future__ import annotations

import asyncio
import logging
from datetime import datetime
from zoneinfo import ZoneInfo

from iscsi_reset_service.backends.base import BackendError, StorageBackend
from iscsi_reset_service.config import ServiceConfig, normalize_disk_id
from iscsi_reset_service.errors import (
    NotReadyError,
    PublisherSessionActiveError,
    ReleaseBusyError,
    ReleaseConflictError,
    ServiceError,
)
from iscsi_reset_service.models import (
    PortalResponse,
    PublisherResponse,
    PublisherVolumeResponse,
    ReleaseActivateResponse,
    ReleaseListResponse,
    ReleaseResponse,
    ReleaseStageResponse,
    ReleaseValidateResponse,
)
from iscsi_reset_service.release_store import ReleaseRecord, ReleaseStore, ReleaseStoreError

LOGGER = logging.getLogger("iscsi_reset_service.release_manager")


class ReleaseManager:
    def __init__(
        self, config: ServiceConfig, backend: StorageBackend, store: ReleaseStore
    ) -> None:
        self.config = config
        self.backend = backend
        self.store = store
        self._lock = asyncio.Lock()

    async def publisher_configuration(self) -> PublisherResponse:
        extents = await self._publisher_extents()
        await self._verify_target_luns()
        volumes = []
        for name, volume in sorted(
            self.config.publisher.volumes.items(), key=lambda item: item[1].lun
        ):
            disk_id = normalize_disk_id(extents[name].naa)
            if not disk_id:
                raise NotReadyError(f"Publisher extent {volume.extent_id} has no NAA")
            volumes.append(
                PublisherVolumeResponse(
                    name=name, lun=volume.lun, disk_unique_id=disk_id
                )
            )
        return PublisherResponse(
            portal=PortalResponse(
                address=str(self.config.portal.address), port=self.config.portal.port
            ),
            target_iqn=self.config.publisher.target_iqn,
            volumes=volumes,
        )

    async def validate(self) -> ReleaseValidateResponse:
        checks: list[str] = ["configuration loaded", "release database loaded"]
        errors: list[str] = []
        try:
            self.store.check(require_active=False)
            await self.backend.ping()
            checks.append("TrueNAS API reachable")
            await self._verify_target_luns()
            checks.append("publisher target-to-LUN associations match")
            await self._publisher_extents()
            checks.append("publisher extent paths and identifiers match")
            if await self._matching_sessions():
                errors.append("PUBLISHER_SESSION_ACTIVE")
            else:
                checks.append("publisher has no active iSCSI session")
            active = self.store.active_release()
            if active is None:
                checks.append("no active release yet; first publication is required")
            else:
                for volume_name, snapshot in active.snapshots.items():
                    if not await self.backend.snapshot_exists(snapshot):
                        errors.append(f"missing active snapshot: {volume_name}")
                if not errors:
                    checks.append(f"active release is complete: {active.name}")
        except (BackendError, ReleaseStoreError, ServiceError) as exc:
            errors.append(str(exc))
        return ReleaseValidateResponse(ready=not errors, checks=checks, errors=errors)

    def list_releases(self) -> ReleaseListResponse:
        releases = [self._response(item) for item in self.store.list()]
        active = next((item.name for item in releases if item.active), None)
        return ReleaseListResponse(active_release=active, releases=releases)

    async def stage(self, request_id: str, source_ip: str) -> ReleaseStageResponse:
        if self._lock.locked():
            raise ReleaseBusyError()
        await self._lock.acquire()
        mutation_started = False
        release_name: str | None = None
        try:
            existing = self.store.by_request_id(request_id)
            if existing and existing.status == "staged":
                return self._stage_response(existing)

            await self._require_no_session()
            await self._verify_target_luns()
            originals = await self._publisher_extents()

            mutation_started = True
            await self._set_all_enabled(False)
            await self._verify_enabled(False)
            await self._require_no_session()

            if existing is None:
                release_name = await self._next_release_name()
                existing = self.store.reserve(release_name, request_id)
            else:
                release_name = existing.name

            expected_snapshots = {
                name: self.config.snapshot_path(name, release_name)
                for name in self.config.publisher.volumes
            }
            for volume_name, snapshot in expected_snapshots.items():
                recorded = existing.snapshots.get(volume_name)
                if recorded is not None and recorded != snapshot:
                    raise NotReadyError(
                        f"Immutable snapshot mapping mismatch for {release_name}/{volume_name}"
                    )
                if not await self.backend.snapshot_exists(snapshot):
                    master = self.config.publisher.volumes[volume_name]
                    await self.backend.create_snapshot(master.dataset, release_name)
                if not await self.backend.snapshot_exists(snapshot):
                    raise NotReadyError(f"Snapshot was not created: {snapshot}")
                self.store.add_snapshot(release_name, volume_name, snapshot)
                existing = self.store.get(release_name)

            if existing.snapshots != expected_snapshots:
                raise NotReadyError(f"Release snapshot set is incomplete: {release_name}")

            await self._verify_target_luns()
            await self._set_all_enabled(True)
            await self._verify_final_extents(originals)
            if await self._matching_sessions():
                await self._best_effort_disable()
                raise PublisherSessionActiveError()

            staged = self.store.mark_staged(
                release_name, set(self.config.publisher.volumes)
            )
            self._audit(
                request_id=request_id,
                action="stage",
                result="success",
                release_name=release_name,
                source_ip=source_ip,
            )
            LOGGER.info(
                "release_staged release=%s request_id=%s config_revision=%s",
                release_name,
                request_id,
                self.config.revision,
            )
            return self._stage_response(staged)
        except ServiceError as exc:
            if mutation_started:
                await self._best_effort_disable()
            self._audit_failure(request_id, "stage", release_name, source_ip, exc)
            raise
        except ReleaseStoreError as exc:
            if mutation_started:
                await self._best_effort_disable()
            self._audit_failure(request_id, "stage", release_name, source_ip, exc)
            if "incomplete release" in str(exc):
                raise ReleaseConflictError("RELEASE_INCOMPLETE", str(exc)) from exc
            raise NotReadyError(str(exc)) from exc
        except Exception as exc:
            LOGGER.exception("release_stage_failed release=%s", release_name)
            if mutation_started:
                await self._best_effort_disable()
            self._audit_failure(request_id, "stage", release_name, source_ip, exc)
            if isinstance(exc, BackendError):
                raise NotReadyError(str(exc)) from exc
            raise NotReadyError() from exc
        finally:
            self._lock.release()

    async def activate(
        self, release_name: str, confirmation: str, request_id: str, source_ip: str
    ) -> ReleaseActivateResponse:
        if confirmation != f"ACTIVATE {release_name}":
            raise ReleaseConflictError(
                "CONFIRMATION_MISMATCH",
                f"Confirmation must be exactly: ACTIVATE {release_name}",
            )
        if self._lock.locked():
            raise ReleaseBusyError()
        await self._lock.acquire()
        try:
            record = self.store.get(release_name)
            expected = set(self.config.publisher.volumes)
            if record.status != "staged" or set(record.snapshots) != expected:
                raise ReleaseConflictError(
                    "RELEASE_NOT_STAGED", f"Release is not complete and staged: {release_name}"
                )
            for snapshot in record.snapshots.values():
                if not await self.backend.snapshot_exists(snapshot):
                    raise NotReadyError(f"Release snapshot does not exist: {snapshot}")
            await self._require_no_session()
            await self._verify_target_luns()
            await self._publisher_extents()
            await self._verify_enabled(True)
            activated = self.store.activate(release_name, request_id)
            self._audit(
                request_id=request_id,
                action="activate",
                result="success",
                release_name=release_name,
                source_ip=source_ip,
            )
            LOGGER.info("release_activated release=%s request_id=%s", release_name, request_id)
            return ReleaseActivateResponse(release=activated.name)
        except ReleaseStoreError as exc:
            self._audit_failure(request_id, "activate", release_name, source_ip, exc)
            raise ReleaseConflictError("RELEASE_CONFLICT", str(exc)) from exc
        finally:
            self._lock.release()

    async def _next_release_name(self) -> str:
        local_now = datetime.now(ZoneInfo(self.config.release_management.timezone))
        date_part = local_now.strftime("%Y.%m.%d")
        prefix = self.config.release_management.prefix
        known = {item.name for item in self.store.list()}
        sequence = 1
        while True:
            candidate = f"{prefix}-{date_part}.{sequence}"
            if candidate not in known:
                collisions = [
                    await self.backend.snapshot_exists(
                        self.config.snapshot_path(volume_name, candidate)
                    )
                    for volume_name in self.config.publisher.volumes
                ]
                if not any(collisions):
                    return candidate
            sequence += 1

    async def _publisher_extents(self):
        extents = {}
        for name, volume in self.config.publisher.volumes.items():
            extent = await self.backend.get_extent(volume.extent_id)
            if extent.disk != volume.dataset:
                raise NotReadyError(
                    f"Publisher extent {volume.extent_id} points to {extent.disk}, "
                    f"expected {volume.dataset}"
                )
            if not normalize_disk_id(extent.naa):
                raise NotReadyError(f"Publisher extent {volume.extent_id} has no NAA")
            extents[name] = extent
        return extents

    async def _verify_target_luns(self) -> None:
        actual = {
            (item.extent_id, item.lun)
            for item in await self.backend.target_luns(self.config.publisher.target_iqn)
        }
        expected = {
            (item.extent_id, item.lun)
            for item in self.config.publisher.volumes.values()
        }
        if actual != expected:
            raise NotReadyError(
                f"Publisher target-to-LUN mapping mismatch for "
                f"{self.config.publisher.target_iqn}"
            )

    async def _matching_sessions(self) -> list[object]:
        publisher = self.config.publisher
        return [
            session
            for session in await self.backend.list_sessions()
            if session.initiator_iqn.lower() == publisher.initiator_iqn
            or session.initiator_addr == str(publisher.source_ip)
            or session.target_iqn.lower() == publisher.target_iqn
        ]

    async def _require_no_session(self) -> None:
        if await self._matching_sessions():
            raise PublisherSessionActiveError()

    async def _set_all_enabled(self, enabled: bool) -> None:
        for volume in self.config.publisher.volumes.values():
            await self.backend.update_extent(volume.extent_id, enabled=enabled)

    async def _verify_enabled(self, enabled: bool) -> None:
        for volume in self.config.publisher.volumes.values():
            extent = await self.backend.get_extent(volume.extent_id)
            if extent.enabled is not enabled:
                raise NotReadyError(
                    f"Publisher extent {volume.extent_id} enabled={extent.enabled}, "
                    f"expected {enabled}"
                )

    async def _verify_final_extents(self, originals: dict[str, object]) -> None:
        await self._verify_enabled(True)
        for name, volume in self.config.publisher.volumes.items():
            extent = await self.backend.get_extent(volume.extent_id)
            before = originals[name]
            if extent.disk != volume.dataset:
                raise NotReadyError(f"Publisher extent {volume.extent_id} path changed")
            if normalize_disk_id(extent.naa) != normalize_disk_id(before.naa):
                raise NotReadyError(f"Publisher extent {volume.extent_id} NAA changed")
            if extent.serial != before.serial:
                raise NotReadyError(f"Publisher extent {volume.extent_id} serial changed")

    async def _best_effort_disable(self) -> None:
        for volume in self.config.publisher.volumes.values():
            try:
                await self.backend.update_extent(volume.extent_id, enabled=False)
            except Exception:
                LOGGER.exception(
                    "failed_to_disable_publisher_extent extent_id=%s", volume.extent_id
                )

    @staticmethod
    def _response(record: ReleaseRecord) -> ReleaseResponse:
        return ReleaseResponse(
            name=record.name,
            status=record.status,
            active=record.active,
            created_at=record.created_at,
            completed_at=record.completed_at,
            snapshots=record.snapshots,
        )

    @staticmethod
    def _stage_response(record: ReleaseRecord) -> ReleaseStageResponse:
        return ReleaseStageResponse(release=record.name, snapshots=record.snapshots)

    def _audit_failure(
        self,
        request_id: str,
        action: str,
        release_name: str | None,
        source_ip: str,
        exc: Exception,
    ) -> None:
        self._audit(
            request_id=request_id,
            action=action,
            result="failure",
            release_name=release_name,
            source_ip=source_ip,
            details=type(exc).__name__,
        )

    def _audit(self, **kwargs) -> None:
        try:
            self.store.audit(**kwargs)
        except Exception:
            LOGGER.exception("failed_to_write_release_audit")
