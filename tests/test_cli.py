from __future__ import annotations

import json

import pytest

from iscsi_reset_service.backends.truenas import TrueNASBackend
from iscsi_reset_service.cli import _serve_management, _server_tls, main
from iscsi_reset_service.configurator import ManagementRuntime
from iscsi_reset_service.runtime import Runtime
from iscsi_reset_service.security import verify_token


class UnusedRpc:
    async def close(self):
        return None


def test_reset_server_uses_only_server_certificate(
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

    tls = _server_tls(runtime)

    assert "ssl_cert_reqs" not in tls
    assert "ssl_ca_certs" not in tls


def test_management_token_generate_outputs_verifiable_digest(
    tmp_path, capsys
) -> None:
    pepper = b"management-cli-pepper-material-123456789"
    pepper_file = tmp_path / "pepper"
    pepper_file.write_bytes(pepper)

    result = main(
        ["management-token", "generate", "--pepper-file", str(pepper_file)]
    )
    payload = json.loads(capsys.readouterr().out)

    assert result == 0
    assert verify_token(payload["token"], payload["token_digest"], pepper)
    assert "shown once" in payload["warning"]


@pytest.mark.parametrize(
    ("host", "port"),
    [("0.0.0.0", "8445"), ("127.0.0.1", "8082")],
)
def test_management_rejects_non_loopback_or_nonstandard_bind(
    monkeypatch, host, port
) -> None:
    monkeypatch.setattr(
        ManagementRuntime,
        "from_env",
        classmethod(lambda cls: object()),
    )
    monkeypatch.setenv("MANAGEMENT_BIND_HOST", host)
    monkeypatch.setenv("MANAGEMENT_BIND_PORT", port)

    with pytest.raises(ValueError, match="127.0.0.1:8445"):
        _serve_management()
