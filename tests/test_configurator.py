from __future__ import annotations

import copy
import os
import stat

import pytest
from conftest import config_dict, mock_state, seed_release

from iscsi_reset_service.backends.mock import MockBackend
from iscsi_reset_service.config import ServiceConfig, dump_config, parse_config_yaml
from iscsi_reset_service.configurator import (
    ConfigRepository,
    ConfiguratorError,
    validate_live_topology,
)
from iscsi_reset_service.models import DatasetState
from iscsi_reset_service.release_store import ReleaseStore


def test_yaml_parser_rejects_duplicate_keys() -> None:
    source = dump_config(ServiceConfig.model_validate(config_dict()))
    duplicate = source.replace("schema_version: 2", "schema_version: 2\nschema_version: 2")

    with pytest.raises(ValueError, match="duplicate key: schema_version"):
        parse_config_yaml(duplicate)


def test_canonical_yaml_is_deterministic_and_drops_comments() -> None:
    source = "# formatting is intentionally not retained\n" + dump_config(
        ServiceConfig.model_validate(config_dict())
    )

    canonical = dump_config(parse_config_yaml(source))

    assert "formatting is intentionally not retained" not in canonical
    assert dump_config(parse_config_yaml(canonical)) == canonical


def test_invalid_existing_yaml_remains_editable(tmp_path) -> None:
    config_path = tmp_path / "config.yaml"
    invalid = "schema_version: 2\nschema_version: 2\n"
    config_path.write_text(invalid, encoding="utf-8")

    document = ConfigRepository(
        config_path,
        tmp_path / "missing.sqlite3",
        MockBackend(mock_state()),
    ).read()

    assert document.config is None
    assert document.yaml == invalid
    assert "duplicate key" in document.error


@pytest.mark.asyncio
async def test_repository_validates_live_topology_and_canonicalizes(tmp_path) -> None:
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config" / "config.yaml"
    config_path.parent.mkdir()
    config_path.write_text(dump_config(config), encoding="utf-8")
    store = ReleaseStore(tmp_path / "state" / "releases.sqlite3")
    store.initialize()
    seed_release(store, config)
    repository = ConfigRepository(config_path, store.path, MockBackend(mock_state()))

    result = await repository.validate_yaml(dump_config(config))

    assert result.config.revision == config.revision
    assert result.warnings == []
    assert result.yaml.startswith("schema_version: 2\n")


@pytest.mark.asyncio
async def test_live_topology_rejects_file_or_locked_extents() -> None:
    config = ServiceConfig.model_validate(config_dict())
    backend = MockBackend(mock_state())
    backend.extents[1].type = "FILE"

    with pytest.raises(ConfiguratorError, match="unlocked disk/zvol"):
        validate_live_topology(config, await backend.discover_configuration())

    backend = MockBackend(mock_state())
    backend.extents[1].locked = True
    with pytest.raises(ConfiguratorError, match="unlocked disk/zvol"):
        validate_live_topology(config, await backend.discover_configuration())


@pytest.mark.asyncio
async def test_live_topology_rejects_locked_clone_parent() -> None:
    config = ServiceConfig.model_validate(config_dict())
    backend = MockBackend(mock_state())
    backend.datasets["nvme/clients/chimera"].locked = True

    with pytest.raises(ConfiguratorError, match="unlocked existing filesystem"):
        validate_live_topology(config, await backend.discover_configuration())

    backend.datasets["nvme/clients/chimera"].locked = None
    with pytest.raises(ConfiguratorError, match="unlocked existing filesystem"):
        validate_live_topology(config, await backend.discover_configuration())


@pytest.mark.asyncio
async def test_live_topology_rejects_zvol_with_unknown_lock_state() -> None:
    config = ServiceConfig.model_validate(config_dict())
    backend = MockBackend(mock_state())
    backend.datasets["nvme/masters/games-ssd"].locked = None

    with pytest.raises(ConfiguratorError, match="unlocked existing zvol"):
        validate_live_topology(config, await backend.discover_configuration())


@pytest.mark.asyncio
async def test_save_is_atomic_versioned_and_optimistic(tmp_path) -> None:
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config" / "config.yaml"
    config_path.parent.mkdir()
    config_path.write_text(dump_config(config), encoding="utf-8")
    store = ReleaseStore(tmp_path / "state" / "releases.sqlite3")
    store.initialize()
    seed_release(store, config)
    repository = ConfigRepository(config_path, store.path, MockBackend(mock_state()))
    base_revision = repository.read().source_revision
    changed = copy.deepcopy(config_dict())
    changed["clients"]["chimera"]["volumes"]["ssd"]["label"] = "GAMES_FAST"

    with pytest.raises(ConfiguratorError, match="changed after this draft") as stale:
        await repository.save_yaml(dump_config(ServiceConfig.model_validate(changed)), "0" * 16)
    result = await repository.save_yaml(
        dump_config(ServiceConfig.model_validate(changed)), base_revision
    )

    assert stale.value.status_code == 409
    assert result.saved_revision != config.revision
    assert result.startup_revision == config.revision
    assert stat.S_IMODE(config_path.stat().st_mode) == 0o600
    history = list((config_path.parent / "history").glob("*.yaml"))
    assert len(history) == 1
    assert parse_config_yaml(history[0].read_text()).revision == config.revision


@pytest.mark.asyncio
async def test_failed_replace_preserves_current_config(tmp_path, monkeypatch) -> None:
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config" / "config.yaml"
    config_path.parent.mkdir()
    original = dump_config(config)
    config_path.write_text(original, encoding="utf-8")
    store = ReleaseStore(tmp_path / "state" / "releases.sqlite3")
    store.initialize()
    seed_release(store, config)
    repository = ConfigRepository(config_path, store.path, MockBackend(mock_state()))
    changed = copy.deepcopy(config_dict())
    changed["clients"]["chimera"]["volumes"]["ssd"]["label"] = "NEW_LABEL"

    def fail_replace(_: str, __: os.PathLike[str]) -> None:
        raise OSError("injected replace failure")

    monkeypatch.setattr("iscsi_reset_service.configurator.os.replace", fail_replace)
    with pytest.raises(ConfiguratorError, match="Atomic configuration save failed"):
        await repository.save_yaml(
            dump_config(ServiceConfig.model_validate(changed)),
            repository.read().source_revision,
        )

    assert config_path.read_text(encoding="utf-8") == original
    history = list((config_path.parent / "history").glob("*.yaml"))
    assert len(history) == 1
    assert history[0].read_text(encoding="utf-8") == original


@pytest.mark.asyncio
async def test_save_rechecks_discovery_after_prior_validation(tmp_path) -> None:
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config" / "config.yaml"
    config_path.parent.mkdir()
    original = dump_config(config)
    config_path.write_text(original, encoding="utf-8")
    store = ReleaseStore(tmp_path / "state" / "releases.sqlite3")
    store.initialize()
    seed_release(store, config)
    backend = MockBackend(mock_state())
    repository = ConfigRepository(config_path, store.path, backend)

    await repository.validate_yaml(original)
    del backend.extents[1]

    with pytest.raises(ConfiguratorError) as disappeared:
        await repository.save_yaml(original, repository.read().source_revision)

    assert disappeared.value.code == "TOPOLOGY_MISMATCH"
    assert config_path.read_text(encoding="utf-8") == original
    assert not (config_path.parent / "history").exists()


@pytest.mark.asyncio
async def test_active_release_blocks_publisher_dataset_change(tmp_path) -> None:
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config" / "config.yaml"
    config_path.parent.mkdir()
    config_path.write_text(dump_config(config), encoding="utf-8")
    store = ReleaseStore(tmp_path / "state" / "releases.sqlite3")
    store.initialize()
    seed_release(store, config)
    backend = MockBackend(mock_state())
    backend.extents[10].disk = "nvme/masters/games-new"
    backend.datasets["nvme/masters/games-new"] = DatasetState(
        "nvme/masters/games-new", None, type="VOLUME", locked=False
    )
    repository = ConfigRepository(config_path, store.path, backend)
    changed = copy.deepcopy(config_dict())
    changed["publisher"]["volumes"]["ssd"]["dataset"] = "nvme/masters/games-new"

    with pytest.raises(ConfiguratorError) as conflict:
        await repository.validate_object(changed)

    assert conflict.value.status_code == 409
    assert conflict.value.code == "ACTIVE_RELEASE_INCOMPATIBLE"


@pytest.mark.asyncio
async def test_incomplete_release_blocks_publisher_changes(tmp_path) -> None:
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config" / "config.yaml"
    config_path.parent.mkdir()
    config_path.write_text(dump_config(config), encoding="utf-8")
    store = ReleaseStore(tmp_path / "state" / "releases.sqlite3")
    store.initialize()
    store.reserve("games-2026.08.19.1", "incomplete")
    repository = ConfigRepository(config_path, store.path, MockBackend(mock_state()))
    changed = copy.deepcopy(config_dict())
    changed["release_management"]["prefix"] = "library"

    with pytest.raises(ConfiguratorError) as conflict:
        await repository.validate_object(changed)

    assert conflict.value.code == "RELEASE_INCOMPLETE"


@pytest.mark.asyncio
async def test_missing_database_is_allowed_only_for_bootstrap(tmp_path) -> None:
    config = ServiceConfig.model_validate(config_dict())
    missing_store = tmp_path / "state" / "releases.sqlite3"
    backend = MockBackend(mock_state())
    bootstrap_path = tmp_path / "bootstrap" / "config.yaml"
    bootstrap = ConfigRepository(bootstrap_path, missing_store, backend)

    result = await bootstrap.save_yaml(dump_config(config), None)
    assert result.saved_revision == config.revision

    installed = ConfigRepository(bootstrap_path, missing_store, MockBackend(mock_state()))
    with pytest.raises(ConfiguratorError) as missing:
        await installed.validate_yaml(dump_config(config))
    assert missing.value.code == "RELEASE_STATE_MISSING"

    invalid_path = tmp_path / "invalid" / "config.yaml"
    invalid_path.parent.mkdir()
    invalid_path.write_text("schema_version: [", encoding="utf-8")
    invalid = ConfigRepository(invalid_path, missing_store, MockBackend(mock_state()))
    with pytest.raises(ConfiguratorError) as invalid_missing:
        await invalid.save_yaml(
            dump_config(config), invalid.read().source_revision
        )
    assert invalid_missing.value.code == "RELEASE_STATE_MISSING"


@pytest.mark.asyncio
async def test_corrupt_database_blocks_save(tmp_path) -> None:
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config.yaml"
    config_path.write_text(dump_config(config), encoding="utf-8")
    corrupt_store = tmp_path / "releases.sqlite3"
    corrupt_store.write_bytes(b"not a sqlite database")
    repository = ConfigRepository(config_path, corrupt_store, MockBackend(mock_state()))

    with pytest.raises(ConfiguratorError) as invalid:
        await repository.save_yaml(
            dump_config(config), repository.read().source_revision
        )

    assert invalid.value.code == "RELEASE_STATE_INVALID"


@pytest.mark.asyncio
async def test_incomplete_database_schema_blocks_save(tmp_path) -> None:
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config.yaml"
    config_path.write_text(dump_config(config), encoding="utf-8")
    incomplete_store = tmp_path / "releases.sqlite3"
    store = ReleaseStore(incomplete_store)
    store.initialize()
    with store._connect() as connection:
        connection.execute("DROP TABLE settings")
    repository = ConfigRepository(config_path, incomplete_store, MockBackend(mock_state()))

    with pytest.raises(ConfiguratorError) as invalid:
        await repository.save_yaml(
            dump_config(config), repository.read().source_revision
        )

    assert invalid.value.code == "RELEASE_STATE_INVALID"
