from __future__ import annotations

import argparse
import asyncio
import json
import os
from pathlib import Path

import uvicorn

from iscsi_reset_service.api import create_app
from iscsi_reset_service.backends import TrueNASBackend
from iscsi_reset_service.config import load_config
from iscsi_reset_service.configurator import ManagementRuntime
from iscsi_reset_service.configurator_api import create_management_app
from iscsi_reset_service.coordinator import ResetCoordinator
from iscsi_reset_service.logging_config import configure_logging
from iscsi_reset_service.release_manager import ReleaseManager
from iscsi_reset_service.runtime import Runtime
from iscsi_reset_service.security import generate_token, token_digest


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="iscsi-reset-service")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("serve-reset", help="run the SAN reset HTTPS API")
    subparsers.add_parser(
        "serve-management", help="run the loopback-only administration UI"
    )

    config_parser = subparsers.add_parser("config", help="configuration commands")
    config_sub = config_parser.add_subparsers(dest="config_command", required=True)
    config_validate = config_sub.add_parser("validate")
    config_validate.add_argument(
        "--path", default=os.environ.get("CONFIG_PATH", "/config/config.yaml")
    )

    token_parser = subparsers.add_parser("token", help="client token commands")
    token_sub = token_parser.add_subparsers(dest="token_command", required=True)
    token_generate = token_sub.add_parser("generate")
    token_generate.add_argument("client")
    token_generate.add_argument(
        "--config", default=os.environ.get("CONFIG_PATH", "/config/config.yaml")
    )
    token_generate.add_argument("--pepper-file", default=os.environ.get("TOKEN_PEPPER_FILE"))

    management_token_parser = subparsers.add_parser(
        "management-token", help="management login token commands"
    )
    management_token_sub = management_token_parser.add_subparsers(
        dest="management_token_command", required=True
    )
    management_token_generate = management_token_sub.add_parser("generate")
    management_token_generate.add_argument(
        "--pepper-file", default=os.environ.get("MANAGEMENT_TOKEN_PEPPER_FILE")
    )

    releases_parser = subparsers.add_parser("releases", help="release commands")
    releases_sub = releases_parser.add_subparsers(dest="releases_command", required=True)
    releases_sub.add_parser("validate")
    releases_sub.add_parser("audit")
    releases_sub.add_parser("list")
    return parser


async def _release_command(command: str) -> int:
    runtime = Runtime.from_env(role="cli")
    coordinator = ResetCoordinator(runtime.config, runtime.backend, runtime.store)
    manager = ReleaseManager(runtime.config, runtime.backend, runtime.store)
    try:
        if command == "validate":
            publisher = await manager.validate()
            clients = {}
            success = publisher.ready
            if runtime.store.active_release() is not None:
                for name in runtime.config.clients:
                    result = await coordinator.validate(name)
                    clients[name] = result.model_dump()
                    success = success and result.ready
            print(
                json.dumps(
                    {"publisher": publisher.model_dump(), "clients": clients},
                    indent=2,
                    ensure_ascii=False,
                )
            )
            return 0 if success else 1
        if command == "audit":
            stale = await coordinator.audit_stale_clones()
            print(
                json.dumps(
                    {
                        "active_release": (
                            runtime.store.active_release().name
                            if runtime.store.active_release()
                            else None
                        ),
                        "stale_unattached_clones": stale,
                        "releases": manager.list_releases().model_dump(),
                    },
                    indent=2,
                )
            )
            return 0
        print(json.dumps(manager.list_releases().model_dump(), indent=2))
        return 0
    finally:
        await runtime.backend.close()


def _server_tls(runtime: Runtime) -> dict:
    cert_file = os.environ.get("SERVER_CERT_FILE")
    key_file = os.environ.get("SERVER_KEY_FILE")
    if not isinstance(runtime.backend, TrueNASBackend):
        return {
            "ssl_certfile": cert_file,
            "ssl_keyfile": key_file,
        }
    if not cert_file or not key_file:
        raise ValueError("TrueNAS mode requires SERVER_CERT_FILE and SERVER_KEY_FILE")
    return {
        "ssl_certfile": cert_file,
        "ssl_keyfile": key_file,
    }


def _serve_reset() -> int:
    runtime = Runtime.from_env(role="reset")
    bind_host = os.environ.get("BIND_HOST", "10.20.40.10")
    bind_port = int(os.environ.get("BIND_PORT", "8443"))
    if isinstance(runtime.backend, TrueNASBackend) and (
        bind_host != str(runtime.config.portal.address) or bind_port != 8443
    ):
        raise ValueError(
            "TrueNAS reset API must bind only to the configured SAN portal IP on 8443"
        )
    uvicorn.run(
        create_app(runtime),
        host=bind_host,
        port=bind_port,
        proxy_headers=False,
        server_header=False,
        access_log=False,
        **_server_tls(runtime),
    )
    return 0


def _serve_management() -> int:
    runtime = ManagementRuntime.from_env()
    bind_host = os.environ.get("MANAGEMENT_BIND_HOST", "127.0.0.1")
    bind_port = int(os.environ.get("MANAGEMENT_BIND_PORT", "8445"))
    if bind_host != "127.0.0.1" or bind_port != 8445:
        raise ValueError("management UI must bind only to 127.0.0.1:8445")
    uvicorn.run(
        create_management_app(runtime),
        host=bind_host,
        port=bind_port,
        proxy_headers=False,
        server_header=False,
        access_log=False,
    )
    return 0


def _read_pepper(parser: argparse.ArgumentParser, path: str | None) -> bytes:
    if not path:
        parser.error("--pepper-file is required")
    pepper = Path(path).read_bytes().strip()
    if len(pepper) < 32:
        parser.error("pepper must be at least 32 bytes")
    return pepper


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    configure_logging(os.environ.get("LOG_LEVEL", "INFO"))

    if args.command == "serve-reset":
        return _serve_reset()
    if args.command == "serve-management":
        return _serve_management()

    if args.command == "config" and args.config_command == "validate":
        config = load_config(args.path)
        print(
            json.dumps(
                {
                    "valid": True,
                    "schema_version": config.schema_version,
                    "config_revision": config.revision,
                    "publisher_volumes": sorted(config.publisher.volumes),
                    "clients": sorted(config.clients),
                },
                indent=2,
            )
        )
        return 0

    if args.command == "token" and args.token_command == "generate":
        config = load_config(args.config)
        if args.client not in config.clients:
            parser.error(f"unknown client: {args.client}")
        pepper = _read_pepper(parser, args.pepper_file)
        token = generate_token()
        print(
            json.dumps(
                {
                    "client": args.client,
                    "token": token,
                    "token_digest": token_digest(token, pepper),
                    "warning": "The raw token is shown once; store it only on the assigned PC.",
                },
                indent=2,
            )
        )
        return 0

    if (
        args.command == "management-token"
        and args.management_token_command == "generate"
    ):
        pepper = _read_pepper(parser, args.pepper_file)
        token = generate_token()
        print(
            json.dumps(
                {
                    "token": token,
                    "token_digest": token_digest(token, pepper),
                    "warning": "The raw management token is shown once.",
                },
                indent=2,
            )
        )
        return 0

    if args.command == "releases":
        return asyncio.run(_release_command(args.releases_command))
    parser.error("unsupported command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
