from __future__ import annotations

import argparse
import os
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from noted.db import MIGRATIONS


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATABASE = ROOT / "data" / "noted.db"
DEFAULT_BACKUP_DIR = Path.home() / ".local" / "share" / "pace" / "backups"
REQUIRED_TABLES = {
    "schema_migrations", "transactions", "action_log", "request_idempotency", "pace_profile",
}
DEFAULT_RETENTION = 30


class BackupError(RuntimeError):
    pass


def database_path() -> Path:
    return Path(os.environ.get("NOTED_DB_PATH", DEFAULT_DATABASE)).expanduser().resolve()


def backup_directory() -> Path:
    return Path(os.environ.get("NOTED_BACKUP_DIR", DEFAULT_BACKUP_DIR)).expanduser().resolve()


def validate_database(path: Path, *, require_current: bool = True) -> None:
    if not path.is_file():
        raise BackupError(f"database does not exist: {path}")
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            result = connection.execute("PRAGMA quick_check").fetchone()
            if result is None or result[0] != "ok":
                raise BackupError(f"SQLite integrity check failed: {result[0] if result else 'no result'}")
            tables = {row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            )}
            missing = REQUIRED_TABLES - tables
            if missing:
                raise BackupError(f"not a Pace database; missing tables: {', '.join(sorted(missing))}")
            if require_current:
                applied = {row[0] for row in connection.execute("SELECT version FROM schema_migrations")}
                expected = {migration.stem for migration in MIGRATIONS.glob("*.sql")}
                missing_migrations = expected - applied
                if missing_migrations:
                    raise BackupError(
                        f"database is missing migrations: {', '.join(sorted(missing_migrations))}"
                    )
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise BackupError(f"invalid or unreadable SQLite database: {path}: {exc}") from exc


def _online_copy(source: Path, destination: Path) -> None:
    source_connection = sqlite3.connect(source, timeout=5)
    destination_connection = sqlite3.connect(destination)
    try:
        source_connection.execute("PRAGMA busy_timeout = 5000")
        source_connection.backup(destination_connection)
    except sqlite3.Error as exc:
        raise BackupError(f"SQLite online backup failed: {exc}") from exc
    finally:
        destination_connection.close()
        source_connection.close()


def _timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def create_backup(source: Path, destination_dir: Path, *, retention: int = DEFAULT_RETENTION,
                  prefix: str = "pace") -> Path:
    source = source.resolve()
    destination_dir = destination_dir.resolve()
    validate_database(source)
    destination_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(destination_dir, 0o700)
    destination = destination_dir / f"{prefix}-{_timestamp()}.sqlite3"
    if destination.exists():
        raise BackupError(f"refusing to overwrite existing backup: {destination}")
    try:
        _online_copy(source, destination)
        os.chmod(destination, 0o600)
        validate_database(destination)
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    if retention > 0:
        snapshots = sorted(destination_dir.glob(f"{prefix}-*.sqlite3"), reverse=True)
        for expired in snapshots[retention:]:
            expired.unlink()
    return destination


def restore_backup(backup: Path, live: Path, safety_dir: Path) -> tuple[Path, Path]:
    backup = backup.expanduser().resolve()
    live = live.expanduser().resolve()
    safety_dir = safety_dir.expanduser().resolve()
    validate_database(backup)
    if not live.is_file():
        raise BackupError(f"live database does not exist; refusing unguarded restore: {live}")
    validate_database(live)

    safety = create_backup(live, safety_dir, retention=0, prefix="pre-restore")
    live.parent.mkdir(parents=True, exist_ok=True)
    temporary_fd, temporary_name = tempfile.mkstemp(prefix=f".{live.name}.restore-", dir=live.parent)
    os.close(temporary_fd)
    temporary = Path(temporary_name)
    try:
        temporary.unlink()
        _online_copy(backup, temporary)
        validate_database(temporary)
        os.chmod(temporary, 0o600)

        lock = sqlite3.connect(live, timeout=1, isolation_level=None)
        try:
            lock.execute("PRAGMA busy_timeout = 1000")
            lock.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            lock.execute("BEGIN EXCLUSIVE")
            lock.execute("COMMIT")
        except sqlite3.Error as exc:
            try:
                lock.execute("ROLLBACK")
            except sqlite3.Error:
                pass
            raise BackupError(
                "could not acquire a safe restore lock; stop Pace and retry: " + str(exc)
            ) from exc
        finally:
            lock.close()
        for suffix in ("-wal", "-shm"):
            Path(f"{live}{suffix}").unlink(missing_ok=True)
        os.replace(temporary, live)
        directory_fd = os.open(live.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        validate_database(live)
        return live, safety
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Create or restore a private Pace SQLite backup")
    subparsers = parser.add_subparsers(dest="command", required=True)
    backup_parser = subparsers.add_parser("backup", help="create an online SQLite snapshot")
    backup_parser.add_argument("--retention", type=int, default=DEFAULT_RETENTION)
    restore_parser = subparsers.add_parser("restore", help="safely restore a Pace snapshot")
    restore_parser.add_argument("backup", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "backup":
            output = create_backup(database_path(), backup_directory(), retention=args.retention)
            print(f"Backup created: {output}")
        else:
            restored, safety = restore_backup(args.backup, database_path(), backup_directory())
            print(f"Restore complete: {restored}")
            print(f"Pre-restore safety backup: {safety}")
    except BackupError as exc:
        parser.exit(1, f"error: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
