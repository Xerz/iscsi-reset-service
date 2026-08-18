from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from iscsi_reset_service.backends import (
    MockBackend,
    StorageBackend,
    TrueNASBackend,
    TrueNASRpcClient,
)
from iscsi_reset_service.config import ServiceConfig, load_config
from iscsi_reset_service.release_store import ReleaseStore


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    if raw.lower() in {"1", "true", "yes", "on"}:
        return True
    if raw.lower() in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be a boolean")


def _read_secret(path_env: str, value_env: str | None = None) -> str:
    path = os.environ.get(path_env)
    if path:
        return Path(path).read_text(encoding="utf-8").strip()
    if value_env and os.environ.get(value_env):
        return os.environ[value_env].strip()
    raise ValueError(f"missing secret: {path_env}")


@dataclass(slots=True)
class Runtime:
    config: ServiceConfig
    backend: StorageBackend
    pepper: bytes
    store: ReleaseStore
    admin_pepper: bytes | None = None
    allow_test_source_header: bool = False

    @classmethod
    def from_env(cls, *, role: str | None = None) -> Runtime:
        role = (role or os.environ.get("SERVICE_ROLE", "reset")).lower()
        if role not in {"reset", "admin", "cli"}:
            raise ValueError("SERVICE_ROLE must be reset, admin, or cli")
        config = load_config(os.environ.get("CONFIG_PATH", "/config/config.yaml"))
        pepper = _read_secret("TOKEN_PEPPER_FILE", "TOKEN_PEPPER").encode("utf-8")
        if len(pepper) < 32:
            raise ValueError("token pepper must be at least 32 bytes")
        admin_pepper = None
        if role == "admin":
            admin_pepper = _read_secret(
                "ADMIN_TOKEN_PEPPER_FILE", "ADMIN_TOKEN_PEPPER"
            ).encode("utf-8")
            if len(admin_pepper) < 32:
                raise ValueError("admin token pepper must be at least 32 bytes")
        store = ReleaseStore(
            os.environ.get("RELEASE_DB_PATH", "/state/releases.sqlite3"),
            read_only=role == "reset",
        )
        if role != "reset":
            store.initialize()
        backend_name = os.environ.get("BACKEND", "truenas").lower()
        if backend_name == "mock":
            state_path = os.environ.get("MOCK_STATE_PATH")
            backend = MockBackend.from_file(state_path) if state_path else MockBackend()
            allow_test_header = _env_bool("ALLOW_TEST_SOURCE_HEADER", False)
        elif backend_name == "truenas":
            api_key = _read_secret("TRUENAS_API_KEY_FILE", "TRUENAS_API_KEY")
            rpc = TrueNASRpcClient(
                os.environ.get("TRUENAS_API_URL", "wss://127.0.0.1/api/current"),
                os.environ.get("TRUENAS_API_USERNAME", "iscsi-reset-service"),
                api_key,
                tls_verify=_env_bool("TRUENAS_TLS_VERIFY", True),
                insecure_ack=os.environ.get("TRUENAS_TLS_INSECURE_ACK"),
            )
            backend = TrueNASBackend(rpc)
            allow_test_header = False
        else:
            raise ValueError("BACKEND must be truenas or mock")
        return cls(config, backend, pepper, store, admin_pepper, allow_test_header)
