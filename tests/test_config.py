from __future__ import annotations

import copy

import pytest
from conftest import config_dict, dual_role_config_dict
from pydantic import ValidationError

from iscsi_reset_service.config import ServiceConfig, load_config


def test_valid_config_supports_separate_clone_pools() -> None:
    config = ServiceConfig.model_validate(config_dict())
    assert config.clients["chimera"].parent_for("ssd") == "nvme/clients/chimera"
    assert config.clients["chimera"].parent_for("hdd") == "hdd/clients/chimera"
    assert config.snapshot_path("ssd", "games-2026.08.18.1") == (
        "nvme/masters/games-ssd@games-2026.08.18.1"
    )
    assert len(config.revision) == 16


def test_iqns_are_normalized_to_lowercase() -> None:
    raw = config_dict()
    raw["publisher"]["initiator_iqn"] = raw["publisher"]["initiator_iqn"].upper()
    raw["publisher"]["target_iqn"] = raw["publisher"]["target_iqn"].upper()
    raw["clients"]["chimera"]["initiator_iqn"] = (
        raw["clients"]["chimera"]["initiator_iqn"].upper()
    )
    config = ServiceConfig.model_validate(raw)

    assert config.publisher.initiator_iqn == "iqn.1991-05.com.microsoft:publisher"
    assert config.publisher.target_iqn == "iqn.2026-08.lab.games:master"
    assert config.clients["chimera"].initiator_iqn == "iqn.1991-05.com.microsoft:chimera"


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("source_ip", "10.20.40.101"),
        ("initiator_iqn", "iqn.1991-05.com.microsoft:chimera"),
        ("target_iqn", "iqn.2026-08.lab.games:chimera"),
    ],
)
def test_duplicate_client_identity_is_rejected(field: str, value: str) -> None:
    raw = config_dict()
    raw["clients"]["beast"][field] = value
    with pytest.raises(ValidationError, match=f"duplicate {field}"):
        ServiceConfig.model_validate(raw)


def test_one_client_may_share_full_publisher_identity_pair() -> None:
    config = ServiceConfig.model_validate(dual_role_config_dict())

    assert config.shared_publisher_client == "chimera"
    assert config.clients["chimera"].source_ip == config.publisher.source_ip
    assert config.clients["chimera"].initiator_iqn == config.publisher.initiator_iqn
    assert config.clients["chimera"].target_iqn != config.publisher.target_iqn


@pytest.mark.parametrize("field", ["source_ip", "initiator_iqn"])
def test_client_cannot_partially_match_publisher_identity(field: str) -> None:
    raw = config_dict()
    raw["clients"]["chimera"][field] = raw["publisher"][field]

    with pytest.raises(ValidationError, match="must match both publisher"):
        ServiceConfig.model_validate(raw)


def test_second_client_cannot_share_publisher_identity_pair() -> None:
    raw = dual_role_config_dict()
    raw["clients"]["beast"]["source_ip"] = raw["publisher"]["source_ip"]
    raw["clients"]["beast"]["initiator_iqn"] = raw["publisher"]["initiator_iqn"]

    with pytest.raises(ValidationError, match="only one client may share publisher"):
        ServiceConfig.model_validate(raw)


def test_shared_client_still_requires_distinct_target() -> None:
    raw = dual_role_config_dict()
    raw["clients"]["chimera"]["target_iqn"] = raw["publisher"]["target_iqn"]

    with pytest.raises(ValidationError, match="duplicate target_iqn"):
        ServiceConfig.model_validate(raw)


def test_duplicate_client_or_publisher_extent_is_rejected() -> None:
    raw = config_dict()
    raw["clients"]["beast"]["volumes"]["ssd"]["extent_id"] = 10
    with pytest.raises(ValidationError, match="duplicate extent_id"):
        ServiceConfig.model_validate(raw)


def test_cross_pool_clone_is_rejected() -> None:
    raw = config_dict()
    raw["clients"]["chimera"]["volumes"]["hdd"]["clone_parent"] = (
        "nvme/clients/chimera"
    )
    with pytest.raises(ValidationError, match="clone_parent must be in pool hdd"):
        ServiceConfig.model_validate(raw)


def test_client_volume_must_have_publisher_master() -> None:
    raw = copy.deepcopy(config_dict())
    raw["clients"]["chimera"]["volumes"]["tools"] = {
        "extent_id": 20,
        "lun": 2,
        "drive_letter": "T",
        "label": "TOOLS",
        "clone_parent": "nvme/clients/chimera",
    }
    with pytest.raises(ValidationError, match="has no publisher master"):
        ServiceConfig.model_validate(raw)


def test_client_may_use_subset_of_publisher_volumes() -> None:
    raw = config_dict()
    del raw["clients"]["beast"]["volumes"]["hdd"]
    config = ServiceConfig.model_validate(raw)
    assert set(config.clients["beast"].volumes) == {"ssd"}


@pytest.mark.parametrize("version", [1, 2])
def test_old_schemas_have_explicit_error(tmp_path, version: int) -> None:
    path = tmp_path / "old.yaml"
    path.write_text(f"schema_version: {version}\n", encoding="utf-8")
    with pytest.raises(ValueError, match="schema_version 1 and 2 are unsupported"):
        load_config(path)


def test_schema_v3_rejects_removed_admin_api() -> None:
    raw = config_dict()
    raw["admin_api"] = {
        "allowed_source_ip": "192.168.1.101",
        "token_digest": f"hmac-sha256:{'0' * 64}",
    }
    with pytest.raises(ValidationError, match="admin_api"):
        ServiceConfig.model_validate(raw)
