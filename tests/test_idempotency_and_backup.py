from __future__ import annotations

import sqlite3
import subprocess
import io
import wave
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.api import create_app
from noted.backup import BackupError, DEFAULT_BACKUP_DIR, ROOT, create_backup, restore_backup, validate_database
from noted.db import Database, MIGRATIONS
from noted.llm import FakeUnderstanding
from tests.support_capture import fixture_understanding


CAPTURE_HEADERS = {
    "X-Session-Id": "v1-test",
    "X-Captured-At": "2026-09-17T12:00:00+08:00",
    "X-Timezone": "Asia/Kuala_Lumpur",
}


class FakeASR:
    model_id = "fake"

    def __init__(self, transcript: str = "Spent RM20 at McDonald's"):
        self.transcript = transcript

    def load(self): pass
    def transcribe(self, _wav_bytes: bytes) -> str: return self.transcript
    def close(self): pass


def post(client: TestClient, text: str, request_id: str):
    return client.post(
        "/api/conversation/text", json={"text": text},
        headers={**CAPTURE_HEADERS, "X-Request-Id": request_id},
    )


def wav_bytes() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\0\0" * 4_800)
    return output.getvalue()


def counts(path: Path) -> tuple[int, int, int]:
    with sqlite3.connect(path) as connection:
        return tuple(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                     for table in ("transactions", "action_log", "request_idempotency"))


def test_first_request_and_durable_replay_return_canonical_result(tmp_path: Path):
    path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=path)
    with TestClient(app) as client:
        first = post(client, "Spent RM20 at McDonald's", "req-durable-1")
        assert first.status_code == 200
        assert first.json()["state"] == "committed"
        canonical = first.json()
        replay = post(client, "Spent RM20 at McDonald's", "req-durable-1")
        assert replay.status_code == 200
        assert replay.json()["state"] == "duplicate_ignored"
        assert replay.json()["transaction"] == canonical["transaction"]
        assert replay.json()["undo_token"] == canonical["undo_token"]
        assert counts(path) == (1, 1, 1)

    restarted = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=path)
    with TestClient(restarted) as client:
        replay = post(client, "Spent RM20 at McDonald's", "req-durable-1")
        assert replay.json()["state"] == "duplicate_ignored"
        assert replay.json()["transaction"] == canonical["transaction"]
        assert counts(path) == (1, 1, 1)


def test_voice_entry_uses_the_same_durable_request_id_semantics(tmp_path: Path):
    path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=path)
    headers = {
        **CAPTURE_HEADERS, "X-Request-Id": "req-voice", "Content-Type": "audio/wav",
    }
    audio = wav_bytes()
    with TestClient(app) as client:
        first = client.post("/api/transactions/voice", content=audio, headers=headers)
        replay = client.post("/api/transactions/voice", content=audio, headers=headers)
    assert first.json()["state"] == "committed"
    assert replay.json()["state"] == "duplicate_ignored"
    assert replay.json()["transaction"] == first.json()["transaction"]
    assert counts(path) == (1, 1, 1)

def test_request_id_collision_fails_closed_and_identical_content_with_new_ids_is_allowed(tmp_path: Path):
    path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=path)
    with TestClient(app) as client:
        assert post(client, "Spent RM20 at McDonald's", "req-collision").status_code == 200
        conflict = post(client, "Spent RM30 at McDonald's", "req-collision")
        assert conflict.status_code == 409
        assert conflict.json()["error"] == "request_id_conflict"
        assert post(client, "Spent RM20 at McDonald's", "req-separate").status_code == 200
    assert counts(path) == (2, 2, 2)


@pytest.mark.parametrize("text", ["Spent money on lunch", "Spent 1650 at a new stall"])
def test_no_write_outcomes_never_create_successful_idempotency_records(tmp_path: Path, text: str):
    path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=path)
    with TestClient(app) as client:
        result = post(client, text, "req-no-write")
        assert result.json()["state"] in {"needs_clarification", "not_understood"}
    assert counts(path) == (0, 0, 0)


def test_audit_failure_rolls_back_transaction_and_idempotency(tmp_path: Path, monkeypatch):
    path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=path)
    with TestClient(app) as client:
        monkeypatch.setattr(app.state.executor, "_log", lambda *_args, **_kwargs: (_ for _ in ()).throw(RuntimeError("audit failed")))
        result = post(client, "Spent RM20 at McDonald's", "req-audit-fail")
        assert result.json()["error_code"] == "execution_failed"
    assert counts(path) == (0, 0, 0)


def test_contribution_creation_is_idempotent(tmp_path: Path):
    path = tmp_path / "noted.db"
    app = create_app(
        asr_service=FakeASR(), database_path=path,
        understanding_service=FakeUnderstanding({
            "intent": "create_transaction", "amount_expr": "RM500",
            "direction": "contribution", "item_expr": "savings",
        }, contract="v2"),
    )
    with TestClient(app) as client:
        first = post(client, "Put RM500 into savings", "req-contribution")
        replay = post(client, "Put RM500 into savings", "req-contribution")
    assert first.json()["transaction"]["type"] == "contribution"
    assert replay.json()["state"] == "duplicate_ignored"
    assert counts(path) == (1, 1, 1)


def test_legacy_request_gets_server_request_id_without_breaking_contract(tmp_path: Path):
    app = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=tmp_path / "noted.db")
    with TestClient(app) as client:
        result = client.post(
            "/api/conversation/text", json={"text": "Spent RM12 on lunch"}, headers=CAPTURE_HEADERS,
        )
    assert result.status_code == 200
    assert result.json()["state"] == "committed"
    assert result.json()["request_id"]


def _seed(path: Path, request_id: str, text: str = "Spent RM20 at McDonald's") -> dict:
    app = create_app(asr_service=FakeASR(), understanding_service=fixture_understanding(), database_path=path)
    with TestClient(app) as client:
        return post(client, text, request_id).json()


def financial_rows(path: Path) -> list[tuple]:
    with sqlite3.connect(path) as connection:
        return connection.execute(
            "SELECT type, amount_minor, merchant, category, local_date, deleted_at FROM transactions ORDER BY id"
        ).fetchall()


def test_backup_restore_round_trip_is_wal_safe_and_pace_readable(tmp_path: Path):
    live = tmp_path / "live.db"
    backup_dir = tmp_path / "backups"
    before = _seed(live, "req-before")
    expected = financial_rows(live)
    backup = create_backup(live, backup_dir)
    validate_database(backup)

    _seed(live, "req-after", "Spent RM35 on groceries")
    with sqlite3.connect(live) as connection:
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("UPDATE transactions SET deleted_at = '2026-09-17T00:00:00+00:00' WHERE id = ?", (before["transaction"]["id"],))
    assert financial_rows(live) != expected
    post_backup_state = financial_rows(live)

    restored, safety = restore_backup(backup, live, backup_dir)
    assert restored == live
    assert safety.is_file()
    assert financial_rows(safety) == post_backup_state
    assert financial_rows(live) == expected
    validate_database(live)
    with Database(live).connect() as connection:
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations").fetchone()[0] == len(list(MIGRATIONS.glob("*.sql")))
    assert Database(live).recent_transactions()[0].id == before["transaction"]["id"]


def test_backup_names_do_not_overwrite_and_restore_rejects_bad_inputs(tmp_path: Path):
    live = tmp_path / "live.db"
    _seed(live, "req-seed")
    first = create_backup(live, tmp_path / "backups")
    second = create_backup(live, tmp_path / "backups")
    assert first != second
    assert first.is_file() and second.is_file()

    corrupt = tmp_path / "corrupt.sqlite3"
    corrupt.write_bytes(b"not sqlite")
    with pytest.raises(BackupError):
        restore_backup(corrupt, live, tmp_path / "backups")
    with pytest.raises(BackupError):
        restore_backup(tmp_path / "missing.sqlite3", live, tmp_path / "backups")
    assert financial_rows(live)


def test_backup_retention_keeps_the_newest_snapshots(tmp_path: Path):
    live = tmp_path / "live.db"
    _seed(live, "req-retention")
    backup_dir = tmp_path / "backups"
    for _ in range(3):
        create_backup(live, backup_dir, retention=2)
    assert len(list(backup_dir.glob("pace-*.sqlite3"))) == 2


def test_default_backup_location_is_private_and_repository_runtime_paths_are_ignored():
    assert ROOT not in DEFAULT_BACKUP_DIR.parents and DEFAULT_BACKUP_DIR != ROOT
    result = subprocess.run(
        ["git", "check-ignore", "data/backups/probe.sqlite3"], cwd=ROOT,
        check=False, capture_output=True, text=True,
    )
    assert result.returncode == 0
