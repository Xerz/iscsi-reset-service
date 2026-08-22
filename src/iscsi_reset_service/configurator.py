from __future__ import annotations

import asyncio
import fcntl
import hashlib
import ipaddress
import os
import sqlite3
import tempfile
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from iscsi_reset_service.backends import MockBackend, StorageBackend, TrueNASBackend
from iscsi_reset_service.backends.base import BackendError
from iscsi_reset_service.backends.truenas import TrueNASRpcClient
from iscsi_reset_service.config import (
    IQN_RE,
    TOKEN_DIGEST_RE,
    ServiceConfig,
    dump_config,
    parse_config_yaml,
)
from iscsi_reset_service.models import ConfigurationDiscovery, TargetState
from iscsi_reset_service.release_manager import ReleaseManager
from iscsi_reset_service.release_store import ReleaseStore, ReleaseStoreError

MAX_CONFIG_BYTES = 512 * 1024


class ConfiguratorError(RuntimeError):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


@dataclass(slots=True)
class ConfigDocument:
    exists: bool
    source_revision: str | None
    config: ServiceConfig | None
    yaml: str | None
    error: str | None

    def as_dict(self) -> dict[str, object]:
        return {
            "exists": self.exists,
            "valid": self.config is not None,
            "source_revision": self.source_revision,
            "config_revision": self.config.revision if self.config else None,
            "config": self.config.model_dump(mode="json") if self.config else None,
            "yaml": self.yaml,
            "error": self.error,
        }


@dataclass(slots=True)
class ValidationResult:
    config: ServiceConfig
    yaml: str
    discovery: ConfigurationDiscovery
    warnings: list[str]

    def as_dict(self) -> dict[str, object]:
        return {
            "valid": True,
            "config_revision": self.config.revision,
            "config": self.config.model_dump(mode="json"),
            "yaml": self.yaml,
            "warnings": self.warnings,
        }


@dataclass(slots=True)
class SaveResult:
    saved_revision: str
    source_revision: str
    startup_revision: str | None
    history_file: str | None

    def as_dict(self) -> dict[str, object]:
        return {
            "saved_revision": self.saved_revision,
            "source_revision": self.source_revision,
            "startup_revision": self.startup_revision,
            "restart_required": self.startup_revision != self.saved_revision,
            "history_file": self.history_file,
        }


@dataclass(slots=True)
class ManagementRuntime:
    discovery_backend: StorageBackend
    mutation_backend: StorageBackend
    repository: ConfigRepository
    client_pepper: bytes
    management_pepper: bytes
    login_digest: str
    store: ReleaseStore
    config: ServiceConfig | None
    release_manager: ReleaseManager | None
    mutation_lock: asyncio.Lock

    @classmethod
    def from_env(cls) -> ManagementRuntime:
        backend_name = os.environ.get(
            "MANAGEMENT_BACKEND", os.environ.get("BACKEND", "truenas")
        ).lower()
        if backend_name == "mock":
            state_path = os.environ.get("MOCK_STATE_PATH")
            discovery_backend: StorageBackend = (
                MockBackend.from_file(state_path) if state_path else MockBackend()
            )
            mutation_backend = discovery_backend
        elif backend_name == "truenas":
            api_url = os.environ.get("TRUENAS_API_URL")
            if not api_url:
                raise ValueError("TRUENAS_API_URL must use the TrueNAS management IP")
            discovery_key = _read_secret("TRUENAS_DISCOVERY_API_KEY_FILE")
            discovery_rpc = TrueNASRpcClient(
                api_url,
                os.environ.get(
                    "TRUENAS_DISCOVERY_API_USERNAME", "iscsi-reset-discovery"
                ),
                discovery_key,
                tls_verify=_env_bool("TRUENAS_TLS_VERIFY", True),
                insecure_ack=os.environ.get("TRUENAS_TLS_INSECURE_ACK"),
            )
            mutation_key = _read_secret("TRUENAS_API_KEY_FILE")
            mutation_rpc = TrueNASRpcClient(
                api_url,
                os.environ.get("TRUENAS_API_USERNAME", "iscsi-reset-service"),
                mutation_key,
                tls_verify=_env_bool("TRUENAS_TLS_VERIFY", True),
                insecure_ack=os.environ.get("TRUENAS_TLS_INSECURE_ACK"),
            )
            discovery_backend = TrueNASBackend(discovery_rpc)
            mutation_backend = TrueNASBackend(mutation_rpc)
        else:
            raise ValueError("MANAGEMENT_BACKEND must be truenas or mock")

        client_pepper = _read_secret("TOKEN_PEPPER_FILE").encode("utf-8")
        management_pepper = _read_secret("MANAGEMENT_TOKEN_PEPPER_FILE").encode("utf-8")
        if len(client_pepper) < 32 or len(management_pepper) < 32:
            raise ValueError("token peppers must be at least 32 bytes")
        login_digest = _read_secret("MANAGEMENT_TOKEN_DIGEST_FILE")
        if not TOKEN_DIGEST_RE.fullmatch(login_digest):
            raise ValueError("management token digest is invalid")

        repository = ConfigRepository(
            os.environ.get("CONFIG_PATH", "/config/config.yaml"),
            os.environ.get("RELEASE_DB_PATH", "/state/releases.sqlite3"),
            discovery_backend,
        )
        store = ReleaseStore(
            os.environ.get("RELEASE_DB_PATH", "/state/releases.sqlite3"),
            read_only=False,
        )
        config = repository.startup_config
        release_manager = None
        if config is not None:
            store.initialize()
            release_manager = ReleaseManager(config, mutation_backend, store)
        return cls(
            discovery_backend,
            mutation_backend,
            repository,
            client_pepper,
            management_pepper,
            login_digest,
            store,
            config,
            release_manager,
            asyncio.Lock(),
        )

    async def close(self) -> None:
        await self.discovery_backend.close()
        if self.mutation_backend is not self.discovery_backend:
            await self.mutation_backend.close()


class ConfigRepository:
    def __init__(
        self,
        config_path: str | Path,
        release_db_path: str | Path,
        backend: StorageBackend,
    ) -> None:
        self.config_path = Path(config_path)
        self.release_db_path = Path(release_db_path)
        self.backend = backend
        document = self.read()
        self.startup_revision = document.config.revision if document.config else None
        self.startup_config = document.config

    def read(self) -> ConfigDocument:
        try:
            raw = self.config_path.read_bytes()
        except FileNotFoundError:
            return ConfigDocument(False, None, None, None, None)
        except OSError as exc:
            return ConfigDocument(True, None, None, None, f"cannot read config: {exc}")
        source_revision = _source_revision(raw)
        try:
            source = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            return ConfigDocument(True, source_revision, None, None, str(exc))
        try:
            config = parse_config_yaml(source)
        except (ValueError, ValidationError) as exc:
            return ConfigDocument(True, source_revision, None, source, str(exc))
        return ConfigDocument(True, source_revision, config, dump_config(config), None)

    async def discovery(self) -> ConfigurationDiscovery:
        try:
            return await self.backend.discover_configuration()
        except (BackendError, KeyError, TypeError, ValueError) as exc:
            raise ConfiguratorError(
                503, "DISCOVERY_UNAVAILABLE", "TrueNAS discovery is unavailable"
            ) from exc

    async def validate_yaml(self, source: str) -> ValidationResult:
        if len(source.encode("utf-8")) > MAX_CONFIG_BYTES:
            raise ConfiguratorError(413, "CONFIG_TOO_LARGE", "Configuration is too large")
        try:
            config = parse_config_yaml(source)
        except (ValueError, ValidationError) as exc:
            raise ConfiguratorError(422, "CONFIG_INVALID", str(exc)) from exc
        discovery = await self.discovery()
        warnings = validate_live_topology(config, discovery)
        self._validate_release_state(config)
        return ValidationResult(config, dump_config(config), discovery, warnings)

    async def validate_object(self, value: dict[str, Any]) -> ValidationResult:
        try:
            config = ServiceConfig.model_validate(value)
        except ValidationError as exc:
            raise ConfiguratorError(422, "CONFIG_INVALID", str(exc)) from exc
        return await self.validate_yaml(dump_config(config))

    async def save_yaml(self, source: str, base_revision: str | None) -> SaveResult:
        lock_fd = -1
        try:
            self.config_path.parent.mkdir(parents=True, exist_ok=True)
            lock_path = self.config_path.parent / ".config.lock"
            lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
            os.fchmod(lock_fd, 0o600)
            with os.fdopen(lock_fd, "r+") as lock_file:
                lock_fd = -1
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                current = self.read()
                if current.source_revision != base_revision:
                    raise ConfiguratorError(
                        409,
                        "CONFIG_CHANGED",
                        "Configuration changed after this draft was opened",
                    )
                validated = await self.validate_yaml(source)
                canonical = validated.yaml.encode("utf-8")
                history_file = self._preserve_history(current)
                self._atomic_replace(canonical)
        except ConfiguratorError:
            raise
        except OSError as exc:
            raise ConfiguratorError(
                503, "CONFIG_WRITE_FAILED", "Cannot lock configuration for writing"
            ) from exc
        finally:
            if lock_fd >= 0:
                os.close(lock_fd)
        return SaveResult(
            saved_revision=validated.config.revision,
            source_revision=_source_revision(canonical),
            startup_revision=self.startup_revision,
            history_file=history_file,
        )

    def _validate_release_state(self, proposed: ServiceConfig) -> None:
        current = self.read()
        if not self.release_db_path.exists():
            if current.exists:
                raise ConfiguratorError(
                    503,
                    "RELEASE_STATE_MISSING",
                    "Release database is missing for an installed configuration",
                )
            return
        try:
            store = ReleaseStore(self.release_db_path, read_only=True)
            store.initialize()
            releases = store.list()
            active = store.active_release()
        except (ReleaseStoreError, sqlite3.Error) as exc:
            raise ConfiguratorError(
                503, "RELEASE_STATE_INVALID", "Release database is unavailable or invalid"
            ) from exc

        if active is not None:
            expected = {
                name: proposed.snapshot_path(name, active.name)
                for name in proposed.publisher.volumes
            }
            if active.snapshots != expected:
                raise ConfiguratorError(
                    409,
                    "ACTIVE_RELEASE_INCOMPATIBLE",
                    "Publisher volume datasets are incompatible with the active release",
                )

        incomplete = [item for item in releases if item.status == "incomplete"]
        if incomplete:
            if current.config is None:
                raise ConfiguratorError(
                    409,
                    "RELEASE_INCOMPLETE",
                    "Cannot replace an invalid config while a release is incomplete",
                )
            publisher_changed = (
                current.config.portal != proposed.portal
                or current.config.publisher != proposed.publisher
                or current.config.release_management != proposed.release_management
            )
            if publisher_changed:
                raise ConfiguratorError(
                    409,
                    "RELEASE_INCOMPLETE",
                    "Recover the incomplete release before changing publisher topology",
                )

    def _preserve_history(self, current: ConfigDocument) -> str | None:
        if not current.exists:
            return None
        try:
            raw = self.config_path.read_bytes()
            history_dir = self.config_path.parent / "history"
            history_dir.mkdir(mode=0o700, exist_ok=True)
            os.chmod(history_dir, 0o700)
            stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%fZ")
            name = f"{stamp}-{_source_revision(raw)}-{uuid.uuid4().hex[:8]}.yaml"
            target = history_dir / name
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as output:
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
            _fsync_directory(history_dir)
        except OSError as exc:
            raise ConfiguratorError(
                503, "CONFIG_WRITE_FAILED", "Cannot preserve current configuration"
            ) from exc
        return name

    def _atomic_replace(self, content: bytes) -> None:
        temporary_path: str | None = None
        try:
            fd, temporary_path = tempfile.mkstemp(
                prefix=".config.", suffix=".tmp", dir=self.config_path.parent
            )
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as output:
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary_path, self.config_path)
            temporary_path = None
            os.chmod(self.config_path, 0o600)
            _fsync_directory(self.config_path.parent)
        except OSError as exc:
            raise ConfiguratorError(
                503, "CONFIG_WRITE_FAILED", "Atomic configuration save failed"
            ) from exc
        finally:
            if temporary_path is not None:
                try:
                    os.unlink(temporary_path)
                except FileNotFoundError:
                    pass


def validate_live_topology(
    config: ServiceConfig, discovery: ConfigurationDiscovery
) -> list[str]:
    warnings: list[str] = []
    portals = {item.id: item for item in discovery.portals}
    targets = {item.iqn: item for item in discovery.targets}
    initiators = {item.id: item for item in discovery.initiator_groups}
    extents = {item.id: item for item in discovery.extents}
    datasets = {item.id: item for item in discovery.datasets}
    associations: dict[str, set[tuple[int, int]]] = {}
    for item in discovery.associations:
        associations.setdefault(item.target_iqn, set()).add((item.extent_id, item.lun))

    portal_pair = (str(config.portal.address), config.portal.port)
    identities = [
        (
            "publisher",
            str(config.publisher.source_ip),
            config.publisher.initiator_iqn,
            config.publisher.target_iqn,
        ),
        *[
            (name, str(client.source_ip), client.initiator_iqn, client.target_iqn)
            for name, client in config.clients.items()
        ],
    ]
    for name, source_ip, initiator_iqn, target_iqn in identities:
        target = targets.get(target_iqn)
        if target is None:
            _conflict(f"{name} target does not exist in TrueNAS: {target_iqn}")
        if target.mode not in {"ISCSI", "BOTH"}:
            _conflict(f"{name} target does not expose iSCSI mode")
        target_portals = {
            listen
            for portal_id in target.portal_ids
            for listen in portals.get(portal_id, _empty_portal()).listen
        }
        if portal_pair not in target_portals:
            _conflict(f"{name} target is not attached to portal {portal_pair[0]}:{portal_pair[1]}")
        warnings.extend(
            _validate_target_identity(
                name,
                source_ip,
                initiator_iqn,
                target,
                initiators,
            )
        )

    publisher_pairs = {
        (volume.extent_id, volume.lun) for volume in config.publisher.volumes.values()
    }
    if publisher_pairs != associations.get(config.publisher.target_iqn, set()):
        _conflict("publisher extent/LUN set does not exactly match the selected target")
    for name, volume in config.publisher.volumes.items():
        extent = _eligible_extent(name, volume.extent_id, extents)
        if extent.disk != volume.dataset:
            _conflict(
                f"publisher volume {name} dataset differs from extent {extent.id} disk"
            )
        dataset = datasets.get(volume.dataset)
        if dataset is None or dataset.type != "VOLUME" or dataset.locked is not False:
            _conflict(f"publisher volume {name} must use an unlocked existing zvol")

    for client_name, client in config.clients.items():
        client_pairs = {(item.extent_id, item.lun) for item in client.volumes.values()}
        if client_pairs != associations.get(client.target_iqn, set()):
            _conflict(
                f"client {client_name} extent/LUN set does not exactly match its target"
            )
        for volume_name, volume in client.volumes.items():
            _eligible_extent(f"{client_name}/{volume_name}", volume.extent_id, extents)
            parent = client.parent_for(volume_name)
            dataset = datasets.get(parent)
            if (
                dataset is None
                or dataset.type != "FILESYSTEM"
                or dataset.locked is not False
            ):
                _conflict(
                    f"client {client_name}/{volume_name} clone_parent must be an "
                    "unlocked existing filesystem dataset"
                )
    return warnings


def _validate_target_identity(
    name: str,
    source_ip: str,
    initiator_iqn: str,
    target: TargetState,
    initiator_groups: dict[int, Any],
) -> list[str]:
    entries = [
        entry
        for group_id in target.initiator_ids
        for entry in initiator_groups.get(group_id, _empty_initiator()).initiators
    ]
    iqns = {entry.lower() for entry in entries if IQN_RE.fullmatch(entry)}
    networks = [*target.auth_networks]
    networks.extend(entry for entry in entries if not IQN_RE.fullmatch(entry))
    if initiator_iqn not in iqns:
        _conflict(f"{name} initiator IQN is not authorized by its target")
    parsed_networks = []
    for value in networks:
        try:
            parsed_networks.append(ipaddress.ip_network(value, strict=False))
        except ValueError:
            continue
    expected_network = ipaddress.ip_network(f"{source_ip}/32")
    if expected_network not in parsed_networks:
        _conflict(f"{name} target does not authorize the exact source IP /32")
    return []


def _eligible_extent(name: str, extent_id: int, extents: dict[int, Any]) -> Any:
    extent = extents.get(extent_id)
    if extent is None:
        _conflict(f"{name} extent does not exist: {extent_id}")
    if extent.type != "DISK" or not extent.disk or extent.locked is not False:
        _conflict(f"{name} extent must be an unlocked disk/zvol extent")
    return extent


def _conflict(message: str) -> None:
    raise ConfiguratorError(409, "TOPOLOGY_MISMATCH", message)


def _empty_portal() -> Any:
    class EmptyPortal:
        listen: tuple[tuple[str, int], ...] = ()

    return EmptyPortal()


def _empty_initiator() -> Any:
    class EmptyInitiator:
        initiators: tuple[str, ...] = ()

    return EmptyInitiator()


def _source_revision(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()[:16]


def _fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _read_secret(name: str) -> str:
    path = os.environ.get(name)
    if not path:
        raise ValueError(f"missing secret: {name}")
    return Path(path).read_text(encoding="utf-8").strip()


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    if raw.lower() in {"1", "true", "yes", "on"}:
        return True
    if raw.lower() in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be a boolean")
