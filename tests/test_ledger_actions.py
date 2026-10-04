from __future__ import annotations

import json
import io
import re
import wave
from datetime import datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.actions import TurnProposal
from noted.api import create_app
from noted.dates import resolve_date_expr, resolve_period_expr
from noted.db import Database
from noted.execute import ActionExecutor, DeletedTransactionError
from noted.models import TransactionCreate
from tests.support_capture import fixture_understanding


CAPTURED = datetime.fromisoformat("2026-09-15T00:05:00+08:00")


class FakeASR:
    model_id = "fake"

    def load(self): pass
    def transcribe(self, _wav_bytes): return ""
    def close(self): pass


def wav_bytes() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\0\0" * 4_800)
    return output.getvalue()


@pytest.fixture
def database(tmp_path: Path) -> Database:
    db = Database(tmp_path / "noted.db")
    db.bootstrap()
    return db


def draft(amount: int = 2000) -> TransactionCreate:
    return TransactionCreate(
        type="expense", amount_minor=amount, merchant_id="merchant-mcdonalds",
        merchant="McDonald's", description=None, category="Food & Drink",
        subcategory=None, occurred_at=CAPTURED, local_date="2026-09-15",
        raw_transcript="Spent twenty ringgit at McDonald's",
    )


def test_action_schema_is_generatable():
    schema = TurnProposal.model_json_schema()
    assert schema["properties"]["actions"]
    assert "CreateTransactionAction" in schema["$defs"]
    assert "UnsupportedAction" in schema["$defs"]


def test_create_update_undo_delete_undo_round_trip(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(draft())
    updated = executor.update_transaction(created.transaction.id, {"amount_minor": 3500})
    assert updated.transaction.amount_minor == 3500

    update_log = database.action_row(updated.action_id)
    assert json.loads(update_log["before_json"])["amount_minor"] == 2000
    assert json.loads(update_log["after_json"])["amount_minor"] == 3500
    restored_update = executor.undo(updated.action_id)
    assert restored_update.transaction.amount_minor == 2000
    assert database.action_row(restored_update.action_id)["undo_of"] == updated.action_id

    deleted = executor.soft_delete_transaction(created.transaction.id, reason="mistake")
    assert deleted.transaction.deleted_at is not None
    assert database.recent_transactions() == []
    delete_log = database.action_row(deleted.action_id)
    assert json.loads(delete_log["before_json"])["deleted_at"] is None
    assert json.loads(delete_log["after_json"])["deleted_at"] is not None

    restored_delete = executor.undo(deleted.action_id)
    assert restored_delete.transaction.deleted_at is None
    assert database.recent_transactions()[0].id == created.transaction.id


def test_undo_is_idempotent_and_cross_session(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(draft())
    updated = executor.update_transaction(created.transaction.id, {"category": "Other"})
    first = executor.undo(updated.action_id)
    second = executor.undo(updated.action_id)
    assert second.action_id == first.action_id
    assert second.transaction.category == "Food & Drink"
    with database.connect() as connection:
        assert connection.execute("SELECT COUNT(*) FROM action_log WHERE undo_of = ?", (updated.action_id,)).fetchone()[0] == 1


def test_deleted_transaction_cannot_be_updated(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(draft())
    executor.soft_delete_transaction(created.transaction.id)
    with pytest.raises(DeletedTransactionError):
        executor.update_transaction(created.transaction.id, {"amount_minor": 1})


def test_mutation_rolls_back_when_audit_log_cannot_be_written(database: Database):
    executor = ActionExecutor(database)
    with pytest.raises(Exception):
        executor.create_transaction(draft(), proposed_action_id="missing-proposal")
    assert database.recent_transactions() == []


def test_conversation_create_and_api_mutations_have_audit_rows(tmp_path: Path):
    db_path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=db_path)
    headers = {
        "X-Session-Id": "sess-test-1", "X-Captured-At": "2026-09-15T14:30:00+08:00",
        "X-Timezone": "Asia/Kuala_Lumpur",
    }
    with TestClient(app) as client:
        response = client.post("/api/conversation/text", json={"text": "Spent twenty ringgit at McDonald's"}, headers=headers)
        assert response.status_code == 200
        result = response.json()
        assert result["executed"][0]["kind"] == "create_transaction"
        assert result["executed"][0]["undo_token"]
        transaction_id = result["executed"][0]["transaction"]["id"]

        assert client.patch(f"/api/transactions/{transaction_id}", json={"amount_minor": 3500}).json()["amount_minor"] == 3500
        assert client.delete(f"/api/transactions/{transaction_id}").status_code == 204
        assert client.get("/api/transactions").json() == []

        database = Database(db_path)
        with database.connect() as connection:
            delete_action = connection.execute(
                "SELECT id FROM action_log WHERE target_id = ? AND kind = 'delete_transaction' ORDER BY executed_at DESC LIMIT 1",
                (transaction_id,),
            ).fetchone()[0]
            assert connection.execute("SELECT COUNT(*) FROM action_log WHERE target_id = ?", (transaction_id,)).fetchone()[0] == 3

        undo = client.post(f"/api/actions/{delete_action}/undo")
        assert undo.status_code == 200
        assert client.get("/api/transactions").json()[0]["id"] == transaction_id
        assert client.post(f"/api/actions/{delete_action}/undo").status_code == 200
        assert client.post("/api/actions/missing/undo").status_code == 404
        session = client.get("/api/conversation/session", headers={"X-Session-Id": "sess-test-1"}).json()
        assert session["session"]["id"] == "sess-test-1"
        assert session["pending"] is None


def test_legacy_voice_and_history_response_shapes_do_not_expose_gate_a_columns(tmp_path: Path):
    class VoiceASR(FakeASR):
        def transcribe(self, _wav_bytes): return "Spent twenty ringgit at McDonald's"

    app = create_app(asr_service=VoiceASR(), understanding_service=fixture_understanding(), database_path=tmp_path / "noted.db")
    with TestClient(app) as client:
        response = client.post("/api/transactions/voice", content=wav_bytes(), headers={"Content-Type": "audio/wav"})
        assert response.status_code == 200
        assert {"updated_at", "deleted_at", "status"}.isdisjoint(response.json())
        assert {"updated_at", "deleted_at", "status"}.isdisjoint(client.get("/api/transactions").json()[0])


@pytest.mark.parametrize(
    ("captured", "expr", "expected"),
    [
        ("2026-09-15T00:05:00+08:00", "yesterday", "2026-09-14"),
        ("2026-09-15T12:00:00+08:00", "last Monday", "2026-09-14"),
    ],
)
def test_date_resolution(captured, expr, expected):
    resolved = resolve_date_expr(expr, datetime.fromisoformat(captured), "Asia/Kuala_Lumpur")
    assert resolved[1] == expected


@pytest.mark.parametrize(
    ("captured", "expr", "expected"),
    [
        ("2026-09-14T12:00:00+08:00", "this week", ("2026-09-14", "2026-09-14")),
        ("2026-09-20T12:00:00+08:00", "this week", ("2026-09-14", "2026-09-20")),
        ("2026-09-01T00:05:00+08:00", "last month", ("2026-08-01", "2026-08-31")),
    ],
)
def test_period_resolution(captured, expr, expected):
    resolved = resolve_period_expr(expr, datetime.fromisoformat(captured), "Asia/Kuala_Lumpur")
    assert tuple(value.isoformat() for value in resolved) == expected


def test_unrecognised_dates_are_never_guessed():
    assert resolve_date_expr("sometime-ish", CAPTURED, "Asia/Kuala_Lumpur") is None
    assert resolve_period_expr("eventually", CAPTURED, "Asia/Kuala_Lumpur") is None


def test_transaction_sql_mutations_are_confined_to_executor():
    noted = Path(__file__).parents[1] / "noted"
    mutation = re.compile(r"\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+transactions\b", re.I)
    offenders = [path.name for path in noted.glob("*.py") if path.name != "execute.py" and mutation.search(path.read_text())]
    assert offenders == []


def test_soft_delete_implementation_never_hard_deletes():
    source = (Path(__file__).parents[1] / "noted" / "execute.py").read_text()
    assert not re.search(r"DELETE\s+FROM\s+transactions", source, re.I)
