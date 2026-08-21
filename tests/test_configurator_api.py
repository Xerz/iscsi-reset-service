from __future__ import annotations

import asyncio

import httpx
import pytest
from conftest import PEPPER, config_dict, mock_state, seed_release

from iscsi_reset_service.backends.mock import MockBackend
from iscsi_reset_service.config import ServiceConfig, dump_config
from iscsi_reset_service.configurator import ConfigRepository, ManagementRuntime
from iscsi_reset_service.configurator_api import (
    IDLE_SECONDS,
    MAX_REQUEST_BYTES,
    create_management_app,
)
from iscsi_reset_service.models import SessionState
from iscsi_reset_service.release_manager import ReleaseManager
from iscsi_reset_service.release_store import ReleaseStore
from iscsi_reset_service.security import token_digest

LOGIN_TOKEN = "management-test-token"
MANAGEMENT_PEPPER = b"management-test-pepper-is-at-least-thirty-two-bytes"
ORIGIN = "http://127.0.0.1"


def management_app(tmp_path):
    config = ServiceConfig.model_validate(config_dict())
    config_path = tmp_path / "config" / "config.yaml"
    config_path.parent.mkdir()
    config_path.write_text(dump_config(config), encoding="utf-8")
    store = ReleaseStore(tmp_path / "state" / "releases.sqlite3")
    store.initialize()
    seed_release(store, config)
    backend = MockBackend(mock_state())
    repository = ConfigRepository(config_path, store.path, backend)
    runtime = ManagementRuntime(
        discovery_backend=backend,
        mutation_backend=backend,
        repository=repository,
        client_pepper=PEPPER,
        management_pepper=MANAGEMENT_PEPPER,
        login_digest=token_digest(LOGIN_TOKEN, MANAGEMENT_PEPPER),
        store=store,
        config=config,
        release_manager=ReleaseManager(config, backend, store),
        mutation_lock=asyncio.Lock(),
    )
    return create_management_app(runtime), config_path


def transport(app):
    return httpx.ASGITransport(app=app, client=("127.0.0.1", 12000))


@pytest.mark.asyncio
async def test_management_requires_loopback_origin_and_login(tmp_path) -> None:
    app, _ = management_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        no_origin = await client.post(
            "/v1/management/session", json={"token": LOGIN_TOKEN}
        )
        wrong_scheme = await client.post(
            "/v1/management/session",
            headers={"Origin": "https://127.0.0.1"},
            json={"token": LOGIN_TOKEN},
        )
        wrong = await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN},
            json={"token": "wrong"},
        )
        anonymous = await client.get("/v1/management/status")
    async with httpx.AsyncClient(
        transport=transport(app), base_url="http://management.invalid"
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
    app, _ = management_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        login = await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        csrf = login.json()["csrf_token"]
        status = await client.get("/v1/management/status")
        missing_csrf = await client.post(
            "/v1/management/tokens",
            headers={"Origin": ORIGIN},
            json={"kind": "client"},
        )
        generated = await client.post(
            "/v1/management/tokens",
            headers={"Origin": ORIGIN, "X-CSRF-Token": csrf},
            json={"kind": "client"},
        )
        session_id = client.cookies.get("iscsi_management_session")
        app.state.sessions.sessions[session_id].last_seen -= IDLE_SECONDS + 1
        expired = await client.get("/v1/management/status")

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
    app, config_path = management_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        login = await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        csrf = login.json()["csrf_token"]
        document = await client.get("/v1/management/config")
        changed = document.json()["config"]
        changed["clients"]["chimera"]["volumes"]["ssd"]["label"] = "FAST_GAMES"
        validated = await client.post(
            "/v1/management/config/validate",
            headers={"Origin": ORIGIN, "X-CSRF-Token": csrf},
            json={"base_revision": document.json()["source_revision"], "config": changed},
        )
        saved = await client.put(
            "/v1/management/config",
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
    app, _ = management_app(tmp_path)
    marker = "raw-token-must-not-be-echoed"
    body = marker + ("x" * MAX_REQUEST_BYTES)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        response = await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN, "Content-Type": "application/json"},
            content=body,
        )

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "REQUEST_TOO_LARGE"
    assert marker not in response.text


@pytest.mark.asyncio
async def test_dashboard_stage_and_activate_without_publisher_reconnect(tmp_path) -> None:
    app, _ = management_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        login = await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        headers = {"Origin": ORIGIN, "X-CSRF-Token": login.json()["csrf_token"]}
        dashboard = await client.get("/v1/management/dashboard")
        staged = await client.post("/v1/management/releases/stage", headers=headers)
        release_name = staged.json()["release"]
        activated = await client.post(
            f"/v1/management/releases/{release_name}/activate",
            headers=headers,
            json={"confirmation": f"ACTIVATE {release_name}"},
        )
        old_admin = await client.get("/v1/admin/releases")

    assert dashboard.status_code == 200
    assert dashboard.json()["publisher"]["connection_status"] == "disconnected"
    assert staged.status_code == 200
    assert activated.status_code == 200
    assert activated.json()["release"] == release_name
    assert old_admin.status_code == 404


@pytest.mark.asyncio
async def test_publisher_manifest_contains_no_credentials(tmp_path) -> None:
    app, _ = management_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        response = await client.get("/v1/management/publisher/manifest")

    body = response.json()
    assert response.status_code == 200
    assert body["config_revision"]
    assert set(body) == {
        "schema_version",
        "config_revision",
        "portal",
        "target_iqn",
        "volumes",
    }
    assert "attachment" in response.headers["content-disposition"]


@pytest.mark.asyncio
async def test_config_save_blocks_stage_until_restart(tmp_path) -> None:
    app, _ = management_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        login = await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        headers = {"Origin": ORIGIN, "X-CSRF-Token": login.json()["csrf_token"]}
        document = (await client.get("/v1/management/config")).json()
        changed = document["config"]
        changed["clients"]["chimera"]["volumes"]["ssd"]["label"] = "NEW_LABEL"
        saved = await client.put(
            "/v1/management/config",
            headers=headers,
            json={"base_revision": document["source_revision"], "config": changed},
        )
        staged = await client.post("/v1/management/releases/stage", headers=headers)

    assert saved.status_code == 200
    assert saved.json()["restart_required"] is True
    assert staged.status_code == 409
    assert staged.json()["error"]["code"] == "RELEASE_NOT_READY"


@pytest.mark.asyncio
async def test_activation_blocks_unexpected_publisher_reconnect(tmp_path) -> None:
    app, _ = management_app(tmp_path)
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        login = await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        headers = {"Origin": ORIGIN, "X-CSRF-Token": login.json()["csrf_token"]}
        staged = await client.post("/v1/management/releases/stage", headers=headers)
        release_name = staged.json()["release"]
        config = app.state.runtime.config
        app.state.runtime.discovery_backend.sessions.append(
            SessionState(
                initiator_iqn=config.publisher.initiator_iqn,
                initiator_addr=str(config.publisher.source_ip),
                target_iqn=config.publisher.target_iqn,
            )
        )
        activated = await client.post(
            f"/v1/management/releases/{release_name}/activate",
            headers=headers,
            json={"confirmation": f"ACTIVATE {release_name}"},
        )

    assert activated.status_code == 409
    assert activated.json()["error"]["code"] == "PUBLISHER_SESSION_ACTIVE"


@pytest.mark.asyncio
async def test_incomplete_stage_retry_reuses_original_request_id(tmp_path) -> None:
    app, _ = management_app(tmp_path)
    backend = app.state.runtime.mutation_backend
    backend.fail_at_calls["create_snapshot"] = {2}
    async with httpx.AsyncClient(transport=transport(app), base_url=ORIGIN) as client:
        login = await client.post(
            "/v1/management/session",
            headers={"Origin": ORIGIN},
            json={"token": LOGIN_TOKEN},
        )
        headers = {"Origin": ORIGIN, "X-CSRF-Token": login.json()["csrf_token"]}
        failed = await client.post("/v1/management/releases/stage", headers=headers)
        incomplete = next(
            item for item in app.state.runtime.store.list() if item.status == "incomplete"
        )
        original_request_id = incomplete.request_id
        retried = await client.post("/v1/management/releases/stage", headers=headers)
        recovered = app.state.runtime.store.get(incomplete.name)

    assert failed.status_code == 503
    assert retried.status_code == 200
    assert retried.json()["release"] == incomplete.name
    assert recovered.request_id == original_request_id
    assert recovered.status == "staged"
