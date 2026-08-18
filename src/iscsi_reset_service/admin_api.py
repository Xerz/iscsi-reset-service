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
from iscsi_reset_service.errors import (
    AdminAuthenticationError,
    AdminSourceAddressError,
    NotReadyError,
    ServiceError,
)
from iscsi_reset_service.models import (
    ActivateRequest,
    ErrorBody,
    ErrorResponse,
    HealthResponse,
    PublisherResponse,
    ReleaseActivateResponse,
    ReleaseListResponse,
    ReleaseStageResponse,
    ReleaseValidateResponse,
)
from iscsi_reset_service.release_manager import ReleaseManager
from iscsi_reset_service.release_store import ReleaseStoreError
from iscsi_reset_service.runtime import Runtime
from iscsi_reset_service.security import verify_token

LOGGER = logging.getLogger("iscsi_reset_service.admin_api")
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,96}$")


@dataclass(frozen=True, slots=True)
class AuthenticatedAdmin:
    source_ip: str


def create_admin_app(runtime: Runtime) -> FastAPI:
    if runtime.admin_pepper is None:
        raise ValueError("admin API requires ADMIN_TOKEN_PEPPER_FILE")
    manager = ReleaseManager(runtime.config, runtime.backend, runtime.store)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        LOGGER.info(
            "admin_service_started version=%s config_revision=%s",
            __version__,
            runtime.config.revision,
        )
        try:
            yield
        finally:
            await runtime.backend.close()

    app = FastAPI(
        title="iSCSI Release Administration",
        version=__version__,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    app.state.runtime = runtime
    app.state.release_manager = manager

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
            "admin_request_failed request_id=%s code=%s status=%s",
            request_id,
            exc.code,
            exc.status_code,
        )
        body = ErrorResponse(
            error=ErrorBody(code=exc.code, message=exc.message, request_id=request_id)
        )
        return JSONResponse(status_code=exc.status_code, content=body.model_dump())

    @app.exception_handler(BackendError)
    @app.exception_handler(ReleaseStoreError)
    async def dependency_error_handler(request: Request, exc: Exception) -> JSONResponse:
        LOGGER.exception("admin_dependency_error")
        return await service_error_handler(request, NotReadyError(str(exc)))

    async def authenticated(request: Request) -> AuthenticatedAdmin:
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            raise AdminAuthenticationError()
        token = authorization[7:].strip()
        if not token or not verify_token(
            token, runtime.config.admin_api.token_digest, runtime.admin_pepper or b""
        ):
            raise AdminAuthenticationError()

        source = request.client.host if request.client else ""
        if runtime.allow_test_source_header:
            source = request.headers.get("X-Test-Source-IP", source)
        try:
            address = ipaddress.ip_address(source)
            if address.version == 6 and address.ipv4_mapped:
                address = address.ipv4_mapped
        except ValueError as exc:
            raise AdminSourceAddressError() from exc
        if address != runtime.config.admin_api.allowed_source_ip:
            raise AdminSourceAddressError()
        return AuthenticatedAdmin(str(address))

    auth_dependency = Depends(authenticated)

    @app.get("/healthz", response_model=HealthResponse)
    async def health() -> HealthResponse:
        return HealthResponse(
            status="ok", version=__version__, config_revision=runtime.config.revision
        )

    @app.get("/readyz", response_model=HealthResponse)
    async def ready() -> HealthResponse:
        try:
            runtime.store.check(require_active=False)
            await runtime.backend.ping()
        except Exception as exc:
            raise NotReadyError("Release state or TrueNAS API is unavailable") from exc
        return HealthResponse(
            status="ready", version=__version__, config_revision=runtime.config.revision
        )

    @app.get("/v1/admin/publisher", response_model=PublisherResponse)
    async def publisher(
        _: AuthenticatedAdmin = auth_dependency,
    ) -> PublisherResponse:
        return await manager.publisher_configuration()

    @app.get("/v1/admin/releases", response_model=ReleaseListResponse)
    async def releases(
        _: AuthenticatedAdmin = auth_dependency,
    ) -> ReleaseListResponse:
        return manager.list_releases()

    @app.post("/v1/admin/releases/validate", response_model=ReleaseValidateResponse)
    async def validate(
        _: AuthenticatedAdmin = auth_dependency,
    ) -> ReleaseValidateResponse:
        return await manager.validate()

    @app.post("/v1/admin/releases/stage", response_model=ReleaseStageResponse)
    async def stage(
        request: Request, admin: AuthenticatedAdmin = auth_dependency
    ) -> ReleaseStageResponse:
        return await manager.stage(request.state.request_id, admin.source_ip)

    @app.post(
        "/v1/admin/releases/{release_name}/activate",
        response_model=ReleaseActivateResponse,
    )
    async def activate(
        release_name: str,
        body: ActivateRequest,
        request: Request,
        admin: AuthenticatedAdmin = auth_dependency,
    ) -> ReleaseActivateResponse:
        return await manager.activate(
            release_name,
            body.confirmation,
            request.state.request_id,
            admin.source_ip,
        )

    return app
