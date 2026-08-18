from __future__ import annotations

from abc import ABC, abstractmethod

from iscsi_reset_service.models import DatasetState, ExtentState, SessionState, TargetLunState


class BackendError(RuntimeError):
    """Storage backend operation failed."""


class StorageBackend(ABC):
    @abstractmethod
    async def ping(self) -> None: ...

    @abstractmethod
    async def close(self) -> None: ...

    @abstractmethod
    async def list_sessions(self) -> list[SessionState]: ...

    @abstractmethod
    async def snapshot_exists(self, snapshot: str) -> bool: ...

    @abstractmethod
    async def dataset(self, dataset: str) -> DatasetState | None: ...

    @abstractmethod
    async def clone_snapshot(
        self, snapshot: str, destination: str, properties: dict[str, str]
    ) -> None: ...

    @abstractmethod
    async def create_snapshot(self, dataset: str, name: str) -> None: ...

    @abstractmethod
    async def rollback_snapshot(self, snapshot: str) -> None: ...

    @abstractmethod
    async def get_extent(self, extent_id: int) -> ExtentState: ...

    @abstractmethod
    async def update_extent(
        self, extent_id: int, *, enabled: bool | None = None, disk: str | None = None
    ) -> ExtentState: ...

    @abstractmethod
    async def target_luns(self, target_iqn: str) -> list[TargetLunState]: ...

    @abstractmethod
    async def list_datasets(self, prefix: str) -> list[DatasetState]: ...

