from __future__ import annotations

import json
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from noted.actions import ExecutedAction
from noted.db import Database
from noted.merchants import learn_merchant_correction, merchant_key, revert_merchant_learning
from noted.models import PaceProfile, PaceProfileInput, Transaction, TransactionCreate


class ActionNotFoundError(LookupError):
    pass


class TransactionNotFoundError(LookupError):
    pass


class DeletedTransactionError(ValueError):
    pass


class RequestIdConflictError(ValueError):
    pass


class UndoConflictError(ValueError):
    """A later action changed what this action wrote; undoing it would overwrite that work."""


class UndoNotSupportedError(ValueError):
    pass


# Bookkeeping columns an undo neither compares nor restores.
_UNDO_IGNORED = {"id", "created_at", "updated_at"}


@dataclass(frozen=True)
class IdempotentExecution:
    executed: ExecutedAction
    turn_id: str | None
    session_id: str | None
    transcript: str | None
    reply: str
    path: str
    duplicate: bool


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _snapshot(row: sqlite3.Row | None) -> dict[str, Any] | None:
    return dict(row) if row else None


def _json(value: dict[str, Any] | None) -> str | None:
    return json.dumps(value, sort_keys=True, separators=(",", ":")) if value is not None else None


class ActionExecutor:
    def __init__(self, database: Database):
        self.database = database

    def _log(self, connection, *, kind: str, target_id: str, before, after,
             turn_id=None, proposed_action_id=None, metadata=None, undo_of=None,
             target_table: str = "transactions") -> str:
        action_id = str(uuid.uuid4())
        connection.execute(
            """INSERT INTO action_log (
                id, turn_id, proposed_action_id, kind, target_table, target_id,
                before_json, after_json, metadata_json, executed_at, undo_of
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (action_id, turn_id, proposed_action_id, kind, target_table, target_id, _json(before),
             _json(after), _json(metadata), _now(), undo_of),
        )
        return action_id

    def record_turn(self, *, session_id: str, captured_at: datetime, timezone_name: str,
                    transcript: str, proposal, llm_model: str | None = None,
                    llm_ms: int | None = None, prompt_version: str | None = None,
                    llm_raw_output: str | None = None, llm_invoked: bool = False,
                    action_status: str = "resolved", validation_error: str | None = None) -> tuple[str, list[str]]:
        now = _now()
        turn_id = str(uuid.uuid4())
        utterance_id = str(uuid.uuid4())
        with self.database.connect() as connection:
            connection.execute(
                """INSERT INTO conversation_sessions(id, started_at, last_turn_at, timezone)
                   VALUES (?, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET last_turn_at=excluded.last_turn_at, timezone=excluded.timezone""",
                (session_id, now, now, timezone_name),
            )
            connection.execute(
                """INSERT INTO utterances (
                    id, session_id, captured_at, timezone, transcript, llm_model, llm_ms,
                    prompt_version, llm_raw_output, llm_invoked, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (utterance_id, session_id, captured_at.isoformat(), timezone_name, transcript,
                 llm_model, llm_ms, prompt_version, llm_raw_output, int(llm_invoked), now),
            )
            connection.execute(
                "INSERT INTO turns(id, session_id, utterance_id, turn_kind, user_text, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (turn_id, session_id, utterance_id, proposal.turn_kind, transcript, now),
            )
            action_ids = []
            for ordinal, action in enumerate(proposal.actions, start=1):
                action_id = str(uuid.uuid4())
                action_ids.append(action_id)
                connection.execute(
                    """INSERT INTO proposed_actions (
                        id, turn_id, ordinal, intent, raw_json, status, validation_error, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (action_id, turn_id, ordinal, action.intent, action.model_dump_json(),
                     action_status, validation_error, now),
                )
        return turn_id, action_ids

    def record_shadow_proposal(self, turn_id: str, outcome) -> None:
        now = _now()
        with self.database.connect() as connection:
            ordinal = connection.execute(
                "SELECT COALESCE(MAX(ordinal), 0) FROM proposed_actions WHERE turn_id = ?", (turn_id,),
            ).fetchone()[0]
            if outcome.proposal:
                for action in outcome.proposal.actions:
                    ordinal += 1
                    connection.execute(
                        """INSERT INTO proposed_actions (
                            id, turn_id, ordinal, intent, raw_json, status, validation_error, created_at
                        ) VALUES (?, ?, ?, ?, ?, 'rejected', NULL, ?)""",
                        (str(uuid.uuid4()), turn_id, ordinal, action.intent, action.model_dump_json(), now),
                    )
            else:
                connection.execute(
                    """INSERT INTO proposed_actions (
                        id, turn_id, ordinal, intent, raw_json, status, validation_error, created_at
                    ) VALUES (?, ?, ?, 'unsupported', ?, 'rejected', ?, ?)""",
                    (str(uuid.uuid4()), turn_id, ordinal + 1, outcome.raw_json or "", outcome.error, now),
                )

    def set_turn_reply(self, turn_id: str, reply: str) -> None:
        with self.database.connect() as connection:
            connection.execute("UPDATE turns SET reply_text = ? WHERE id = ?", (reply, turn_id))

    @staticmethod
    def _transaction(connection, transaction_id: str) -> sqlite3.Row | None:
        return connection.execute("SELECT * FROM transactions WHERE id = ?", (transaction_id,)).fetchone()

    @staticmethod
    def _executed(action_id: str, kind: str, row: sqlite3.Row, *, undone: bool = False) -> ExecutedAction:
        return ExecutedAction(
            action_id=action_id, kind=kind,
            transaction=Transaction.model_validate(dict(row)), undo_token=action_id, undone=undone,
        )

    def _idempotent_execution(self, connection, request_id: str, fingerprint: str) -> IdempotentExecution | None:
        row = connection.execute(
            """SELECT i.request_fingerprint, i.turn_id, i.capture_path,
                      a.id AS action_id, a.kind, a.target_id,
                      t.session_id, t.user_text, t.reply_text
               FROM request_idempotency i
               JOIN action_log a ON a.id = i.action_log_id
               LEFT JOIN turns t ON t.id = i.turn_id
               WHERE i.request_id = ?""",
            (request_id,),
        ).fetchone()
        if row is None:
            return None
        if row["request_fingerprint"] != fingerprint:
            raise RequestIdConflictError("request ID was already committed with a different payload")
        transaction = self._transaction(connection, row["target_id"])
        if transaction is None:
            raise RuntimeError("idempotency record references a missing transaction")
        return IdempotentExecution(
            executed=self._executed(row["action_id"], row["kind"], transaction),
            turn_id=row["turn_id"], session_id=row["session_id"], transcript=row["user_text"],
            reply=row["reply_text"] or "", path=row["capture_path"], duplicate=True,
        )

    def replay(self, request_id: str, fingerprint: str) -> IdempotentExecution | None:
        with self.database.connect() as connection:
            return self._idempotent_execution(connection, request_id, fingerprint)

    def create_transaction(self, draft: TransactionCreate, *, turn_id=None, proposed_action_id=None,
                           merchant_alias_id: int | None = None, request_id: str | None = None,
                           request_fingerprint: str | None = None, capture_path: str | None = None,
                           reply: str | None = None) -> IdempotentExecution | ExecutedAction:
        transaction_id = str(uuid.uuid4())
        created_at = _now()
        values = draft.model_dump(mode="json")
        with self.database.connect() as connection:
            if request_id is not None:
                if not request_fingerprint or not capture_path:
                    raise ValueError("idempotent create requires fingerprint and path")
                if capture_path != "manual" and (not turn_id or reply is None):
                    raise ValueError("conversational idempotent create requires turn and reply")
                connection.execute("BEGIN IMMEDIATE")
                replay = self._idempotent_execution(connection, request_id, request_fingerprint)
                if replay is not None:
                    return replay
            connection.execute(
                """INSERT INTO transactions (
                    id, type, amount_minor, currency, merchant_id, merchant, description,
                    category, subcategory, occurred_at, local_date, raw_transcript, created_at,
                    updated_at, deleted_at, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 'confirmed')""",
                (transaction_id, values["type"], values["amount_minor"], values["currency"],
                 values["merchant_id"], values["merchant"], values["description"],
                 values["category"], values["subcategory"], values["occurred_at"],
                 values["local_date"], values["raw_transcript"], created_at),
            )
            if values["merchant_id"]:
                connection.execute(
                    "UPDATE merchants SET hit_count = hit_count + 1, last_seen_at = ? WHERE id = ?",
                    (created_at, values["merchant_id"]),
                )
            if merchant_alias_id is not None:
                connection.execute(
                    "UPDATE merchant_aliases SET hit_count = hit_count + 1 WHERE id = ?",
                    (merchant_alias_id,),
                )
            row = self._transaction(connection, transaction_id)
            action_id = self._log(connection, kind="create_transaction", target_id=transaction_id,
                                  before=None, after=_snapshot(row), turn_id=turn_id,
                                  proposed_action_id=proposed_action_id)
            if proposed_action_id:
                connection.execute("UPDATE proposed_actions SET status = 'executed' WHERE id = ?", (proposed_action_id,))
            if request_id is not None:
                if turn_id is not None:
                    connection.execute("UPDATE turns SET reply_text = ? WHERE id = ?", (reply, turn_id))
                connection.execute(
                    """INSERT INTO request_idempotency (
                           request_id, request_fingerprint, action_log_id, turn_id, capture_path, committed_at
                       ) VALUES (?, ?, ?, ?, ?, ?)""",
                    (request_id, request_fingerprint, action_id, turn_id, capture_path, created_at),
                )
        executed = self._executed(action_id, "create_transaction", row)
        if request_id is None:
            return executed
        return IdempotentExecution(
            executed=executed, turn_id=turn_id, session_id="", transcript=draft.raw_transcript,
            reply=reply or "", path=capture_path, duplicate=False,
        )

    def set_pace_profile(self, profile: PaceProfileInput) -> PaceProfile:
        now = _now()
        values = profile.model_dump(mode="json")
        with self.database.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            before_row = connection.execute("SELECT * FROM pace_profile WHERE id = 1").fetchone()
            created_at = before_row["created_at"] if before_row else now
            connection.execute(
                """INSERT INTO pace_profile (
                       id, income_amount_minor, income_frequency, next_income_date,
                       fixed_commitments_minor, savings_target_minor, savings_mode,
                       savings_percentage_basis_points, currency,
                       created_at, updated_at
                   ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, 'MYR', ?, ?)
                   ON CONFLICT(id) DO UPDATE SET
                       income_amount_minor=excluded.income_amount_minor,
                       income_frequency=excluded.income_frequency,
                       next_income_date=excluded.next_income_date,
                       fixed_commitments_minor=excluded.fixed_commitments_minor,
                       savings_target_minor=excluded.savings_target_minor,
                       savings_mode=excluded.savings_mode,
                       savings_percentage_basis_points=excluded.savings_percentage_basis_points,
                       updated_at=excluded.updated_at""",
                (values["income_amount_minor"], values["income_frequency"],
                 values["next_income_date"], values["fixed_commitments_minor"],
                 values["savings_target_minor"], values["savings_mode"],
                 values["savings_percentage_basis_points"], created_at, now),
            )
            after_row = connection.execute("SELECT * FROM pace_profile WHERE id = 1").fetchone()
            self._log(
                connection, kind="set_pace_profile", target_table="pace_profile",
                target_id="1", before=_snapshot(before_row), after=_snapshot(after_row),
            )
        result = dict(after_row)
        result.pop("id")
        return PaceProfile.model_validate(result)

    def update_transaction(self, transaction_id: str, changes: dict, *, turn_id=None,
                           proposed_action_id=None, explicit_user_edit: bool = False) -> ExecutedAction:
        allowed = {"type", "amount_minor", "merchant_id", "merchant", "description", "category",
                   "subcategory", "occurred_at", "local_date", "raw_transcript", "status"}
        unknown = set(changes) - allowed
        if unknown or not changes:
            raise ValueError(f"invalid transaction changes: {sorted(unknown)}")
        values = {key: value.isoformat() if isinstance(value, datetime) else value for key, value in changes.items()}
        learning: dict = {}
        with self.database.connect() as connection:
            before_row = self._transaction(connection, transaction_id)
            if before_row is None:
                raise TransactionNotFoundError(transaction_id)
            if before_row["deleted_at"] is not None:
                raise DeletedTransactionError("cannot update a deleted transaction")
            candidate = dict(before_row)
            candidate.update(values)
            Transaction.model_validate(candidate)
            if explicit_user_edit:
                old_name = before_row["merchant"]
                new_name = candidate["merchant"]
                if "merchant" in values and not merchant_key(new_name or ""):
                    values["merchant_id"] = None
                merchant_changed = (
                    "merchant" in values and bool(merchant_key(old_name or ""))
                    and bool(merchant_key(new_name or ""))
                    and merchant_key(old_name) != merchant_key(new_name)
                )
                category_changed = (
                    "category" in values and candidate["category"] != before_row["category"]
                    and candidate["type"] == before_row["type"]
                    and bool(candidate["category"])
                )
                if (merchant_changed or category_changed) and merchant_key(new_name or ""):
                    source_name = old_name
                    if merchant_changed:
                        original = connection.execute(
                            """SELECT p.raw_json FROM action_log a
                               JOIN proposed_actions p ON p.id = a.proposed_action_id
                               WHERE a.target_id = ? AND a.kind = 'create_transaction'
                               ORDER BY a.executed_at LIMIT 1""",
                            (transaction_id,),
                        ).fetchone()
                        if original:
                            source_name = json.loads(original["raw_json"]).get("merchant_expr") or old_name
                    merchant_id = learn_merchant_correction(
                        connection, source_name=source_name, corrected_name=new_name,
                        category=candidate["category"], learn_alias=merchant_changed,
                        learn_category=category_changed, record=learning,
                    )
                    values["merchant_id"] = merchant_id
            assignments = ", ".join(f"{key} = ?" for key in values)
            connection.execute(
                f"UPDATE transactions SET {assignments}, updated_at = ? WHERE id = ?",
                (*values.values(), _now(), transaction_id),
            )
            after_row = self._transaction(connection, transaction_id)
            action_id = self._log(connection, kind="update_transaction", target_id=transaction_id,
                                  before=_snapshot(before_row), after=_snapshot(after_row), turn_id=turn_id,
                                  proposed_action_id=proposed_action_id,
                                  metadata={"learning": learning} if learning else None)
            if proposed_action_id:
                connection.execute("UPDATE proposed_actions SET status = 'executed' WHERE id = ?", (proposed_action_id,))
        return self._executed(action_id, "update_transaction", after_row)

    def soft_delete_transaction(self, transaction_id: str, *, reason=None, turn_id=None,
                                proposed_action_id=None) -> ExecutedAction:
        with self.database.connect() as connection:
            before_row = self._transaction(connection, transaction_id)
            if before_row is None:
                raise TransactionNotFoundError(transaction_id)
            if before_row["deleted_at"] is None:
                now = _now()
                connection.execute("UPDATE transactions SET deleted_at = ?, updated_at = ? WHERE id = ?", (now, now, transaction_id))
            after_row = self._transaction(connection, transaction_id)
            action_id = self._log(connection, kind="delete_transaction", target_id=transaction_id,
                                  before=_snapshot(before_row), after=_snapshot(after_row), turn_id=turn_id,
                                  proposed_action_id=proposed_action_id,
                                  metadata={"reason": reason} if reason else None)
            if proposed_action_id:
                connection.execute("UPDATE proposed_actions SET status = 'executed' WHERE id = ?", (proposed_action_id,))
        return self._executed(action_id, "delete_transaction", after_row)

    @staticmethod
    def _later_learning(connection, action) -> list[dict]:
        """Learning records of still-active corrections executed after ``action``."""
        rows = connection.execute(
            """SELECT metadata_json FROM action_log
               WHERE kind = 'update_transaction' AND undone_at IS NULL AND metadata_json IS NOT NULL
                 AND rowid > (SELECT rowid FROM action_log WHERE id = ?)""",
            (action["id"],),
        ).fetchall()
        return [json.loads(row["metadata_json"]).get("learning") or {} for row in rows]

    def undo(self, action_log_id: str) -> ExecutedAction:
        with self.database.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            action = connection.execute("SELECT * FROM action_log WHERE id = ?", (action_log_id,)).fetchone()
            if action is None:
                raise ActionNotFoundError(action_log_id)
            if action["target_table"] != "transactions" or action["kind"] == "undo":
                raise UndoNotSupportedError(f"{action['kind']} cannot be undone")
            if action["undone_at"] is not None:
                undo = connection.execute("SELECT * FROM action_log WHERE undo_of = ? ORDER BY executed_at LIMIT 1", (action_log_id,)).fetchone()
                row = self._transaction(connection, action["target_id"])
                return self._executed(undo["id"] if undo else action_log_id, "undo", row, undone=True)
            before = json.loads(action["before_json"]) if action["before_json"] else None
            after = json.loads(action["after_json"])
            current = self._transaction(connection, action["target_id"])
            current_snapshot = _snapshot(current)
            now = _now()
            # Revert only what this action wrote, and only while it is still there.
            if before is None:
                written = {key for key in after if key not in _UNDO_IGNORED}
                restore = {"deleted_at": now}
            else:
                written = {key for key in after if key not in _UNDO_IGNORED and after[key] != before.get(key)}
                restore = {key: before[key] for key in written}
            # Matching current values are insufficient: a later edit may have
            # changed a field and then put the same value back. Its active
            # audit record still owns that field.
            later_actions = connection.execute(
                """SELECT before_json, after_json FROM action_log
                   WHERE target_table = 'transactions' AND target_id = ?
                     AND rowid > (SELECT rowid FROM action_log WHERE id = ?)
                     AND undone_at IS NULL AND kind != 'undo'""",
                (action["target_id"], action_log_id),
            ).fetchall()
            for later in later_actions:
                later_before = json.loads(later["before_json"]) if later["before_json"] else None
                later_after = json.loads(later["after_json"])
                later_written = {
                    key for key in later_after if key not in _UNDO_IGNORED
                    and (later_before is None or later_after[key] != later_before.get(key))
                }
                if written & later_written:
                    raise UndoConflictError("a later change replaced what this action wrote; undo that change first")
            if any(current_snapshot.get(key) != after[key] for key in written):
                raise UndoConflictError("a later change replaced what this action wrote; undo that change first")
            if restore:
                assignments = ", ".join(f"{key} = ?" for key in restore)
                connection.execute(
                    f"UPDATE transactions SET {assignments}, updated_at = ? WHERE id = ?",
                    (*restore.values(), now, action["target_id"]),
                )
            metadata = json.loads(action["metadata_json"]) if action["metadata_json"] else {}
            learning = metadata.get("learning")
            if learning:
                later = self._later_learning(connection, action)
                revert_merchant_learning(
                    connection, learning,
                    reinforced_aliases={
                        alias["alias_key"] for record in later
                        if record.get("merchant_id") == learning["merchant_id"]
                        for alias in record.get("aliases", [])
                    },
                    merchant_reinforced=any(
                        record.get("merchant_id") == learning["merchant_id"] for record in later
                    ),
                )
            restored = self._transaction(connection, action["target_id"])
            undo_id = self._log(connection, kind="undo", target_id=action["target_id"],
                                before=current_snapshot, after=_snapshot(restored), undo_of=action_log_id)
            connection.execute("UPDATE action_log SET undone_at = ? WHERE id = ?", (now, action_log_id))
        return self._executed(undo_id, "undo", restored, undone=True)
