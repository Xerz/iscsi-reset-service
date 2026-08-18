from __future__ import annotations

import httpx
import pytest
from conftest import CHIMERA_TOKEN, PEPPER

from iscsi_reset_service.api import create_app
from iscsi_reset_service.models import SessionState
from iscsi_reset_service.release_store import ReleaseStore
from iscsi_reset_service.runtime import Runtime


def transport_for(service_config, backend, release_store, source_ip: str = "10.20.40.101"):
    app = create_app(Runtime(service_config, backend, PEPPER, release_store))
    return httpx.ASGITransport(app=app, client=(source_ip, 12345))


@pytest.mark.asyncio
async def test_unknown_token_is_401(service_config, backend, release_store) -> None:
    async with httpx.AsyncClient(
        transport=transport_for(service_config, backend, release_store), base_url="http://test"
    ) as client:
        response = await client.get(
            "/v1/client", headers={"Authorization": "Bearer definitely-wrong"}
        )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


@pytest.mark.asyncio
async def test_valid_token_from_wrong_ip_is_403(
    service_config, backend, release_store
) -> None:
    async with httpx.AsyncClient(
        transport=transport_for(service_config, backend, release_store, "10.20.40.102"),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/v1/client", headers={"Authorization": f"Bearer {CHIMERA_TOKEN}"}
        )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "SOURCE_IP_MISMATCH"


@pytest.mark.asyncio
async def test_prepare_contract_hides_release_and_snapshot_paths(
    service_config, backend, release_store
) -> None:
    async with httpx.AsyncClient(
        transport=transport_for(service_config, backend, release_store), base_url="http://test"
    ) as client:
        response = await client.post(
            "/v1/prepare",
            headers={
                "Authorization": f"Bearer {CHIMERA_TOKEN}",
                "X-Request-ID": "boot-test-1",
            },
        )
    assert response.status_code == 200
    assert response.headers["X-Request-ID"] == "boot-test-1"
    payload = response.json()
    assert set(payload) == {"schema_version", "status", "portal", "target_iqn", "volumes"}
    assert "release" not in str(payload).lower()
    assert "snapshot" not in str(payload).lower()


@pytest.mark.asyncio
async def test_active_session_is_409(service_config, backend, release_store) -> None:
    backend.sessions.append(
        SessionState(
            initiator_iqn="iqn.1991-05.com.microsoft:chimera",
            initiator_addr="10.20.40.101",
            target_iqn="iqn.2026-08.lab.games:chimera",
        )
    )
    async with httpx.AsyncClient(
        transport=transport_for(service_config, backend, release_store), base_url="http://test"
    ) as client:
        response = await client.post(
            "/v1/prepare", headers={"Authorization": f"Bearer {CHIMERA_TOKEN}"}
        )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "SESSION_ACTIVE"


@pytest.mark.asyncio
async def test_concurrent_prepare_is_423(service_config, backend, release_store) -> None:
    transport = transport_for(service_config, backend, release_store)
    app = transport.app
    lock = app.state.coordinator._locks["chimera"]
    await lock.acquire()
    try:
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.post(
                "/v1/prepare", headers={"Authorization": f"Bearer {CHIMERA_TOKEN}"}
            )
    finally:
        lock.release()
    assert response.status_code == 423
    assert response.json()["error"]["code"] == "CLIENT_BUSY"


@pytest.mark.asyncio
async def test_readyz_fails_closed_without_active_release(
    service_config, backend, tmp_path
) -> None:
    empty_store = ReleaseStore(tmp_path / "empty.sqlite3")
    empty_store.initialize()
    async with httpx.AsyncClient(
        transport=transport_for(service_config, backend, empty_store),
        base_url="http://test",
    ) as client:
        health = await client.get("/healthz")
        ready = await client.get("/readyz")

    assert health.status_code == 200
    assert ready.status_code == 503
    assert ready.json()["error"]["code"] == "NOT_READY"
