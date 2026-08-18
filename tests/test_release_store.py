from __future__ import annotations

import sqlite3

import pytest

from iscsi_reset_service.release_store import ReleaseStore, ReleaseStoreError


def test_release_store_persists_active_release_across_reopen(
    tmp_path, service_config
) -> None:
    path = tmp_path / "releases.sqlite3"
    store = ReleaseStore(path)
    store.initialize()
    store.reserve("games-2026.08.18.1", "stage-1")
    for volume_name in service_config.publisher.volumes:
        store.add_snapshot(
            "games-2026.08.18.1",
            volume_name,
            service_config.snapshot_path(volume_name, "games-2026.08.18.1"),
        )
    store.mark_staged("games-2026.08.18.1", set(service_config.publisher.volumes))
    store.activate("games-2026.08.18.1", "activate-1")

    reopened = ReleaseStore(path, read_only=True)
    reopened.initialize()
    active = reopened.active_release()

    assert active is not None
    assert active.name == "games-2026.08.18.1"
    assert active.active is True
    assert set(active.snapshots) == {"ssd", "hdd"}


def test_snapshot_mapping_is_immutable(release_store) -> None:
    with pytest.raises(ReleaseStoreError, match="only be added to incomplete"):
        release_store.add_snapshot(
            "games-2026.08.18.1",
            "ssd",
            "nvme/masters/games-ssd@games-2026.08.18.999",
        )


def test_activation_is_idempotent_for_same_request(release_store) -> None:
    first = release_store.activate("games-2026.08.18.1", "repeat-activation")
    second = release_store.activate("games-2026.08.18.1", "repeat-activation")
    assert first.name == second.name
    assert release_store.active_release().name == first.name


def test_read_only_store_rejects_mutation(tmp_path) -> None:
    path = tmp_path / "releases.sqlite3"
    writable = ReleaseStore(path)
    writable.initialize()
    read_only = ReleaseStore(path, read_only=True)

    with pytest.raises(ReleaseStoreError, match="read-only"):
        read_only.reserve("games-2026.08.18.1", "stage")


def test_unknown_database_schema_fails_closed(tmp_path) -> None:
    path = tmp_path / "releases.sqlite3"
    with sqlite3.connect(path) as connection:
        connection.execute("PRAGMA user_version=99")

    with pytest.raises(ReleaseStoreError, match="unsupported release database schema"):
        ReleaseStore(path, read_only=True).initialize()
