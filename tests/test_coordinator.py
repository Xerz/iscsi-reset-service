from __future__ import annotations

import asyncio

import pytest
from conftest import config_dict, seed_release

from iscsi_reset_service.backends.mock import MockBackend
from iscsi_reset_service.config import ServiceConfig
from iscsi_reset_service.coordinator import ResetCoordinator
from iscsi_reset_service.errors import ClientBusyError, NotReadyError, SessionActiveError
from iscsi_reset_service.models import DatasetState, ExtentState, SessionState, TargetLunState
from iscsi_reset_service.release_store import ReleaseStore


@pytest.mark.asyncio
async def test_prepare_migrates_both_luns_and_creates_clean_snapshots(
    service_config, backend: MockBackend, release_store
) -> None:
    coordinator = ResetCoordinator(service_config, backend, release_store)

    result = await coordinator.prepare("chimera")

    assert result.target_iqn == "iqn.2026-08.lab.games:chimera"
    assert [item.drive_letter for item in result.volumes] == ["S", "H"]
    assert backend.extents[1].disk.endswith("ssd__games-2026.08.18.1")
    assert backend.extents[2].disk.endswith("hdd__games-2026.08.18.1")
    assert backend.extents[1].enabled is True
    assert backend.extents[2].enabled is True
    assert "nvme/clients/chimera/ssd__games-2026.08.18.1@clean" in backend.snapshots
    assert "hdd/clients/chimera/hdd__games-2026.08.18.1@clean" in backend.snapshots
    assert any(call.startswith("rollback_snapshot:") for call in backend.calls)


@pytest.mark.asyncio
async def test_prepare_supports_an_arbitrary_third_volume(
    backend: MockBackend, tmp_path
) -> None:
    raw = config_dict()
    release_name = "games-2026.08.18.1"
    bonus_snapshot = f"hdd/masters/games-bonus@{release_name}"
    raw["publisher"]["volumes"]["bonus"] = {
        "dataset": "hdd/masters/games-bonus",
        "extent_id": 12,
        "lun": 2,
    }
    raw["clients"]["chimera"]["volumes"]["bonus"] = {
        "extent_id": 5,
        "lun": 2,
        "drive_letter": "T",
        "label": "GAMES_BONUS",
        "clone_parent": "hdd/clients/chimera",
    }
    backend.snapshots.add(bonus_snapshot)
    backend.datasets["hdd/masters/games-bonus"] = DatasetState(
        "hdd/masters/games-bonus", None, {}
    )
    backend.extents[12] = ExtentState(
        id=12,
        disk="hdd/masters/games-bonus",
        naa="0x6589cfc000000012",
        serial="MASTER-BONUS",
        enabled=True,
    )
    backend.luns["iqn.2026-08.lab.games:master"].append(
        TargetLunState(
            target_iqn="iqn.2026-08.lab.games:master", extent_id=12, lun=2
        )
    )
    backend.extents[5] = ExtentState(
        id=5,
        disk="hdd/clients/chimera/bonus__legacy",
        naa="0x6589cfc000000005",
        serial="CHIMERA-BONUS",
        enabled=True,
    )
    backend.luns["iqn.2026-08.lab.games:chimera"].append(
        TargetLunState(
            target_iqn="iqn.2026-08.lab.games:chimera",
            extent_id=5,
            lun=2,
        )
    )
    config = ServiceConfig.model_validate(raw)
    store = ReleaseStore(tmp_path / "bonus.sqlite3")
    store.initialize()
    seed_release(store, config)
    coordinator = ResetCoordinator(config, backend, store)

    result = await coordinator.prepare("chimera")

    assert [volume.name for volume in result.volumes] == ["ssd", "hdd", "bonus"]
    assert backend.extents[5].disk.endswith(f"bonus__{release_name}")
    assert f"hdd/clients/chimera/bonus__{release_name}@clean" in backend.snapshots


@pytest.mark.asyncio
async def test_prepare_is_idempotent_and_reuses_release_clone(
    service_config, backend: MockBackend, release_store
) -> None:
    coordinator = ResetCoordinator(service_config, backend, release_store)
    await coordinator.prepare("chimera")
    first_clone_calls = [call for call in backend.calls if call.startswith("clone_snapshot:")]

    await coordinator.prepare("chimera")

    second_clone_calls = [call for call in backend.calls if call.startswith("clone_snapshot:")]
    assert second_clone_calls == first_clone_calls
    assert len([call for call in backend.calls if call.startswith("rollback_snapshot:")]) == 4


@pytest.mark.asyncio
async def test_active_session_blocks_before_any_extent_change(
    service_config, backend: MockBackend, release_store
) -> None:
    backend.sessions.append(
        SessionState(
            initiator_iqn="iqn.1991-05.com.microsoft:chimera",
            initiator_addr="10.20.40.101",
            target_iqn="iqn.2026-08.lab.games:chimera",
        )
    )
    coordinator = ResetCoordinator(service_config, backend, release_store)

    with pytest.raises(SessionActiveError):
        await coordinator.prepare("chimera")

    assert backend.extents[1].enabled is True
    assert backend.extents[2].enabled is True
    assert not any(call.startswith("update_extent") for call in backend.calls)


@pytest.mark.asyncio
async def test_partial_extent_switch_fails_closed_and_retry_recovers(
    service_config, backend: MockBackend, release_store
) -> None:
    backend.failpoints["update_extent_disk:2"] = 1
    coordinator = ResetCoordinator(service_config, backend, release_store)

    with pytest.raises(NotReadyError):
        await coordinator.prepare("chimera")

    assert backend.extents[1].enabled is False
    assert backend.extents[2].enabled is False

    result = await coordinator.prepare("chimera")
    assert result.status == "ready"
    assert backend.extents[1].enabled is True
    assert backend.extents[2].enabled is True
    assert backend.extents[1].disk.endswith("games-2026.08.18.1")
    assert backend.extents[2].disk.endswith("games-2026.08.18.1")


@pytest.mark.asyncio
async def test_existing_clone_with_wrong_origin_is_not_destroyed(
    service_config, backend: MockBackend, release_store
) -> None:
    destination = "nvme/clients/chimera/ssd__games-2026.08.18.1"
    backend.datasets[destination] = DatasetState(
        destination,
        "nvme/masters/games-ssd@wrong",
        {
            "org.openai:iscsi-reset-managed": "yes",
            "org.openai:iscsi-reset-client": "chimera",
            "org.openai:iscsi-reset-volume": "ssd",
            "org.openai:iscsi-reset-release": "games-2026.08.18.1",
        },
    )
    coordinator = ResetCoordinator(service_config, backend, release_store)

    with pytest.raises(NotReadyError, match="origin mismatch"):
        await coordinator.prepare("chimera")

    assert backend.datasets[destination].origin.endswith("@wrong")
    assert backend.extents[1].enabled is False
    assert backend.extents[2].enabled is False


@pytest.mark.asyncio
async def test_second_concurrent_request_gets_client_busy(
    service_config, backend, release_store
) -> None:
    coordinator = ResetCoordinator(service_config, backend, release_store)
    lock = coordinator._locks["chimera"]
    await lock.acquire()
    try:
        with pytest.raises(ClientBusyError):
            await coordinator.prepare("chimera")
    finally:
        lock.release()


@pytest.mark.asyncio
async def test_different_clients_have_independent_locks(
    service_config, backend, release_store
) -> None:
    coordinator = ResetCoordinator(service_config, backend, release_store)
    await coordinator._locks["chimera"].acquire()
    try:
        result = await asyncio.wait_for(coordinator.prepare("beast"), timeout=1)
        assert result.target_iqn.endswith(":beast")
    finally:
        coordinator._locks["chimera"].release()


@pytest.mark.parametrize(
    ("operation", "call_number"),
    [
        ("update_extent:1", 1),
        ("update_extent:2", 1),
        ("clone_snapshot:nvme/clients/chimera/ssd__games-2026.08.18.1", 1),
        ("create_snapshot:nvme/clients/chimera/ssd__games-2026.08.18.1@clean", 1),
        ("clone_snapshot:hdd/clients/chimera/hdd__games-2026.08.18.1", 1),
        ("create_snapshot:hdd/clients/chimera/hdd__games-2026.08.18.1@clean", 1),
        ("update_extent_disk:1", 1),
        ("update_extent_disk:2", 1),
        ("rollback_snapshot:nvme/clients/chimera/ssd__games-2026.08.18.1@clean", 1),
        ("rollback_snapshot:hdd/clients/chimera/hdd__games-2026.08.18.1@clean", 1),
        ("target_luns:iqn.2026-08.lab.games:chimera", 2),
        ("update_extent:1", 2),
        ("update_extent:2", 2),
    ],
)
@pytest.mark.asyncio
async def test_every_partial_mutation_failure_is_fail_closed_and_reconcilable(
    service_config,
    backend: MockBackend,
    release_store,
    operation: str,
    call_number: int,
) -> None:
    backend.fail_at_calls[operation] = {call_number}
    coordinator = ResetCoordinator(service_config, backend, release_store)

    with pytest.raises(NotReadyError):
        await coordinator.prepare("chimera")

    assert backend.extents[1].enabled is False
    assert backend.extents[2].enabled is False

    result = await coordinator.prepare("chimera")
    assert result.status == "ready"
    assert backend.extents[1].enabled is True
    assert backend.extents[2].enabled is True
    assert backend.extents[1].serial == "CHIMERA-SSD"
    assert backend.extents[2].serial == "CHIMERA-HDD"


@pytest.mark.asyncio
async def test_release_migration_keeps_old_clones_for_audit(
    service_config, backend, release_store
) -> None:
    await ResetCoordinator(service_config, backend, release_store).prepare("chimera")

    release_name = "games-2026.08.19.1"
    backend.snapshots.update(
        {
            f"nvme/masters/games-ssd@{release_name}",
            f"hdd/masters/games-hdd@{release_name}",
        }
    )
    release_store.reserve(release_name, "stage-r2")
    for volume_name in service_config.publisher.volumes:
        release_store.add_snapshot(
            release_name,
            volume_name,
            service_config.snapshot_path(volume_name, release_name),
        )
    release_store.mark_staged(release_name, set(service_config.publisher.volumes))
    release_store.activate(release_name, "activate-r2")
    coordinator = ResetCoordinator(service_config, backend, release_store)

    await coordinator.prepare("chimera")
    stale = await coordinator.audit_stale_clones()

    assert backend.extents[1].disk.endswith(f"ssd__{release_name}")
    assert backend.extents[2].disk.endswith(f"hdd__{release_name}")
    assert "nvme/clients/chimera/ssd__games-2026.08.18.1" in stale
    assert "hdd/clients/chimera/hdd__games-2026.08.18.1" in stale


@pytest.mark.asyncio
async def test_parallel_clients_remain_storage_isolated(
    service_config, backend, release_store
) -> None:
    coordinator = ResetCoordinator(service_config, backend, release_store)

    chimera, beast = await asyncio.gather(
        coordinator.prepare("chimera"), coordinator.prepare("beast")
    )

    assert chimera.target_iqn.endswith(":chimera")
    assert beast.target_iqn.endswith(":beast")
    assert "/chimera/" in backend.extents[1].disk
    assert "/chimera/" in backend.extents[2].disk
    assert "/beast/" in backend.extents[3].disk
    assert "/beast/" in backend.extents[4].disk


@pytest.mark.parametrize("matching_field", ["initiator_iqn", "initiator_addr", "target_iqn"])
@pytest.mark.asyncio
async def test_any_matching_session_identity_blocks_reset(
    service_config, backend, release_store, matching_field: str
) -> None:
    values = {
        "initiator_iqn": "iqn.1991-05.com.example:unrelated",
        "initiator_addr": "10.20.40.250",
        "target_iqn": "iqn.2026-08.lab.games:unrelated",
    }
    values[matching_field] = {
        "initiator_iqn": "iqn.1991-05.com.microsoft:chimera",
        "initiator_addr": "10.20.40.101",
        "target_iqn": "iqn.2026-08.lab.games:chimera",
    }[matching_field]
    backend.sessions.append(SessionState(**values))

    with pytest.raises(SessionActiveError):
        await ResetCoordinator(service_config, backend, release_store).prepare("chimera")

    assert not any(call.startswith("update_extent") for call in backend.calls)


@pytest.mark.asyncio
async def test_extent_serial_change_is_fail_closed(
    service_config, backend, release_store, monkeypatch
) -> None:
    original_update = backend.update_extent

    async def mutating_update(extent_id, *, enabled=None, disk=None):
        result = await original_update(extent_id, enabled=enabled, disk=disk)
        if extent_id == 1 and disk is not None:
            backend.extents[extent_id].serial = "MUTATED"
            result.serial = "MUTATED"
        return result

    monkeypatch.setattr(backend, "update_extent", mutating_update)

    with pytest.raises(NotReadyError, match="serial changed"):
        await ResetCoordinator(service_config, backend, release_store).prepare("chimera")

    assert backend.extents[1].enabled is False
    assert backend.extents[2].enabled is False
