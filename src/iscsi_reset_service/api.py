from __future__ import annotations

import ipaddress
import logging
import re
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass

from fastapi import Depends, FastAPI, Request
from fastapi.responses import JSONResponse

from iscsi_reset_service import __version__
from iscsi_reset_service.backends.base import BackendError
from iscsi_reset_service.coordinator import ResetCoordinator
from iscsi_reset_service.errors import (
    AuthenticationError,
    NotReadyError,
    ServiceError,
    SourceAddressError,
)
from iscsi_reset_service.models import (
    ClientResponse,
    ErrorBody,
    ErrorResponse,
    HealthResponse,
    ValidateResponse,
)
from iscsi_reset_service.runtime import Runtime
from iscsi_reset_service.security import verify_token

LOGGER = logging.getLogger("iscsi_reset_service.api")
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,96}$")


@dataclass(frozen=True, slots=True)
class AuthenticatedClient:
    name: str


def create_app(runtime: Runtime) -> FastAPI:
    coordinator = ResetCoordinator(runtime.config, runtime.backend, runtime.store)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        LOGGER.info(
            "service_started version=%s config_revision=%s",
            __version__,
            runtime.config.revision,
        )
        try:
            yield
        finally:
            await runtime.backend.close()

    app = FastAPI(
        title="iSCSI Reset Service",
        version=__version__,
        docs_url=None,
        redoc_url=None,
        openapi_url="/openapi.json",
        lifespan=lifespan,
    )
    app.state.runtime = runtime
    app.state.coordinator = coordinator

    @app.middleware("http")
    async def request_id_middleware(request: Request, call_next):
        supplied = request.headers.get("X-Request-ID", "")
        request.state.request_id = (
            supplied if REQUEST_ID_RE.fullmatch(supplied) else str(uuid.uuid4())
        )
        response = await call_next(request)
        response.headers["X-Request-ID"] = request.state.request_id
        return response

    @app.exception_handler(ServiceError)
    async def service_error_handler(request: Request, exc: ServiceError) -> JSONResponse:
        request_id = getattr(request.state, "request_id", str(uuid.uuid4()))
        LOGGER.warning(
            "request_failed request_id=%s code=%s status=%s",
            request_id,
            exc.code,
            exc.status_code,
        )
        body = ErrorResponse(
            error=ErrorBody(code=exc.code, message=exc.message, request_id=request_id)
        )
        return JSONResponse(status_code=exc.status_code, content=body.model_dump())

    @app.exception_handler(BackendError)
    async def backend_error_handler(request: Request, exc: BackendError) -> JSONResponse:
        LOGGER.exception("backend_error")
        mapped = NotReadyError(str(exc))
        return await service_error_handler(request, mapped)

    async def authenticated(request: Request) -> AuthenticatedClient:
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            raise AuthenticationError()
        token = authorization[7:].strip()
        if not token:
            raise AuthenticationError()
        # Check every digest so the response time does not disclose where a
        # valid client happens to appear in the YAML file.
        matches = [
            name
            for name, client in runtime.config.clients.items()
            if verify_token(token, client.token_digest, runtime.pepper)
        ]
        if len(matches) != 1:
            raise AuthenticationError()
        client_name = matches[0]

        source = request.client.host if request.client else ""
        if runtime.allow_test_source_header:
            source = request.headers.get("X-Test-Source-IP", source)
        try:
            address = ipaddress.ip_address(source)
            if address.version == 6 and address.ipv4_mapped:
                address = address.ipv4_mapped
        except ValueError as exc:
            raise SourceAddressError() from exc
        if address != runtime.config.clients[client_name].source_ip:
            raise SourceAddressError()
        return AuthenticatedClient(client_name)

    auth_dependency = Depends(authenticated)

    @app.get("/healthz", response_model=HealthResponse)
    async def health() -> HealthResponse:
        return HealthResponse(
            status="ok", version=__version__, config_revision=runtime.config.revision
        )

    @app.get("/readyz", response_model=HealthResponse)
    async def ready() -> HealthResponse:
        try:
            runtime.store.check(require_active=True)
            await runtime.backend.ping()
        except Exception as exc:
            raise NotReadyError("Release state or TrueNAS API is unavailable") from exc
        return HealthResponse(
            status="ready", version=__version__, config_revision=runtime.config.revision
        )

    @app.get("/v1/client", response_model=ClientResponse)
    async def client_configuration(
        auth: AuthenticatedClient = auth_dependency,
    ) -> ClientResponse:
        return await coordinator.public_client(auth.name)

    @app.post("/v1/validate", response_model=ValidateResponse)
    async def validate_client(
        auth: AuthenticatedClient = auth_dependency,
    ) -> ValidateResponse:
        return await coordinator.validate(auth.name)

    @app.post("/v1/prepare", response_model=ClientResponse)
    async def prepare_client(
        auth: AuthenticatedClient = auth_dependency,
    ) -> ClientResponse:
        return await coordinator.prepare(auth.name)

    return app
