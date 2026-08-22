from __future__ import annotations

import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from iscsi_reset_service.coordinator import ResetCoordinator
from iscsi_reset_service.errors import (
    NotReadyError,
    PublisherSessionActiveError,
    ReleaseBusyError,
    ReleaseConflictError,
)
from iscsi_reset_service.models import SessionState
from iscsi_reset_service.release_manager import ReleaseManager


def expected_next_release(service_config) -> str:
    date_part = datetime.now(
        ZoneInfo(service_config.release_management.timezone)
    ).strftime("%Y.%m.%d")
    sequence = 2 if date_part == "2026.08.18" else 1
    return f"games-{date_part}.{sequence}"


@pytest.mark.asyncio
async def test_stage_creates_complete_release_and_reenables_masters(
    service_config, backend, release_store
) -> None:
    manager = ReleaseManager(service_config, backend, release_store)

    result = await manager.stage("stage-r2", "192.168.1.101")

    assert result.release == expected_next_release(service_config)
    assert set(result.snapshots) == {"ssd", "hdd"}
    assert backend.extents[10].enabled is True
    assert backend.extents[11].enabled is True
    assert release_store.active_release().name == "games-2026.08.18.1"
    assert release_store.get(result.release).status == "staged"


@pytest.mark.asyncio
async def test_activation_requires_exact_confirmation_and_is_atomic(
    service_config, backend, release_store
) -> None:
    manager = ReleaseManager(service_config, backend, release_store)
    staged = await manager.stage("stage-r2", "192.168.1.101")

    with pytest.raises(ReleaseConflictError, match="Confirmation must be exactly"):
        await manager.activate(
            staged.release, "yes", "activate-r2-wrong", "192.168.1.101"
        )
    assert release_store.active_release().name == "games-2026.08.18.1"

    result = await manager.activate(
        staged.release,
        f"ACTIVATE {staged.release}",
        "activate-r2",
        "192.168.1.101",
    )
    assert result.release == staged.release
    assert release_store.active_release().name == staged.release


@pytest.mark.asyncio
async def test_activation_rechecks_publisher_is_still_disconnected(
    service_config, backend, release_store
) -> None:
    manager = ReleaseManager(service_config, backend, release_store)
    staged = await manager.stage("stage-before-race", "127.0.0.1")
    backend.sessions.append(
        SessionState(
            initiator_iqn=service_config.publisher.initiator_iqn,
            initiator_addr=str(service_config.publisher.source_ip),
            target_iqn=service_config.publisher.target_iqn,
        )
    )

    with pytest.raises(PublisherSessionActiveError):
        await manager.activate(
            staged.release,
            f"ACTIVATE {staged.release}",
            "activate-after-reconnect",
            "127.0.0.1",
        )

    assert release_store.active_release().name != staged.release


@pytest.mark.asyncio
async def test_client_prepare_lazily_uses_newly_activated_release(
    service_config, backend, release_store
) -> None:
    manager = ReleaseManager(service_config, backend, release_store)
    staged = await manager.stage("stage-for-client", "192.168.1.101")
    await manager.activate(
        staged.release,
        f"ACTIVATE {staged.release}",
        "activate-for-client",
        "192.168.1.101",
    )

    result = await ResetCoordinator(service_config, backend, release_store).prepare(
        "chimera"
    )

    assert result.status == "ready"
    assert backend.extents[1].disk.endswith(f"ssd__{staged.release}")
    assert backend.extents[2].disk.endswith(f"hdd__{staged.release}")


@pytest.mark.asyncio
async def test_publisher_session_blocks_before_extent_mutation(
    service_config, backend, release_store
) -> None:
    backend.sessions.append(
        SessionState(
            initiator_iqn=service_config.publisher.initiator_iqn,
            initiator_addr=str(service_config.publisher.source_ip),
            target_iqn=service_config.publisher.target_iqn,
        )
    )

    with pytest.raises(PublisherSessionActiveError):
        await ReleaseManager(service_config, backend, release_store).stage(
            "blocked", "192.168.1.101"
        )

    assert backend.extents[10].enabled is True
    assert backend.extents[11].enabled is True
    assert not any(call.startswith("update_extent") for call in backend.calls)


@pytest.mark.asyncio
async def test_dual_role_client_session_blocks_stage_before_extent_mutation(
    dual_role_config, dual_role_backend, release_store
) -> None:
    client = dual_role_config.clients["chimera"]
    dual_role_backend.sessions.append(
        SessionState(
            initiator_iqn=client.initiator_iqn,
            initiator_addr=str(client.source_ip),
            target_iqn=client.target_iqn,
        )
    )

    with pytest.raises(PublisherSessionActiveError):
        await ReleaseManager(
            dual_role_config, dual_role_backend, release_store
        ).stage("dual-role-blocked", "192.168.1.101")

    assert dual_role_backend.extents[10].enabled is True
    assert dual_role_backend.extents[11].enabled is True
    assert not any(
        call.startswith("update_extent") for call in dual_role_backend.calls
    )


@pytest.mark.asyncio
async def test_dual_role_client_session_blocks_activation(
    dual_role_config, dual_role_backend, release_store
) -> None:
    manager = ReleaseManager(dual_role_config, dual_role_backend, release_store)
    staged = await manager.stage("dual-role-stage", "192.168.1.101")
    client = dual_role_config.clients["chimera"]
    dual_role_backend.sessions.append(
        SessionState(
            initiator_iqn=client.initiator_iqn,
            initiator_addr=str(client.source_ip),
            target_iqn=client.target_iqn,
        )
    )

    with pytest.raises(PublisherSessionActiveError):
        await manager.activate(
            staged.release,
            f"ACTIVATE {staged.release}",
            "dual-role-activate",
            "192.168.1.101",
        )

    assert release_store.active_release().name != staged.release


@pytest.mark.asyncio
async def test_partial_snapshot_failure_is_fail_closed_and_same_request_recovers(
    service_config, backend, release_store
) -> None:
    release_name = expected_next_release(service_config)
    backend.failpoints[f"create_snapshot:hdd/masters/games-hdd@{release_name}"] = 1
    manager = ReleaseManager(service_config, backend, release_store)

    with pytest.raises(NotReadyError):
        await manager.stage("recoverable-stage", "192.168.1.101")

    assert release_store.active_release().name == "games-2026.08.18.1"
    incomplete = release_store.by_request_id("recoverable-stage")
    assert incomplete is not None
    assert incomplete.status == "incomplete"
    assert set(incomplete.snapshots) == {"ssd"}
    assert backend.extents[10].enabled is False
    assert backend.extents[11].enabled is False

    with pytest.raises(ReleaseConflictError, match="must be resumed"):
        await manager.stage("different-request", "192.168.1.101")

    result = await manager.stage("recoverable-stage", "192.168.1.101")
    assert result.release == release_name
    assert set(result.snapshots) == {"ssd", "hdd"}
    assert backend.extents[10].enabled is True
    assert backend.extents[11].enabled is True


@pytest.mark.asyncio
async def test_concurrent_stage_is_locked(service_config, backend, release_store) -> None:
    manager = ReleaseManager(service_config, backend, release_store)
    await manager._lock.acquire()
    try:
        with pytest.raises(ReleaseBusyError):
            await asyncio.wait_for(
                manager.stage("concurrent", "192.168.1.101"), timeout=1
            )
    finally:
        manager._lock.release()


@pytest.mark.parametrize(
    ("operation_template", "call_number"),
    [
        ("update_extent:10", 1),
        ("update_extent:11", 1),
        ("create_snapshot:nvme/masters/games-ssd@{release}", 1),
        ("create_snapshot:hdd/masters/games-hdd@{release}", 1),
        ("target_luns:iqn.2026-08.lab.games:master", 2),
        ("update_extent:10", 2),
        ("update_extent:11", 2),
    ],
)
@pytest.mark.asyncio
async def test_every_release_mutation_failure_is_fail_closed_and_reconcilable(
    service_config,
    backend,
    release_store,
    operation_template: str,
    call_number: int,
) -> None:
    release_name = expected_next_release(service_config)
    operation = operation_template.format(release=release_name)
    backend.fail_at_calls[operation] = {call_number}
    manager = ReleaseManager(service_config, backend, release_store)

    with pytest.raises(NotReadyError):
        await manager.stage("exhaustive-retry", "192.168.1.101")

    assert backend.extents[10].enabled is False
    assert backend.extents[11].enabled is False
    assert release_store.active_release().name == "games-2026.08.18.1"

    staged = await manager.stage("exhaustive-retry", "192.168.1.101")
    assert staged.status == "staged"
    assert backend.extents[10].enabled is True
    assert backend.extents[11].enabled is True
