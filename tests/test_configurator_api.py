from __future__ import annotations

import httpx
import pytest
from conftest import ADMIN_PEPPER, PEPPER, config_dict, mock_state, seed_release

from iscsi_reset_service.backends.mock import MockBackend
from iscsi_reset_service.config import ServiceConfig, dump_config
from iscsi_reset_service.configurator import ConfigRepository, ConfiguratorRuntime
from iscsi_reset_service.configurator_api import (
    IDLE_SECONDS,
    MAX_REQUEST_BYTES,
    create_configurator_app,
)
from iscsi_reset_service.release_store import ReleaseStore
from iscsi_reset_service.security import token_digest

LOGIN_TOKEN = "configurator-test-token"
ORIGIN = "http://127.0.0.1"


def configurator_app(tmp_path):
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config" / "config.yaml"
    config_path.parent.mkdir()
    config_path.write_text(dump_config(config), encoding="utf-8")
    store = ReleaseStore(tmp_path / "state" / "releases.sqlite3")
    store.initialize()
    seed_release(store, config)
    backend = MockBackend(mock_state())
    runtime = ConfiguratorRuntime(
        backend=backend,
        repository=ConfigRepository(config_path, store.path, backend),
        client_pepper=PEPPER,
        admin_pepper=ADMIN_PEPPER,
        login_digest=token_digest(LOGIN_TOKEN, ADMIN_PEPPER),
    )
    return create_configurator_app(runtime), config_path


def transport(app):
    return httpx.ASGITransport(app=app, client=("127.0.0.1", 12000))


@pytest.mark.asyncio
async def test_configurator_requires_loopback_origin_and_login(tmp_path) -> None:
    app, _ = configurator_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        no_origin = await client.post(
            "/v1/configurator/session", json={"token": LOGIN_TOKEN}
        )
        wrong_scheme = await client.post(
            "/v1/configurator/session",
            headers={"Origin": "https://127.0.0.1"},
            json={"token": LOGIN_TOKEN},
        )
        wrong = await client.post(
            "/v1/configurator/session",
            headers={"Origin": ORIGIN},
            json={"token": "wrong"},
        )
        anonymous = await client.get("/v1/configurator/status")
    async with httpx.AsyncClient(
        transport=transport(app), base_url="http://configurator.invalid"
    ) as client:
        non_loopback_host = await client.get("/healthz")

    assert no_origin.status_code == 403
    assert no_origin.json()["error"]["code"] == "ORIGIN_MISMATCH"
    assert wrong_scheme.status_code == 403
    assert wrong_scheme.json()["error"]["code"] == "ORIGIN_MISMATCH"
    assert wrong.status_code == 401
    assert anonymous.status_code == 401
    assert non_loopback_host.status_code == 403
    assert non_loopback_host.json()["error"]["code"] == "LOOPBACK_REQUIRED"


@pytest.mark.asyncio
async def test_login_csrf_security_headers_and_expiry(tmp_path) -> None:
    app, _ = configurator_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        login = await client.post(
            "/v1/configurator/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        csrf = login.json()["csrf_token"]
        status = await client.get("/v1/configurator/status")
        missing_csrf = await client.post(
            "/v1/configurator/tokens",
            headers={"Origin": ORIGIN},
            json={"kind": "client"},
        )
        generated = await client.post(
            "/v1/configurator/tokens",
            headers={"Origin": ORIGIN, "X-CSRF-Token": csrf},
            json={"kind": "client"},
        )
        session_id = client.cookies.get("iscsi_configurator_session")
        app.state.sessions.sessions[session_id].last_seen -= IDLE_SECONDS + 1
        expired = await client.get("/v1/configurator/status")

    assert login.status_code == 200
    assert login.headers["x-frame-options"] == "DENY"
    assert "frame-ancestors 'none'" in login.headers["content-security-policy"]
    assert status.status_code == 200
    assert status.json()["csrf_token"] == csrf
    assert missing_csrf.status_code == 403
    assert generated.status_code == 200
    assert generated.json()["token"]
    assert generated.json()["token_digest"].startswith("hmac-sha256:")
    assert expired.status_code == 401


@pytest.mark.asyncio
async def test_validate_and_save_config_through_api(tmp_path) -> None:
    app, config_path = configurator_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        login = await client.post(
            "/v1/configurator/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        csrf = login.json()["csrf_token"]
        document = await client.get("/v1/configurator/config")
        changed = document.json()["config"]
        changed["clients"]["chimera"]["volumes"]["ssd"]["label"] = "FAST_GAMES"
        validated = await client.post(
            "/v1/configurator/config/validate",
            headers={"Origin": ORIGIN, "X-CSRF-Token": csrf},
            json={"base_revision": document.json()["source_revision"], "config": changed},
        )
        saved = await client.put(
            "/v1/configurator/config",
            headers={"Origin": ORIGIN, "X-CSRF-Token": csrf},
            json={
                "base_revision": document.json()["source_revision"],
                "yaml": validated.json()["yaml"],
            },
        )

    assert validated.status_code == 200
    assert saved.status_code == 200
    assert saved.json()["restart_required"] is True
    assert "FAST_GAMES" in config_path.read_text(encoding="utf-8")


@pytest.mark.asyncio
async def test_request_size_limit_does_not_echo_body(tmp_path) -> None:
    app, _ = configurator_app(tmp_path)
    marker = "raw-token-must-not-be-echoed"
    body = marker + ("x" * MAX_REQUEST_BYTES)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        response = await client.post(
            "/v1/configurator/session",
            headers={"Origin": ORIGIN, "Content-Type": "application/json"},
            content=body,
        )

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "REQUEST_TOO_LARGE"
    assert marker not in response.text
