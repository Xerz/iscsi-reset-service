from __future__ import annotations

import pytest

from iscsi_reset_service.backends.truenas import TrueNASBackend, _dataset_state


def test_dataset_state_reads_top_level_and_property_user_values() -> None:
    state = _dataset_state(
        {
            "id": "nvme/clients/chimera/ssd__r1",
            "properties": {
                "origin": {"rawvalue": "nvme/masters/games-ssd@r1"},
                "org.openai:iscsi-reset-managed": {"rawvalue": "yes"},
            },
            "org.openai:iscsi-reset-client": {"value": "chimera"},
        }
    )

    assert state.origin == "nvme/masters/games-ssd@r1"
    assert state.user_properties["org.openai:iscsi-reset-managed"] == "yes"
    assert state.user_properties["org.openai:iscsi-reset-client"] == "chimera"


def test_dataset_state_accepts_truenas_user_properties_shapes() -> None:
    mapping = _dataset_state(
        {
            "id": "pool/dataset",
            "user_properties": {
                "org.openai:iscsi-reset-release": {"rawvalue": "games-2026.08.18.1"}
            },
        }
    )
    listed = _dataset_state(
        {
            "id": "pool/dataset",
            "user_properties": [
                {"key": "org.openai:iscsi-reset-volume", "value": "ssd"}
            ],
        }
    )

    assert mapping.user_properties["org.openai:iscsi-reset-release"] == "games-2026.08.18.1"
    assert listed.user_properties["org.openai:iscsi-reset-volume"] == "ssd"


class RecordingRpc:
    def __init__(self) -> None:
        self.calls = []

    async def call(self, method, params=None):
        self.calls.append((method, params))
        if method == "iscsi.extent.update":
            return {
                "id": params[0],
                "disk": "zvol/nvme/masters/games-ssd",
                "naa": "0x01",
                "serial": "MASTER",
                "enabled": params[1]["enabled"],
            }
        return {}

    async def close(self):
        return None


class DiscoveryRpc:
    def __init__(self) -> None:
        self.calls = []

    async def call(self, method, params=None):
        self.calls.append((method, params))
        responses = {
            "iscsi.global.config": {
                "basename": "iqn.2026-08.lab.games",
                "listen_port": 3260,
            },
            "iscsi.portal.query": [
                {
                    "id": 1,
                    "comment": "SAN",
                    "listen": [{"ip": "10.20.40.10", "port": 3260}],
                }
            ],
            "iscsi.target.query": [
                {
                    "id": 7,
                    "name": "master",
                    "alias": "Master",
                    "groups": [
                        {
                            "portal": 1,
                            "initiator": 3,
                            "auth_networks": ["10.20.40.100/32"],
                        }
                    ],
                }
            ],
            "iscsi.extent.query": [
                {
                    "id": 10,
                    "name": "master-ssd",
                    "type": "DISK",
                    "disk": "zvol/nvme/masters/games-ssd",
                    "naa": "0x01",
                    "serial": "MASTER",
                    "enabled": True,
                    "locked": False,
                }
            ],
            "iscsi.targetextent.query": [
                {"id": 5, "target": 7, "extent": 10, "lunid": 0}
            ],
            "iscsi.initiator.query": [
                {
                    "id": 3,
                    "comment": "publisher",
                    "initiators": ["iqn.1991-05.com.microsoft:publisher"],
                }
            ],
            "pool.dataset.query": [
                {
                    "id": "nvme/masters/games-ssd",
                    "type": "VOLUME",
                    "locked": False,
                }
            ],
            "iscsi.global.sessions": [],
        }
        return responses[method]

    async def close(self):
        return None


@pytest.mark.asyncio
async def test_master_snapshot_is_non_recursive_and_without_vmware_sync() -> None:
    rpc = RecordingRpc()
    backend = TrueNASBackend(rpc)

    await backend.create_snapshot("nvme/masters/games-ssd", "games-2026.08.18.2")

    assert rpc.calls == [
        (
            "pool.snapshot.create",
            [
                {
                    "dataset": "nvme/masters/games-ssd",
                    "name": "games-2026.08.18.2",
                    "recursive": False,
                    "vmware_sync": False,
                }
            ],
        )
    ]


@pytest.mark.asyncio
async def test_master_extent_enabled_flag_is_the_only_update() -> None:
    rpc = RecordingRpc()
    backend = TrueNASBackend(rpc)

    result = await backend.update_extent(10, enabled=False)

    assert rpc.calls == [("iscsi.extent.update", [10, {"enabled": False}])]
    assert result.enabled is False


@pytest.mark.asyncio
async def test_configuration_discovery_uses_read_only_query_methods() -> None:
    rpc = DiscoveryRpc()
    backend = TrueNASBackend(rpc)

    result = await backend.discover_configuration()

    assert result.targets[0].iqn == "iqn.2026-08.lab.games:master"
    assert result.extents[0].disk == "nvme/masters/games-ssd"
    assert result.associations[0].extent_id == 10
    assert result.datasets[0].type == "VOLUME"
    assert rpc.calls == [
        ("iscsi.global.config", None),
        ("iscsi.portal.query", [[], {}]),
        ("iscsi.target.query", [[], {}]),
        (
            "iscsi.extent.query",
            [[], {"extra": {"retrieve_locked_info": True}}],
        ),
        ("iscsi.targetextent.query", [[], {}]),
        ("iscsi.initiator.query", [[], {}]),
        (
            "pool.dataset.query",
            [
                [],
                {
                    "extra": {
                        "flat": True,
                        "retrieve_children": True,
                        "properties": [],
                        "retrieve_user_props": False,
                    }
                },
            ],
        ),
        ("iscsi.global.sessions", [[], {}]),
    ]
