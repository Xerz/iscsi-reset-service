from __future__ import annotations

from dataclasses import replace

import pytest
from conftest import ACTIVE_RELEASE, seed_release

from iscsi_reset_service.coordinator import ResetCoordinator
from iscsi_reset_service.management import ManagementInspector
from iscsi_reset_service.models import SessionState


@pytest.mark.asyncio
async def test_dashboard_separates_connection_from_mapped_release(
    service_config, backend, release_store
) -> None:
    await ResetCoordinator(service_config, backend, release_store).prepare("chimera")
    backend.sessions.append(
        SessionState(
            initiator_iqn=service_config.clients["chimera"].initiator_iqn,
            initiator_addr=str(service_config.clients["chimera"].source_ip),
            target_iqn=service_config.clients["chimera"].target_iqn,
        )
    )

    result = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision=service_config.revision, restart_required=False)
    chimera = next(item for item in result["clients"] if item["name"] == "chimera")
    beast = next(item for item in result["clients"] if item["name"] == "beast")

    assert chimera["connection_status"] == "connected"
    assert chimera["mapped_release"] == ACTIVE_RELEASE
    assert chimera["update_status"] == "updated"
    assert beast["connection_status"] == "disconnected"
    assert beast["update_status"] == "unprepared"
    assert result["all_clients_updated"] is False


@pytest.mark.asyncio
async def test_dashboard_distinguishes_outdated_partial_and_unprepared(
    service_config, backend, release_store
) -> None:
    old = "games-2026.08.17.1"
    backend.snapshots.update(
        service_config.snapshot_path(name, old)
        for name in service_config.publisher.volumes
    )
    seed_release(release_store, service_config, old)
    await ResetCoordinator(service_config, backend, release_store).prepare("chimera")
    release_store.activate(ACTIVE_RELEASE, "restore-active")

    result = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision=service_config.revision, restart_required=False)
    chimera = next(item for item in result["clients"] if item["name"] == "chimera")
    beast = next(item for item in result["clients"] if item["name"] == "beast")

    assert chimera["mapped_release"] == old
    assert chimera["update_status"] == "outdated"
    assert beast["mapped_release"] is None
    assert beast["update_status"] == "unprepared"

    backend.datasets.pop(chimera["volumes"][0]["dataset"])
    partial = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision=service_config.revision, restart_required=False)
    chimera = next(item for item in partial["clients"] if item["name"] == "chimera")

    assert chimera["mapped_release"] is None
    assert chimera["update_status"] == "partial"
    assert chimera["errors"]


@pytest.mark.asyncio
async def test_partial_session_identity_is_a_conflict(
    service_config, backend, release_store
) -> None:
    backend.sessions.append(
        SessionState(
            initiator_iqn=service_config.publisher.initiator_iqn,
            initiator_addr="10.20.40.250",
            target_iqn="iqn.2026-08.lab.games:wrong",
        )
    )

    result = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision=service_config.revision, restart_required=False)

    assert result["publisher"]["connection_status"] == "conflict"
    assert result["release_action"]["can_stage"] is False
    assert result["release_action"]["reasons"] == [
        "Publisher session identity conflict"
    ]


@pytest.mark.asyncio
async def test_dual_role_client_session_is_an_expected_blocking_conflict(
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

    result = await ManagementInspector(
        dual_role_config, dual_role_backend, release_store
    ).dashboard(saved_revision=dual_role_config.revision, restart_required=False)
    chimera = next(item for item in result["clients"] if item["name"] == "chimera")

    assert result["publisher"]["connection_status"] == "conflict"
    assert chimera["connection_status"] == "connected"
    assert result["release_action"]["can_stage"] is False
    assert result["release_action"]["reasons"] == [
        f"Shared-role client session is active: chimera ({client.target_iqn})"
    ]


@pytest.mark.asyncio
async def test_dual_role_master_session_conflicts_with_client_view(
    dual_role_config, dual_role_backend, release_store
) -> None:
    publisher = dual_role_config.publisher
    dual_role_backend.sessions.append(
        SessionState(
            initiator_iqn=publisher.initiator_iqn,
            initiator_addr=str(publisher.source_ip),
            target_iqn=publisher.target_iqn,
        )
    )

    result = await ManagementInspector(
        dual_role_config, dual_role_backend, release_store
    ).dashboard(saved_revision=dual_role_config.revision, restart_required=False)
    chimera = next(item for item in result["clients"] if item["name"] == "chimera")

    assert result["publisher"]["connection_status"] == "connected"
    assert chimera["connection_status"] == "conflict"
    assert result["release_action"]["can_stage"] is False
    assert result["release_action"]["reasons"] == ["Publisher is connected"]


@pytest.mark.asyncio
async def test_old_release_is_unused_only_after_every_client_updates(
    service_config, backend, release_store
) -> None:
    old = "games-2026.08.17.1"
    backend.snapshots.update(
        service_config.snapshot_path(name, old)
        for name in service_config.publisher.volumes
    )
    seed_release(release_store, service_config, old)
    coordinator = ResetCoordinator(service_config, backend, release_store)
    await coordinator.prepare("chimera")
    await coordinator.prepare("beast")
    release_store.activate(ACTIVE_RELEASE, "restore-active")
    await coordinator.prepare("chimera")

    before = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision=service_config.revision, restart_required=False)
    old_before = next(item for item in before["releases"] if item["name"] == old)
    assert old_before["unused_by_current_mappings"] is False

    await coordinator.prepare("beast")
    after = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision=service_config.revision, restart_required=False)
    old_after = next(item for item in after["releases"] if item["name"] == old)

    assert after["all_clients_updated"] is True
    assert old_after["unused_by_current_mappings"] is True
    assert old_after["mapped_clients"] == []
    assert old_after["clone_dependencies"] == sorted(
        [
            f"hdd/clients/beast/hdd__{old}",
            f"hdd/clients/chimera/hdd__{old}",
            f"nvme/clients/beast/ssd__{old}",
            f"nvme/clients/chimera/ssd__{old}",
        ]
    )

    backend.snapshots.remove(service_config.snapshot_path("ssd", old))
    missing = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision=service_config.revision, restart_required=False)
    old_missing = next(item for item in missing["releases"] if item["name"] == old)
    snapshots = {item["volume"]: item["exists"] for item in old_missing["snapshots"]}

    assert snapshots == {"hdd": True, "ssd": False}


@pytest.mark.asyncio
async def test_restart_requirement_blocks_release_action(
    service_config, backend, release_store
) -> None:
    result = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision="different", restart_required=True)

    assert result["release_action"]["can_stage"] is False
    assert any("restart" in item for item in result["release_action"]["reasons"])


@pytest.mark.asyncio
async def test_publisher_requires_exact_discovery_authorization(
    service_config, backend, release_store
) -> None:
    backend.targets = [
        replace(item, auth_networks=("10.20.40.0/24",))
        if item.iqn == service_config.publisher.target_iqn
        else item
        for item in backend.targets
    ]
    publisher_group = next(
        item for item in backend.initiator_groups if item.comment == "publisher"
    )
    backend.initiator_groups = [
        replace(publisher_group, initiators=(service_config.publisher.initiator_iqn,))
        if item.id == publisher_group.id
        else item
        for item in backend.initiator_groups
    ]

    result = await ManagementInspector(
        service_config, backend, release_store
    ).dashboard(saved_revision=service_config.revision, restart_required=False)

    assert result["publisher"]["topology_valid"] is False
    assert result["release_action"]["can_stage"] is False
    assert any("exact source IP /32" in item for item in result["publisher"]["errors"])
