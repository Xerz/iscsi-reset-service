from __future__ import annotations

import ssl

from iscsi_reset_service.backends.truenas import TrueNASBackend
from iscsi_reset_service.cli import _server_tls
from iscsi_reset_service.runtime import Runtime


class UnusedRpc:
    async def close(self):
        return None


def test_admin_server_requires_client_certificate_ca(
    monkeypatch, service_config, release_store
) -> None:
    monkeypatch.setenv("SERVER_CERT_FILE", "/tls/server.crt")
    monkeypatch.setenv("SERVER_KEY_FILE", "/tls/server.key")
    monkeypatch.setenv("ADMIN_CLIENT_CA_FILE", "/tls/client-ca.crt")
    runtime = Runtime(
        service_config,
        TrueNASBackend(UnusedRpc()),
        b"x" * 32,
        release_store,
        admin_pepper=b"y" * 32,
    )

    tls = _server_tls(runtime, admin=True)

    assert tls["ssl_cert_reqs"] == ssl.CERT_REQUIRED
    assert tls["ssl_ca_certs"] == "/tls/client-ca.crt"


def test_reset_server_does_not_request_admin_client_certificate(
    monkeypatch, service_config, release_store
) -> None:
    monkeypatch.setenv("SERVER_CERT_FILE", "/tls/server.crt")
    monkeypatch.setenv("SERVER_KEY_FILE", "/tls/server.key")
    runtime = Runtime(
        service_config,
        TrueNASBackend(UnusedRpc()),
        b"x" * 32,
        release_store,
    )

    tls = _server_tls(runtime, admin=False)

    assert "ssl_cert_reqs" not in tls
    assert "ssl_ca_certs" not in tls
