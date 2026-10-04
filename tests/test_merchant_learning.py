from __future__ import annotations

import io
import json
import wave
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.api import create_app
from noted.db import Database
from noted.llm import FakeUnderstanding
from noted.merchants import resolve_merchant_alias


HEADERS = {"X-Session-Id": "learning-test", "X-Captured-At": "2026-09-17T14:30:00+08:00",
           "X-Timezone": "Asia/Kuala_Lumpur"}
TRANSCRIPT = "Was it RM14.50 at Zeus Cafe?"
PROPOSAL = {"intent": "create_transaction", "amount_expr": "RM14.50", "direction": "expense",
            "merchant_expr": "Zeus Cafe", "category_hint": "Shopping"}


class CountingUnderstanding(FakeUnderstanding):
    def __init__(self):
        super().__init__(PROPOSAL, contract="v2")
        self.calls = 0

    def understand(self, transcript, frame):
        self.calls += 1
        return super().understand(transcript, frame)


class TranscriptASR:
    model_id = "test-asr"

    def __init__(self, transcript=TRANSCRIPT):
        self.transcript = transcript
        self.calls = 0

    def load(self): pass
    def transcribe(self, _audio):
        self.calls += 1
        return self.transcript
    def close(self): pass


def wav_bytes() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\0\0" * 4_800)
    return output.getvalue()


def app_for(tmp_path: Path):
    understanding = CountingUnderstanding()
    asr = TranscriptASR()
    app = create_app(asr_service=asr, understanding_service=understanding,
                     database_path=tmp_path / "learning.db")
    return app, understanding, asr


def capture(client: TestClient, *, session="learning-test", text=TRANSCRIPT) -> dict:
    response = client.post("/api/conversation/text", json={"text": text},
                           headers={**HEADERS, "X-Session-Id": session})
    assert response.status_code == 200, response.text
    return response.json()


def manual(client: TestClient, *, merchant="Zeus Cafe", category="Shopping") -> dict:
    response = client.post("/api/transactions", json={
        "type": "expense", "amount_minor": 1450, "currency": "MYR", "merchant": merchant,
        "description": None, "category": category, "subcategory": None,
        "occurred_at": "2026-09-17T14:30:00+08:00", "local_date": "2026-09-17",
        "raw_transcript": "manual entry",
    })
    assert response.status_code == 200, response.text
    return response.json()


def edit(client: TestClient, transaction_id: str, patch: dict) -> dict:
    response = client.patch(f"/api/transactions/{transaction_id}", json=patch)
    assert response.status_code == 200, response.text
    return response.json()


def test_combined_correction_teaches_future_text_and_voice_atomically(tmp_path: Path):
    app, understanding, asr = app_for(tmp_path)
    with TestClient(app) as client:
        first = capture(client)
        assert (first["transaction"]["merchant"], first["transaction"]["category"]) == ("Zeus Cafe", "Shopping")
        assert resolve_merchant_alias("zeus cafe", app.state.database) is None

        corrected = edit(client, first["transaction"]["id"],
                         {"merchant": "ZUS Coffee", "category": "Food & Drink"})
        assert understanding.calls == 1
        assert (corrected["merchant"], corrected["category"], corrected["merchant_id"]) == (
            "ZUS Coffee", "Food & Drink", "merchant-zus")
        match = resolve_merchant_alias("zeus cafe", app.state.database)
        assert (match.display_name, match.category) == ("ZUS Coffee", "Food & Drink")
        assert resolve_merchant_alias("zus coffee", app.state.database).display_name == "ZUS Coffee"

        later_text = capture(client, session="later-text")
        later_voice_response = client.post("/api/transactions/voice", content=wav_bytes(), headers={
            **HEADERS, "X-Session-Id": "later-voice", "Content-Type": "audio/wav"})
        assert later_voice_response.status_code == 200, later_voice_response.text
        later_voice = later_voice_response.json()
        assert understanding.calls == 3  # One Qwen call per capture; the edit made none.
        assert asr.calls == 1
        for result in (later_text, later_voice):
            assert result["state"] == "committed"
            assert result["path"] == "local_understanding"
            assert (result["transaction"]["merchant"], result["transaction"]["category"]) == (
                "ZUS Coffee", "Food & Drink")
        assert resolve_merchant_alias("mcd", app.state.database).display_name == "McDonald's"

    with app.state.database.connect() as connection:
        rows = connection.execute("SELECT merchant, category FROM transactions ORDER BY created_at, rowid").fetchall()
        assert [(row["merchant"], row["category"]) for row in rows] == [
            ("ZUS Coffee", "Food & Drink"), ("ZUS Coffee", "Food & Drink"),
            ("ZUS Coffee", "Food & Drink")]
        actions = connection.execute(
            "SELECT before_json, after_json FROM action_log WHERE kind = 'update_transaction'"
        ).fetchall()
        assert len(actions) == 1
        assert json.loads(actions[0]["before_json"])["merchant"] == "Zeus Cafe"
        assert json.loads(actions[0]["after_json"])["merchant"] == "ZUS Coffee"
        assert connection.execute("SELECT count(*) FROM merchants WHERE canonical_key = 'zus coffee'").fetchone()[0] == 1
        alias = connection.execute("SELECT merchant_id, source FROM merchant_aliases WHERE alias_key = 'zeus cafe'").fetchone()
        assert (alias["merchant_id"], alias["source"]) == ("merchant-zus", "user")


def test_merchant_only_correction_reuses_canonical_without_learning_old_category(tmp_path: Path):
    app, _, _ = app_for(tmp_path)
    with TestClient(app) as client:
        original = manual(client)
        changed = edit(client, original["id"], {"merchant": "  zus   coffee  "})
        assert changed["category"] == "Shopping"
        assert changed["merchant_id"] == "merchant-zus"
        match = resolve_merchant_alias("zeus cafe", app.state.database)
        assert (match.display_name, match.category) == ("ZUS Coffee", "Food & Drink")
    with app.state.database.connect() as connection:
        assert connection.execute("SELECT count(*) FROM merchants WHERE canonical_key = 'zus coffee'").fetchone()[0] == 1


def test_category_only_correction_teaches_merchant_and_overrides_future_qwen(tmp_path: Path):
    app, understanding, _ = app_for(tmp_path)
    with TestClient(app) as client:
        original = manual(client, merchant="Baker Lane")
        assert resolve_merchant_alias("baker lane", app.state.database) is None
        corrected = edit(client, original["id"], {"category": "Food & Drink"})
        assert corrected["merchant"] == "Baker Lane"
        match = resolve_merchant_alias("baker lane", app.state.database)
        assert (match.display_name, match.category) == ("Baker Lane", "Food & Drink")
        understanding.raw_json = json.dumps({**PROPOSAL, "merchant_expr": "Baker Lane"})
        later = capture(client, text="Was it RM14.50 at Baker Lane?")
        assert (later["transaction"]["merchant"], later["transaction"]["category"]) == (
            "Baker Lane", "Food & Drink")


@pytest.mark.parametrize("patch", [
    {"amount_minor": 1600},
    {"local_date": "2026-09-18", "occurred_at": "2026-09-18T14:30:00+08:00"},
    {"description": "A note"},
])
def test_non_merchant_edits_do_not_teach(tmp_path: Path, patch: dict):
    app, _, _ = app_for(tmp_path)
    with TestClient(app) as client:
        original = manual(client)
        edit(client, original["id"], patch)
        assert resolve_merchant_alias("zeus cafe", app.state.database) is None


def test_normal_create_clear_and_delete_do_not_teach(tmp_path: Path):
    app, understanding, _ = app_for(tmp_path)
    with TestClient(app) as client:
        captured = capture(client)
        assert understanding.calls == 1
        assert resolve_merchant_alias("zeus cafe", app.state.database) is None
        manual_entry = manual(client, merchant="Unknown Place")
        assert resolve_merchant_alias("unknown place", app.state.database) is None
        cleared = edit(client, captured["transaction"]["id"], {"merchant": None})
        assert (cleared["merchant"], cleared["merchant_id"]) == (None, None)
        assert resolve_merchant_alias("zeus cafe", app.state.database) is None
        assert client.delete(f"/api/transactions/{manual_entry['id']}").status_code == 204
        assert resolve_merchant_alias("unknown place", app.state.database) is None


def test_category_edit_without_merchant_does_not_teach_and_undo_reverts_learning(tmp_path: Path):
    app, _, _ = app_for(tmp_path)
    with TestClient(app) as client:
        no_merchant = manual(client, merchant=None)
        edit(client, no_merchant["id"], {"category": "Food & Drink"})
        with app.state.database.connect() as connection:
            assert connection.execute("SELECT count(*) FROM merchants WHERE is_user_taught = 1").fetchone()[0] == 0

        with app.state.database.connect() as connection:
            count_before = connection.execute("SELECT count(*) FROM merchant_aliases").fetchone()[0]
        original = manual(client)
        changed = edit(client, original["id"], {"merchant": "ZUS Coffee"})
        assert resolve_merchant_alias("zeus cafe", app.state.database) is not None
        with app.state.database.connect() as connection:
            action_id = connection.execute(
                "SELECT id FROM action_log WHERE target_id = ? AND kind = 'update_transaction'",
                (changed["id"],),
            ).fetchone()[0]
        response = client.post(f"/api/actions/{action_id}/undo")
        assert response.status_code == 200
        # Decision O5: undoing a correction reverts what it taught.
        assert resolve_merchant_alias("zeus cafe", app.state.database) is None
        with app.state.database.connect() as connection:
            assert connection.execute("SELECT count(*) FROM merchant_aliases").fetchone()[0] == count_before


def test_repeated_correction_reassigns_original_alias_without_duplicate(tmp_path: Path):
    app, _, _ = app_for(tmp_path)
    with TestClient(app) as client:
        first = capture(client)["transaction"]
        edit(client, first["id"], {"merchant": "ZUS Coffee", "category": "Food & Drink"})
        second = capture(client, session="repeat")["transaction"]
        assert second["merchant"] == "ZUS Coffee"
        changed = edit(client, second["id"], {"merchant": "Zeus Café KL", "category": "Groceries"})
        assert (changed["merchant"], changed["category"]) == ("Zeus Café KL", "Groceries")
        match = resolve_merchant_alias("zeus cafe", app.state.database)
        assert (match.display_name, match.category) == ("Zeus Café KL", "Groceries")
        assert resolve_merchant_alias("Zeus Café KL", app.state.database).display_name == "Zeus Café KL"
        assert resolve_merchant_alias("ZUS Coffee", app.state.database).display_name == "ZUS Coffee"
        assert app.state.database.transaction(first["id"]).merchant == "ZUS Coffee"
    with app.state.database.connect() as connection:
        assert connection.execute("SELECT count(*) FROM merchant_aliases WHERE alias_key = 'zeus cafe'").fetchone()[0] == 1


def test_failed_audit_rolls_back_edit_and_learning(tmp_path: Path, monkeypatch):
    app, _, _ = app_for(tmp_path)
    with TestClient(app) as client:
        original = manual(client)
        def fail_log(*_args, **_kwargs):
            raise RuntimeError("audit failed")
        monkeypatch.setattr(app.state.executor, "_log", fail_log)
        with pytest.raises(RuntimeError, match="audit failed"):
            client.patch(f"/api/transactions/{original['id']}", json={
                "merchant": "ZUS Coffee", "category": "Food & Drink"})
        assert app.state.database.transaction(original["id"]).merchant == "Zeus Cafe"
        assert resolve_merchant_alias("zeus cafe", app.state.database) is None
