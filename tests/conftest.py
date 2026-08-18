from __future__ import annotations

import copy

import pytest

from iscsi_reset_service.backends.mock import MockBackend
from iscsi_reset_service.config import ServiceConfig
from iscsi_reset_service.release_store import ReleaseStore
from iscsi_reset_service.security import token_digest

PEPPER = b"test-pepper-is-at-least-thirty-two-bytes-long"
ADMIN_PEPPER = b"admin-pepper-is-also-at-least-thirty-two-bytes"
CHIMERA_TOKEN = "chimera-test-token"
BEAST_TOKEN = "beast-test-token"
ADMIN_TOKEN = "publisher-administrator-test-token"
ACTIVE_RELEASE = "games-2026.08.18.1"


def config_dict() -> dict:
    return {
        "schema_version": 2,
        "allowed_source_cidr": "10.20.40.0/24",
        "portal": {"address": "10.20.40.10", "port": 3260},
        "admin_api": {
            "allowed_source_ip": "192.168.1.101",
            "token_digest": token_digest(ADMIN_TOKEN, ADMIN_PEPPER),
        },
        "release_management": {
            "prefix": "games",
            "timezone": "Asia/Yekaterinburg",
        },
        "publisher": {
            "source_ip": "10.20.40.100",
            "initiator_iqn": "iqn.1991-05.com.microsoft:threadripper",
            "target_iqn": "iqn.2026-08.lab.games:master",
            "volumes": {
                "ssd": {"dataset": "nvme/masters/games-ssd", "extent_id": 10, "lun": 0},
                "hdd": {"dataset": "hdd/masters/games-hdd", "extent_id": 11, "lun": 1},
            },
        },
        "clients": {
            "chimera": {
                "source_ip": "10.20.40.101",
                "initiator_iqn": "iqn.1991-05.com.microsoft:chimera",
                "target_iqn": "iqn.2026-08.lab.games:chimera",
                "token_digest": token_digest(CHIMERA_TOKEN, PEPPER),
                "volumes": {
                    "ssd": {
                        "extent_id": 1,
                        "lun": 0,
                        "drive_letter": "S",
                        "label": "GAMES_SSD",
                        "clone_parent": "nvme/clients/chimera",
                    },
                    "hdd": {
                        "extent_id": 2,
                        "lun": 1,
                        "drive_letter": "H",
                        "label": "GAMES_HDD",
                        "clone_parent": "hdd/clients/chimera",
                    },
                },
            },
            "beast": {
                "source_ip": "10.20.40.102",
                "initiator_iqn": "iqn.1991-05.com.microsoft:beast",
                "target_iqn": "iqn.2026-08.lab.games:beast",
                "token_digest": token_digest(BEAST_TOKEN, PEPPER),
                "volumes": {
                    "ssd": {
                        "extent_id": 3,
                        "lun": 0,
                        "drive_letter": "S",
                        "label": "GAMES_SSD",
                        "clone_parent": "nvme/clients/beast",
                    },
                    "hdd": {
                        "extent_id": 4,
                        "lun": 1,
                        "drive_letter": "H",
                        "label": "GAMES_HDD",
                        "clone_parent": "hdd/clients/beast",
                    },
                },
            },
        },
    }


def mock_state() -> dict:
    return {
        "snapshots": [
            f"nvme/masters/games-ssd@{ACTIVE_RELEASE}",
            f"hdd/masters/games-hdd@{ACTIVE_RELEASE}",
        ],
        "datasets": {
            "nvme/masters/games-ssd": {"origin": None},
            "hdd/masters/games-hdd": {"origin": None},
        },
        "extents": {
            "1": {
                "disk": "nvme/clients/chimera/ssd__legacy",
                "naa": "0x6589cfc000000001",
                "serial": "CHIMERA-SSD",
                "enabled": True,
            },
            "2": {
                "disk": "hdd/clients/chimera/hdd__legacy",
                "naa": "0x6589cfc000000002",
                "serial": "CHIMERA-HDD",
                "enabled": True,
            },
            "3": {
                "disk": "nvme/clients/beast/ssd__legacy",
                "naa": "0x6589cfc000000003",
                "serial": "BEAST-SSD",
                "enabled": True,
            },
            "4": {
                "disk": "hdd/clients/beast/hdd__legacy",
                "naa": "0x6589cfc000000004",
                "serial": "BEAST-HDD",
                "enabled": True,
            },
            "10": {
                "disk": "nvme/masters/games-ssd",
                "naa": "0x6589cfc000000010",
                "serial": "MASTER-SSD",
                "enabled": True,
            },
            "11": {
                "disk": "hdd/masters/games-hdd",
                "naa": "0x6589cfc000000011",
                "serial": "MASTER-HDD",
                "enabled": True,
            },
        },
        "target_luns": {
            "iqn.2026-08.lab.games:chimera": [
                {"extent_id": 1, "lun": 0},
                {"extent_id": 2, "lun": 1},
            ],
            "iqn.2026-08.lab.games:beast": [
                {"extent_id": 3, "lun": 0},
                {"extent_id": 4, "lun": 1},
            ],
            "iqn.2026-08.lab.games:master": [
                {"extent_id": 10, "lun": 0},
                {"extent_id": 11, "lun": 1},
            ],
        },
        "sessions": [],
    }


def seed_release(store: ReleaseStore, config: ServiceConfig, name: str = ACTIVE_RELEASE) -> None:
    store.reserve(name, f"seed-{name}")
    for volume_name in config.publisher.volumes:
        store.add_snapshot(
            volume_name=volume_name,
            release_name=name,
            snapshot=config.snapshot_path(volume_name, name),
        )
    store.mark_staged(name, set(config.publisher.volumes))
    store.activate(name, f"activate-{name}")


@pytest.fixture
def service_config() -> ServiceConfig:
    return ServiceConfig.model_validate(config_dict())


@pytest.fixture
def backend() -> MockBackend:
    return MockBackend(copy.deepcopy(mock_state()))


@pytest.fixture
def release_store(tmp_path, service_config) -> ReleaseStore:
    store = ReleaseStore(tmp_path / "releases.sqlite3")
    store.initialize()
    seed_release(store, service_config)
    return store
