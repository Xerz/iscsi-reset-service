from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

DATABASE_SCHEMA_VERSION = 1


class ReleaseStoreError(RuntimeError):
    """Persistent release state is missing, corrupt, or internally inconsistent."""


@dataclass(frozen=True, slots=True)
class ReleaseRecord:
    name: str
    status: str
    request_id: str
    created_at: str
    completed_at: str | None
    snapshots: dict[str, str]
    active: bool = False


class ReleaseStore:
    def __init__(self, path: str | Path, *, read_only: bool = False) -> None:
        self.path = Path(path)
        self.read_only = read_only

    def initialize(self) -> None:
        if self.read_only:
            if not self.path.is_file():
                raise ReleaseStoreError("release database does not exist")
            with self._connect() as connection:
                self._check_schema(connection)
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS releases (
                    name TEXT PRIMARY KEY,
                    status TEXT NOT NULL CHECK (status IN ('incomplete', 'staged')),
                    request_id TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL,
                    completed_at TEXT
                );
                CREATE TABLE IF NOT EXISTS release_volumes (
                    release_name TEXT NOT NULL REFERENCES releases(name),
                    volume_name TEXT NOT NULL,
                    snapshot TEXT NOT NULL UNIQUE,
                    PRIMARY KEY (release_name, volume_name)
                );
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS operations (
                    request_id TEXT PRIMARY KEY,
                    operation TEXT NOT NULL,
                    release_name TEXT NOT NULL,
                    response_json TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS audit_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    request_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    release_name TEXT,
                    result TEXT NOT NULL,
                    source_ip TEXT,
                    details TEXT NOT NULL
                );
                """
            )
            current = int(connection.execute("PRAGMA user_version").fetchone()[0])
            if current == 0:
                connection.execute(f"PRAGMA user_version={DATABASE_SCHEMA_VERSION}")
            elif current != DATABASE_SCHEMA_VERSION:
                raise ReleaseStoreError(
                    f"unsupported release database schema {current}; "
                    f"expected {DATABASE_SCHEMA_VERSION}"
                )
            connection.commit()

    def check(self, *, require_active: bool) -> None:
        with self._connect() as connection:
            self._check_schema(connection)
            if require_active and self.active_release() is None:
                raise ReleaseStoreError("no active release is configured")

    def reserve(self, name: str, request_id: str) -> ReleaseRecord:
        self._require_writable()
        now = _now()
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                pending = connection.execute(
                    "SELECT name, request_id FROM releases WHERE status = 'incomplete'"
                ).fetchone()
                if pending and pending["request_id"] != request_id:
                    raise ReleaseStoreError(
                        f"incomplete release {pending['name']} must be resumed first"
                    )
                connection.execute(
                    """
                    INSERT INTO releases(name, status, request_id, created_at)
                    VALUES (?, 'incomplete', ?, ?)
                    ON CONFLICT(request_id) DO NOTHING
                    """,
                    (name, request_id, now),
                )
                row = connection.execute(
                    "SELECT name FROM releases WHERE request_id = ?", (request_id,)
                ).fetchone()
                if row is None:
                    raise ReleaseStoreError("failed to reserve release request")
                connection.commit()
                return self.get(str(row["name"]))
        except sqlite3.IntegrityError as exc:
            raise ReleaseStoreError(f"release reservation conflict: {name}") from exc

    def by_request_id(self, request_id: str) -> ReleaseRecord | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT name FROM releases WHERE request_id = ?", (request_id,)
            ).fetchone()
        return self.get(str(row["name"])) if row else None

    def add_snapshot(self, release_name: str, volume_name: str, snapshot: str) -> None:
        self._require_writable()
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                release = connection.execute(
                    "SELECT status FROM releases WHERE name = ?", (release_name,)
                ).fetchone()
                if release is None or release["status"] != "incomplete":
                    raise ReleaseStoreError("snapshots can only be added to incomplete releases")
                existing = connection.execute(
                    """
                    SELECT snapshot FROM release_volumes
                    WHERE release_name = ? AND volume_name = ?
                    """,
                    (release_name, volume_name),
                ).fetchone()
                if existing and existing["snapshot"] != snapshot:
                    raise ReleaseStoreError(
                        f"immutable snapshot mapping mismatch for {release_name}/{volume_name}"
                    )
                connection.execute(
                    """
                    INSERT OR IGNORE INTO release_volumes(release_name, volume_name, snapshot)
                    VALUES (?, ?, ?)
                    """,
                    (release_name, volume_name, snapshot),
                )
                connection.commit()
        except sqlite3.IntegrityError as exc:
            raise ReleaseStoreError(
                f"snapshot is already owned by another release: {snapshot}"
            ) from exc

    def mark_staged(self, release_name: str, expected_volumes: set[str]) -> ReleaseRecord:
        self._require_writable()
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actual = {
                str(row["volume_name"])
                for row in connection.execute(
                    "SELECT volume_name FROM release_volumes WHERE release_name = ?",
                    (release_name,),
                )
            }
            if actual != expected_volumes:
                raise ReleaseStoreError(
                    f"release {release_name} volume set is incomplete: {sorted(actual)}"
                )
            connection.execute(
                """
                UPDATE releases SET status = 'staged', completed_at = ?
                WHERE name = ? AND status IN ('incomplete', 'staged')
                """,
                (_now(), release_name),
            )
            connection.commit()
        return self.get(release_name)

    def activate(self, release_name: str, request_id: str) -> ReleaseRecord:
        self._require_writable()
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            prior = connection.execute(
                "SELECT operation, release_name FROM operations WHERE request_id = ?",
                (request_id,),
            ).fetchone()
            if prior:
                if prior["operation"] != "activate" or prior["release_name"] != release_name:
                    raise ReleaseStoreError("request ID was already used for another operation")
                connection.commit()
                return self.get(release_name)
            release = connection.execute(
                "SELECT status FROM releases WHERE name = ?", (release_name,)
            ).fetchone()
            if release is None:
                raise ReleaseStoreError(f"unknown release: {release_name}")
            if release["status"] != "staged":
                raise ReleaseStoreError(f"release is not staged: {release_name}")
            connection.execute(
                """
                INSERT INTO settings(key, value) VALUES ('active_release', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                (release_name,),
            )
            response = json.dumps({"release": release_name, "status": "active"})
            connection.execute(
                """
                INSERT INTO operations(
                    request_id, operation, release_name, response_json, created_at
                )
                VALUES (?, 'activate', ?, ?, ?)
                """,
                (request_id, release_name, response, _now()),
            )
            connection.commit()
        return self.get(release_name)

    def active_release(self) -> ReleaseRecord | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT value FROM settings WHERE key = 'active_release'"
            ).fetchone()
        return self.get(str(row["value"])) if row else None

    def get(self, release_name: str) -> ReleaseRecord:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT r.*,
                    CASE WHEN s.value = r.name THEN 1 ELSE 0 END AS active
                FROM releases r
                LEFT JOIN settings s ON s.key = 'active_release'
                WHERE r.name = ?
                """,
                (release_name,),
            ).fetchone()
            if row is None:
                raise ReleaseStoreError(f"unknown release: {release_name}")
            snapshots = {
                str(item["volume_name"]): str(item["snapshot"])
                for item in connection.execute(
                    """
                    SELECT volume_name, snapshot FROM release_volumes
                    WHERE release_name = ? ORDER BY volume_name
                    """,
                    (release_name,),
                )
            }
        return ReleaseRecord(
            name=str(row["name"]),
            status=str(row["status"]),
            request_id=str(row["request_id"]),
            created_at=str(row["created_at"]),
            completed_at=str(row["completed_at"]) if row["completed_at"] else None,
            snapshots=snapshots,
            active=bool(row["active"]),
        )

    def list(self) -> list[ReleaseRecord]:
        with self._connect() as connection:
            names = [
                str(row["name"])
                for row in connection.execute(
                    "SELECT name FROM releases ORDER BY created_at, name"
                )
            ]
        return [self.get(name) for name in names]

    def audit(
        self,
        *,
        request_id: str,
        action: str,
        result: str,
        release_name: str | None = None,
        source_ip: str | None = None,
        details: str = "",
    ) -> None:
        self._require_writable()
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO audit_events(
                    created_at, request_id, action, release_name, result, source_ip, details
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (_now(), request_id, action, release_name, result, source_ip, details[:500]),
            )
            connection.commit()

    def _connect(self) -> sqlite3.Connection:
        try:
            if self.read_only:
                connection = sqlite3.connect(
                    f"file:{self.path}?mode=ro", uri=True, timeout=5
                )
            else:
                connection = sqlite3.connect(self.path, timeout=5)
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA busy_timeout=5000")
            return connection
        except sqlite3.Error as exc:
            raise ReleaseStoreError(f"cannot open release database: {self.path}") from exc

    @staticmethod
    def _check_schema(connection: sqlite3.Connection) -> None:
        try:
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            if version != DATABASE_SCHEMA_VERSION:
                raise ReleaseStoreError(
                    f"unsupported release database schema {version}; "
                    f"expected {DATABASE_SCHEMA_VERSION}"
                )
            connection.execute("SELECT 1 FROM releases LIMIT 1").fetchone()
        except sqlite3.Error as exc:
            raise ReleaseStoreError("release database is corrupt or incomplete") from exc

    def _require_writable(self) -> None:
        if self.read_only:
            raise ReleaseStoreError("release database is read-only")


def _now() -> str:
    return datetime.now(UTC).isoformat()
