from __future__ import annotations

import httpx
import pytest
from conftest import ADMIN_PEPPER, ADMIN_TOKEN, PEPPER

from iscsi_reset_service.admin_api import create_admin_app
from iscsi_reset_service.runtime import Runtime


def transport_for(
    service_config, backend, release_store, source_ip: str = "192.168.1.101"
):
    runtime = Runtime(
        service_config,
        backend,
        PEPPER,
        release_store,
        admin_pepper=ADMIN_PEPPER,
    )
    return httpx.ASGITransport(
        app=create_admin_app(runtime), client=(source_ip, 12345)
    )


@pytest.mark.asyncio
async def test_admin_api_rejects_unknown_token(
    service_config, backend, release_store
) -> None:
    async with httpx.AsyncClient(
        transport=transport_for(service_config, backend, release_store),
        base_url="https://test",
    ) as client:
        response = await client.get(
            "/v1/admin/releases", headers={"Authorization": "Bearer wrong"}
        )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


@pytest.mark.asyncio
async def test_admin_api_rejects_wrong_management_ip(
    service_config, backend, release_store
) -> None:
    async with httpx.AsyncClient(
        transport=transport_for(
            service_config, backend, release_store, "192.168.1.102"
        ),
        base_url="https://test",
    ) as client:
        response = await client.get(
            "/v1/admin/releases",
            headers={"Authorization": f"Bearer {ADMIN_TOKEN}"},
        )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "SOURCE_IP_MISMATCH"


@pytest.mark.asyncio
async def test_admin_stage_and_activate_contract(
    service_config, backend, release_store
) -> None:
    headers = {
        "Authorization": f"Bearer {ADMIN_TOKEN}",
        "X-Request-ID": "admin-stage",
    }
    async with httpx.AsyncClient(
        transport=transport_for(service_config, backend, release_store),
        base_url="https://test",
    ) as client:
        staged = await client.post("/v1/admin/releases/stage", headers=headers)
        release_name = staged.json()["release"]
        activated = await client.post(
            f"/v1/admin/releases/{release_name}/activate",
            headers={**headers, "X-Request-ID": "admin-activate"},
            json={"confirmation": f"ACTIVATE {release_name}"},
        )
        listed = await client.get("/v1/admin/releases", headers=headers)

    assert staged.status_code == 200
    assert activated.status_code == 200
    assert activated.json() == {
        "schema_version": 1,
        "status": "active",
        "release": release_name,
    }
    assert listed.json()["active_release"] == release_name
