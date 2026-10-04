from __future__ import annotations

import sqlite3
from datetime import date, datetime, timezone
from pathlib import Path

from noted.models import PaceProfile, Transaction


MIGRATIONS = Path(__file__).with_name("migrations")


class Database:
    def __init__(self, path: Path):
        self.path = path

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        return connection

    def bootstrap(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA synchronous = NORMAL")
            connection.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)")
            applied = {row[0] for row in connection.execute("SELECT version FROM schema_migrations")}
            for migration in sorted(MIGRATIONS.glob("*.sql")):
                if migration.stem in applied:
                    continue
                connection.executescript(migration.read_text(encoding="utf-8"))
                connection.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
                    (migration.stem, datetime.now(timezone.utc).isoformat()),
                )

    def recent_transactions(self, limit: int = 50) -> list[Transaction]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM transactions WHERE deleted_at IS NULL ORDER BY occurred_at DESC, created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [Transaction.model_validate(dict(row)) for row in rows]

    def search_transactions(
        self,
        *,
        limit: int = 50,
        start_date: date | None = None,
        end_date: date | None = None,
        query: str | None = None,
    ) -> list[Transaction]:
        clauses = ["deleted_at IS NULL"]
        parameters: list[object] = []
        if start_date is not None:
            clauses.append("local_date >= ?")
            parameters.append(start_date.isoformat())
        if end_date is not None:
            clauses.append("local_date <= ?")
            parameters.append(end_date.isoformat())
        if query is not None and query.strip():
            escaped = query.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            pattern = f"%{escaped}%"
            clauses.append(
                "(merchant LIKE ? ESCAPE '\\' COLLATE NOCASE "
                "OR description LIKE ? ESCAPE '\\' COLLATE NOCASE "
                "OR category LIKE ? ESCAPE '\\' COLLATE NOCASE)"
            )
            parameters.extend((pattern, pattern, pattern))
        parameters.append(limit)
        with self.connect() as connection:
            rows = connection.execute(
                f"SELECT * FROM transactions WHERE {' AND '.join(clauses)} "
                "ORDER BY occurred_at DESC, created_at DESC LIMIT ?",
                parameters,
            ).fetchall()
        return [Transaction.model_validate(dict(row)) for row in rows]

    def transaction(self, transaction_id: str, *, include_deleted: bool = False) -> Transaction | None:
        predicate = "id = ?" if include_deleted else "id = ? AND deleted_at IS NULL"
        with self.connect() as connection:
            row = connection.execute(f"SELECT * FROM transactions WHERE {predicate}", (transaction_id,)).fetchone()
        return Transaction.model_validate(dict(row)) if row else None

    def action_row(self, action_id: str):
        with self.connect() as connection:
            return connection.execute("SELECT * FROM action_log WHERE id = ?", (action_id,)).fetchone()

    def session(self, session_id: str):
        with self.connect() as connection:
            return connection.execute("SELECT * FROM conversation_sessions WHERE id = ?", (session_id,)).fetchone()

    def action_context(self, action_id: str):
        with self.connect() as connection:
            return connection.execute(
                """SELECT a.*, t.session_id, t.user_text
                   FROM action_log a LEFT JOIN turns t ON t.id = a.turn_id WHERE a.id = ?""",
                (action_id,),
            ).fetchone()

    def merchant_rows(self) -> list[sqlite3.Row]:
        with self.connect() as connection:
            return connection.execute(
                """SELECT m.*, m.id AS merchant_id, a.alias_key, a.id AS alias_id, a.source
                   FROM merchants m JOIN merchant_aliases a ON a.merchant_id = m.id"""
            ).fetchall()

    def merchant_alias(self, alias_key: str) -> sqlite3.Row | None:
        with self.connect() as connection:
            return connection.execute(
                """SELECT m.*, m.id AS merchant_id, a.alias_key, a.id AS alias_id, a.source
                   FROM merchant_aliases a JOIN merchants m ON m.id = a.merchant_id
                   WHERE a.alias_key = ? AND a.source IN ('user', 'seed')""",
                (alias_key,),
            ).fetchone()

    def context_rules(self, merchant_id: str) -> list[sqlite3.Row]:
        with self.connect() as connection:
            return connection.execute(
                """SELECT * FROM merchant_context_rules
                   WHERE merchant_id = ? ORDER BY priority DESC, keyword""",
                (merchant_id,),
            ).fetchall()

    def pace_profile(self) -> PaceProfile | None:
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM pace_profile WHERE id = 1").fetchone()
        if row is None:
            return None
        values = dict(row)
        values.pop("id")
        return PaceProfile.model_validate(values)

    def transactions_between(self, start_date: str, end_date: str) -> list[Transaction]:
        with self.connect() as connection:
            rows = connection.execute(
                """SELECT * FROM transactions
                   WHERE deleted_at IS NULL AND local_date >= ? AND local_date <= ?
                   ORDER BY local_date, occurred_at, created_at""",
                (start_date, end_date),
            ).fetchall()
        return [Transaction.model_validate(dict(row)) for row in rows]
