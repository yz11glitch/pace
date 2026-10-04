from __future__ import annotations

import io
import sqlite3
import wave
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.api import create_app
from noted.db import Database
from tests.support_capture import fixture_understanding


class FakeASR:
    model_id = "fake"

    def __init__(self, transcript: str):
        self.transcript = transcript

    def load(self): pass
    def transcribe(self, _wav_bytes: bytes) -> str: return self.transcript
    def close(self): pass


class FailingASR(FakeASR):
    def transcribe(self, _wav_bytes: bytes) -> str:
        raise RuntimeError("ASR unavailable")


def wav_bytes(duration_ms: int = 300) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\0\0" * round(16_000 * duration_ms / 1000))
    return output.getvalue()


def test_voice_transaction_persists_and_history_returns_it(tmp_path: Path):
    db_path = tmp_path / "noted.db"
    app = create_app(understanding_service=fixture_understanding(), asr_service=FakeASR("Spent sixteen fifty at ZUS Coffee."), database_path=db_path)
    with TestClient(app) as client:
        response = client.post(
            "/api/transactions/voice",
            content=wav_bytes(),
            headers={"Content-Type": "audio/wav", "X-Captured-At": "2026-09-14T20:30:00+08:00", "X-Timezone": "Asia/Kuala_Lumpur"},
        )
        assert response.status_code == 200
        assert response.json()["state"] == "committed"
        assert response.json()["transaction"]["amount_minor"] == 1650
        assert response.json()["transaction"]["merchant"] == "ZUS Coffee"
        assert "amount_minor" not in response.json()
        history = client.get("/api/transactions").json()
        assert len(history) == 1
        assert history[0]["id"] == response.json()["transaction"]["id"]


def test_voice_clarification_uses_capture_result_and_does_not_save(tmp_path: Path):
    db_path = tmp_path / "noted.db"
    app = create_app(understanding_service=fixture_understanding(), asr_service=FakeASR("Spent 1650 at a new stall."), database_path=db_path)
    with TestClient(app) as client:
        response = client.post("/api/transactions/voice", content=wav_bytes(), headers={"Content-Type": "audio/wav"})
        assert response.status_code == 200
        assert response.json()["state"] == "needs_clarification"
        assert response.json()["clarification"]["question"]
        assert "status" not in response.json()
        assert client.get("/api/transactions").json() == []
    database = Database(db_path)
    assert database.recent_transactions() == []


def manual_payload(flow: str, amount: int, *, category="Other", day="2026-09-10", label="Manual"):
    return {
        "type": flow,
        "amount_minor": amount,
        "currency": "MYR",
        "merchant": label,
        "description": f"{label} description",
        "category": category,
        "occurred_at": f"{day}T12:00:00+08:00",
        "local_date": day,
        "raw_transcript": "manual entry",
    }


def test_manual_create_supports_all_flow_classes_and_audits(tmp_path: Path):
    path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(""), database_path=path)
    cases = [
        ("expense", 1800, "Food & Drink"),
        ("income", 350000, "Income"),
        ("refund", 2850, "Shopping"),
        ("contribution", 50000, None),
    ]
    with TestClient(app) as client:
        for index, (flow, amount, category) in enumerate(cases):
            response = client.post(
                "/api/transactions",
                json=manual_payload(flow, amount, category=category, label=f"Manual {flow}"),
                headers={"X-Request-Id": f"manual-{index}"},
            )
            assert response.status_code == 200
            assert response.json()["type"] == flow
            assert response.json()["amount_minor"] == amount
            assert response.json()["category"] == category
    with sqlite3.connect(path) as connection:
        assert connection.execute("SELECT COUNT(*) FROM transactions").fetchone()[0] == 4
        assert connection.execute(
            "SELECT COUNT(*) FROM action_log WHERE kind = 'create_transaction' AND turn_id IS NULL"
        ).fetchone()[0] == 4
        assert connection.execute("SELECT COUNT(*) FROM turns").fetchone()[0] == 0


def test_invalid_manual_input_and_contribution_category_invariant_create_no_write(tmp_path: Path):
    path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(""), database_path=path)
    with TestClient(app) as client:
        invalid_amount = client.post(
            "/api/transactions", json=manual_payload("expense", 0),
            headers={"X-Request-Id": "invalid-amount"},
        )
        invalid_contribution = client.post(
            "/api/transactions", json=manual_payload("contribution", 50000, category="Other"),
            headers={"X-Request-Id": "invalid-contribution"},
        )
        invalid_expense = client.post(
            "/api/transactions", json=manual_payload("expense", 1800, category=None),
            headers={"X-Request-Id": "invalid-expense"},
        )
        assert {invalid_amount.status_code, invalid_contribution.status_code, invalid_expense.status_code} == {422}
        assert client.get("/api/transactions").json() == []
    with sqlite3.connect(path) as connection:
        assert connection.execute("SELECT COUNT(*) FROM action_log").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM request_idempotency").fetchone()[0] == 0


def test_manual_create_request_id_is_durable_and_conflicts_fail_closed(tmp_path: Path):
    path = tmp_path / "noted.db"
    payload = manual_payload("expense", 1800)
    app = create_app(asr_service=FakeASR(""), database_path=path)
    with TestClient(app) as client:
        first = client.post("/api/transactions", json=payload, headers={"X-Request-Id": "manual-retry"})
        retry = client.post("/api/transactions", json=payload, headers={"X-Request-Id": "manual-retry"})
        conflict = client.post(
            "/api/transactions", json={**payload, "amount_minor": 1900},
            headers={"X-Request-Id": "manual-retry"},
        )
        assert retry.json() == first.json()
        assert conflict.status_code == 409
        assert conflict.json()["error"] == "request_id_conflict"
    restarted = create_app(asr_service=FakeASR(""), database_path=path)
    with TestClient(restarted) as client:
        assert client.post(
            "/api/transactions", json=payload, headers={"X-Request-Id": "manual-retry"},
        ).json() == first.json()
    with sqlite3.connect(path) as connection:
        assert connection.execute("SELECT COUNT(*) FROM transactions").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM action_log").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM request_idempotency").fetchone()[0] == 1


def test_manual_create_audit_failure_is_atomic(tmp_path: Path, monkeypatch):
    path = tmp_path / "noted.db"
    app = create_app(asr_service=FakeASR(""), database_path=path)
    with TestClient(app) as client:
        monkeypatch.setattr(
            app.state.executor, "_log",
            lambda *_args, **_kwargs: (_ for _ in ()).throw(RuntimeError("audit failed")),
        )
        with pytest.raises(RuntimeError, match="audit failed"):
            client.post(
                "/api/transactions", json=manual_payload("expense", 1800),
                headers={"X-Request-Id": "manual-audit-fail"},
            )
    with sqlite3.connect(path) as connection:
        assert connection.execute("SELECT COUNT(*) FROM transactions").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM action_log").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM request_idempotency").fetchone()[0] == 0


def test_history_date_search_category_limit_and_soft_delete(tmp_path: Path):
    app = create_app(asr_service=FakeASR(""), database_path=tmp_path / "noted.db")
    rows = [
        manual_payload("expense", 1800, category="Food & Drink", day="2026-08-31", label="Old Cafe"),
        manual_payload("expense", 2400, category="Transport", day="2026-09-01", label="Grab"),
        manual_payload("income", 350000, category="Income", day="2026-09-15", label="Payroll"),
        manual_payload("contribution", 50000, category=None, day="2026-09-30", label="Savings"),
        manual_payload("refund", 900, category="Food & Drink", day="2026-10-01", label="CAFE REFUND"),
    ]
    with TestClient(app) as client:
        created = [client.post(
            "/api/transactions", json=row, headers={"X-Request-Id": f"history-{i}"},
        ).json() for i, row in enumerate(rows)]
        september = client.get(
            "/api/transactions", params={"start_date": "2026-09-01", "end_date": "2026-09-30", "limit": 200},
        )
        assert september.status_code == 200
        assert [row["type"] for row in september.json()] == ["contribution", "income", "expense"]
        assert [row["type"] for row in client.get("/api/transactions", params={"q": "cafe"}).json()] == ["refund", "expense"]
        assert [row["type"] for row in client.get("/api/transactions", params={"q": "transport"}).json()] == ["expense"]
        assert client.get("/api/transactions", params={"q": "%"}).json() == []
        assert len(client.get("/api/transactions", params={"limit": 200}).json()) == 5
        assert client.get("/api/transactions", params={"limit": 201}).status_code == 422
        assert client.get(
            "/api/transactions", params={"start_date": "2026-10-01", "end_date": "2026-09-01"},
        ).status_code == 422
        assert client.delete(f"/api/transactions/{created[1]['id']}").status_code == 204
        assert client.get("/api/transactions", params={"q": "grab"}).json() == []


def test_voice_and_text_not_understood_have_equivalent_capture_shapes(tmp_path: Path):
    transcript = "Delete the last one"
    app = create_app(understanding_service=fixture_understanding(), asr_service=FakeASR(transcript), database_path=tmp_path / "noted.db")
    headers = {
        "X-Session-Id": "shape-test", "X-Captured-At": "2026-09-17T12:00:00+08:00",
        "X-Timezone": "Asia/Kuala_Lumpur",
    }
    with TestClient(app) as client:
        typed = client.post("/api/conversation/text", json={"text": transcript}, headers=headers)
        voice = client.post(
            "/api/transactions/voice", content=wav_bytes(),
            headers={**headers, "X-Session-Id": "shape-voice", "Content-Type": "audio/wav"},
        )
    assert typed.status_code == voice.status_code == 200
    assert typed.json()["state"] == voice.json()["state"] == "not_understood"
    assert set(typed.json()) == set(voice.json())
    assert "status" not in voice.json()


def test_voice_genuine_transport_errors_remain_http_errors(tmp_path: Path):
    app = create_app(asr_service=FakeASR("Spent RM5 on tea"), database_path=tmp_path / "noted.db")
    with TestClient(app) as client:
        wrong_type = client.post("/api/transactions/voice", content=b"no", headers={"Content-Type": "text/plain"})
        bad_audio = client.post("/api/transactions/voice", content=b"not a wav", headers={"Content-Type": "audio/wav"})
    assert wrong_type.status_code == 415
    assert bad_audio.status_code == 400
    assert "state" not in wrong_type.json()
    assert "state" not in bad_audio.json()

    failing_app = create_app(asr_service=FailingASR(""), database_path=tmp_path / "failing.db")
    with TestClient(failing_app) as client:
        transcription = client.post(
            "/api/transactions/voice", content=wav_bytes(), headers={"Content-Type": "audio/wav"},
        )
    assert transcription.status_code == 503
    assert "state" not in transcription.json()
