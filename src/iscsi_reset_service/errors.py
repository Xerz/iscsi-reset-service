from __future__ import annotations


class ServiceError(RuntimeError):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


class AuthenticationError(ServiceError):
    def __init__(self) -> None:
        super().__init__(401, "UNAUTHORIZED", "Unknown or missing reset token")


class SourceAddressError(ServiceError):
    def __init__(self) -> None:
        super().__init__(403, "SOURCE_IP_MISMATCH", "Token is not valid from this source address")


class SessionActiveError(ServiceError):
    def __init__(self) -> None:
        super().__init__(409, "SESSION_ACTIVE", "The client target still has an active session")


class ClientBusyError(ServiceError):
    def __init__(self) -> None:
        super().__init__(423, "CLIENT_BUSY", "A reset is already running for this client")


class ReleaseBusyError(ServiceError):
    def __init__(self) -> None:
        super().__init__(423, "RELEASE_BUSY", "A release operation is already running")


class ReleaseConflictError(ServiceError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(409, code, message)


class PublisherSessionActiveError(ServiceError):
    def __init__(self) -> None:
        super().__init__(
            409,
            "PUBLISHER_SESSION_ACTIVE",
            "The publisher target still has an active session",
        )


class NotReadyError(ServiceError):
    def __init__(self, message: str = "Storage was not brought to a safe ready state") -> None:
        super().__init__(503, "NOT_READY", message)
