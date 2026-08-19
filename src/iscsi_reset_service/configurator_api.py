from __future__ import annotations

import ipaddress
import logging
import secrets
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, model_validator

from iscsi_reset_service import __version__
from iscsi_reset_service.config import dump_config
from iscsi_reset_service.configurator import (
    MAX_CONFIG_BYTES,
    ConfiguratorError,
    ConfiguratorRuntime,
)
from iscsi_reset_service.security import generate_token, token_digest, verify_token

LOGGER = logging.getLogger("iscsi_reset_service.configurator_api")
COOKIE_NAME = "iscsi_configurator_session"
IDLE_SECONDS = 30 * 60
MAX_SESSION_SECONDS = 8 * 60 * 60
MAX_REQUEST_BYTES = MAX_CONFIG_BYTES + 64 * 1024


class ApiRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LoginRequest(ApiRequest):
    token: str = Field(min_length=1, max_length=512)


class DraftRequest(ApiRequest):
    base_revision: str | None = Field(default=None, pattern=r"^[0-9a-f]{16}$")
    config: dict | None = None
    yaml: str | None = Field(default=None, max_length=MAX_CONFIG_BYTES)

    @model_validator(mode="after")
    def exactly_one_representation(self) -> DraftRequest:
        if (self.config is None) == (self.yaml is None):
            raise ValueError("provide exactly one of config or yaml")
        return self


class TokenRequest(ApiRequest):
    kind: Literal["client", "admin"]


@dataclass(slots=True)
class Session:
    created_at: float
    last_seen: float
    csrf_token: str


class SessionStore:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}

    def create(self) -> tuple[str, Session]:
        now = time.monotonic()
        session_id = secrets.token_urlsafe(32)
        session = Session(now, now, secrets.token_urlsafe(24))
        self.sessions[session_id] = session
        return session_id, session

    def get(self, session_id: str) -> Session | None:
        now = time.monotonic()
        session = self.sessions.get(session_id)
        if session is None:
            return None
        if (
            now - session.last_seen > IDLE_SECONDS
            or now - session.created_at > MAX_SESSION_SECONDS
        ):
            self.sessions.pop(session_id, None)
            return None
        session.last_seen = now
        return session

    def delete(self, session_id: str) -> None:
        self.sessions.pop(session_id, None)


def create_configurator_app(runtime: ConfiguratorRuntime) -> FastAPI:
    sessions = SessionStore()
    static_dir = Path(__file__).with_name("static")

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        LOGGER.info(
            "configurator_started version=%s startup_revision=%s",
            __version__,
            runtime.repository.startup_revision,
        )
        try:
            yield
        finally:
            await runtime.backend.close()

    app = FastAPI(
        title="iSCSI Reset Configurator",
        version=__version__,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    app.state.runtime = runtime
    app.state.sessions = sessions
    app.mount("/assets", StaticFiles(directory=static_dir), name="assets")

    @app.middleware("http")
    async def security_middleware(request: Request, call_next):
        request.state.request_id = str(uuid.uuid4())
        if not _is_loopback_request(request):
            response = _error_response(
                request, ConfiguratorError(403, "LOOPBACK_REQUIRED", "Loopback access required")
            )
        elif request.method in {"POST", "PUT", "PATCH", "DELETE"} and not _valid_origin(
            request
        ):
            response = _error_response(
                request,
                ConfiguratorError(403, "ORIGIN_MISMATCH", "Origin must match loopback Host"),
            )
        else:
            content_length = request.headers.get("content-length")
            try:
                declared_length = int(content_length) if content_length else None
            except ValueError:
                response = _error_response(
                    request,
                    ConfiguratorError(400, "REQUEST_INVALID", "Invalid Content-Length"),
                )
            else:
                body = await request.body()
                actual_length = len(body)
                too_large = (
                    declared_length is not None and declared_length > MAX_REQUEST_BYTES
                ) or actual_length > MAX_REQUEST_BYTES
                if too_large:
                    response = _error_response(
                        request,
                        ConfiguratorError(
                            413, "REQUEST_TOO_LARGE", "Request is too large"
                        ),
                    )
                else:
                    response = await call_next(request)
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "connect-src 'self'; img-src 'self'; frame-ancestors 'none'; "
            "object-src 'none'; base-uri 'none'; form-action 'self'"
        )
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Request-ID"] = request.state.request_id
        return response

    @app.exception_handler(ConfiguratorError)
    async def configurator_error_handler(
        request: Request, exc: ConfiguratorError
    ) -> JSONResponse:
        LOGGER.warning(
            "configurator_request_failed request_id=%s code=%s status=%s",
            request.state.request_id,
            exc.code,
            exc.status_code,
        )
        return _error_response(request, exc)

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request, _: RequestValidationError
    ) -> JSONResponse:
        return _error_response(
            request,
            ConfiguratorError(422, "REQUEST_INVALID", "Request body is invalid"),
        )

    def authenticated(request: Request) -> Session:
        session_id = request.cookies.get(COOKIE_NAME, "")
        session = sessions.get(session_id)
        if session is None:
            raise ConfiguratorError(401, "UNAUTHORIZED", "Configurator login required")
        return session

    auth_dependency = Depends(authenticated)

    def csrf_protected(
        request: Request, session: Session = auth_dependency
    ) -> Session:
        supplied = request.headers.get("X-CSRF-Token", "")
        if not supplied or not secrets.compare_digest(supplied, session.csrf_token):
            raise ConfiguratorError(403, "CSRF_MISMATCH", "CSRF token is invalid")
        return session

    auth = auth_dependency
    csrf = Depends(csrf_protected)

    @app.get("/", include_in_schema=False)
    async def index() -> FileResponse:
        return FileResponse(static_dir / "index.html", media_type="text/html")

    @app.get("/healthz")
    async def health() -> dict[str, object]:
        return {
            "status": "ok",
            "version": __version__,
            "startup_revision": runtime.repository.startup_revision,
        }

    @app.post("/v1/configurator/session")
    async def login(body: LoginRequest, response: Response) -> dict[str, object]:
        if not verify_token(body.token, runtime.login_digest, runtime.admin_pepper):
            raise ConfiguratorError(401, "UNAUTHORIZED", "Unknown configurator token")
        session_id, session = sessions.create()
        response.set_cookie(
            COOKIE_NAME,
            session_id,
            max_age=MAX_SESSION_SECONDS,
            httponly=True,
            secure=False,
            samesite="strict",
            path="/",
        )
        return {
            "csrf_token": session.csrf_token,
            "idle_seconds": IDLE_SECONDS,
            "max_session_seconds": MAX_SESSION_SECONDS,
        }

    @app.delete("/v1/configurator/session")
    async def logout(
        request: Request, response: Response, _: Session = csrf
    ) -> Response:
        sessions.delete(request.cookies.get(COOKIE_NAME, ""))
        response.delete_cookie(COOKIE_NAME, path="/")
        response.status_code = 204
        return response

    @app.get("/v1/configurator/status")
    async def status(session: Session = auth) -> dict[str, object]:
        document = runtime.repository.read()
        saved_revision = document.config.revision if document.config else None
        return {
            "version": __version__,
            "csrf_token": session.csrf_token,
            "startup_revision": runtime.repository.startup_revision,
            "saved_revision": saved_revision,
            "source_revision": document.source_revision,
            "config_exists": document.exists,
            "config_valid": document.config is not None,
            "config_error": document.error,
            "restart_required": runtime.repository.startup_revision != saved_revision,
        }

    @app.get("/v1/configurator/discovery")
    async def discovery(_: Session = auth) -> dict[str, object]:
        return (await runtime.repository.discovery()).as_dict()

    @app.get("/v1/configurator/config")
    async def get_config(_: Session = auth) -> dict[str, object]:
        return runtime.repository.read().as_dict()

    @app.post("/v1/configurator/config/validate")
    async def validate_config(body: DraftRequest, _: Session = csrf) -> dict[str, object]:
        result = (
            await runtime.repository.validate_object(body.config)
            if body.config is not None
            else await runtime.repository.validate_yaml(body.yaml or "")
        )
        return result.as_dict()

    @app.put("/v1/configurator/config")
    async def save_config(body: DraftRequest, _: Session = csrf) -> dict[str, object]:
        source = body.yaml
        if body.config is not None:
            validated = await runtime.repository.validate_object(body.config)
            source = dump_config(validated.config)
        return (await runtime.repository.save_yaml(source or "", body.base_revision)).as_dict()

    @app.post("/v1/configurator/tokens")
    async def create_token(body: TokenRequest, _: Session = csrf) -> dict[str, str]:
        raw = generate_token()
        pepper = runtime.client_pepper if body.kind == "client" else runtime.admin_pepper
        return {
            "kind": body.kind,
            "token": raw,
            "token_digest": token_digest(raw, pepper),
            "warning": "Raw token is shown once and is not retained by the service.",
        }

    return app


def _error_response(request: Request, exc: ConfiguratorError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": {
                "code": exc.code,
                "message": exc.message,
                "request_id": getattr(request.state, "request_id", str(uuid.uuid4())),
            }
        },
    )


def _is_loopback_request(request: Request) -> bool:
    host = _hostname(request.headers.get("host", ""))
    source = request.client.host if request.client else ""
    return _is_loopback_name(host) and _is_loopback_name(source)


def _valid_origin(request: Request) -> bool:
    origin = request.headers.get("origin", "")
    if not origin:
        return False
    parsed = urlsplit(origin)
    host = request.headers.get("host", "").lower()
    return parsed.scheme == request.url.scheme and parsed.netloc.lower() == host


def _hostname(value: str) -> str:
    try:
        return urlsplit(f"//{value}").hostname or ""
    except ValueError:
        return ""


def _is_loopback_name(value: str) -> bool:
    if value.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(value).is_loopback
    except ValueError:
        return False
