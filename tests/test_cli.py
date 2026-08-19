from __future__ import annotations

import json
import ssl

import pytest

from iscsi_reset_service.backends.truenas import TrueNASBackend
from iscsi_reset_service.cli import _serve_configurator, _server_tls, main
from iscsi_reset_service.configurator import ConfiguratorRuntime
from iscsi_reset_service.runtime import Runtime
from iscsi_reset_service.security import verify_token


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


def test_configurator_token_generate_outputs_verifiable_digest(
    tmp_path, capsys
) -> None:
    pepper = b"configurator-cli-pepper-material-123456789"
    pepper_file = tmp_path / "pepper"
    pepper_file.write_bytes(pepper)

    result = main(
        ["configurator-token", "generate", "--pepper-file", str(pepper_file)]
    )
    payload = json.loads(capsys.readouterr().out)

    assert result == 0
    assert verify_token(payload["token"], payload["token_digest"], pepper)
    assert "shown once" in payload["warning"]


@pytest.mark.parametrize(
    ("host", "port"),
    [("0.0.0.0", "8445"), ("127.0.0.1", "8082")],
)
def test_configurator_rejects_non_loopback_or_nonstandard_bind(
    monkeypatch, host, port
) -> None:
    monkeypatch.setattr(
        ConfiguratorRuntime,
        "from_env",
        classmethod(lambda cls: object()),
    )
    monkeypatch.setenv("CONFIGURATOR_BIND_HOST", host)
    monkeypatch.setenv("CONFIGURATOR_BIND_PORT", port)

    with pytest.raises(ValueError, match="127.0.0.1:8445"):
        _serve_configurator()
