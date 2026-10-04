from __future__ import annotations

import io
import json
import wave
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.api import create_app
from noted.db import Database
from noted.finance import category_totals, merchant_spending_totals, summarize
from noted.llm import FakeUnderstanding
from tests.support_capture import fixture_understanding


CAPTURE_HEADERS = {
    "X-Session-Id": "gate-c-test",
    "X-Captured-At": "2026-09-17T14:30:00+08:00",
    "X-Timezone": "Asia/Kuala_Lumpur",
}


class TranscriptASR:
    model_id = "test-asr"

    def __init__(self, transcript: str):
        self.transcript = transcript

    def load(self): pass
    def transcribe(self, _wav_bytes: bytes) -> str: return self.transcript
    def close(self): pass


def wav_bytes() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\0\0" * 4_800)
    return output.getvalue()


def compact_create(*, amount: str, direction: str, item: str | None = None,
                   merchant: str | None = None, category: str | None = None,
                   date: str | None = None) -> dict:
    result = {"intent": "create_transaction", "amount_expr": amount, "direction": direction}
    for key, value in {
        "item_expr": item, "merchant_expr": merchant,
        "category_hint": category, "date_expr": date,
    }.items():
        if value is not None:
            result[key] = value
    return result


def post_text(client: TestClient, text: str):
    return client.post("/api/conversation/text", json={"text": text}, headers=CAPTURE_HEADERS)


@pytest.mark.parametrize(
    ("text", "proposal", "flow", "minor", "category"),
    [
        (
            "Chicken rice was RM18.",
            compact_create(amount="RM18", direction="expense", item="Chicken rice", category="Food & Drink"),
            "expense", 1800, "Food & Drink",
        ),
        (
            "Money in was RM3,500.",
            compact_create(amount="RM3,500", direction="income", item="Money in", category="Income"),
            "income", 350000, "Income",
        ),
        (
            "Money back from the shop was RM28.50.",
            compact_create(amount="RM28.50", direction="refund", item="shop", category="Shopping"),
            "refund", 2850, "Shopping",
        ),
        (
            "Put RM500 into savings.",
            compact_create(amount="RM500", direction="contribution", item="savings"),
            "contribution", 50000, None,
        ),
    ],
)
def test_validated_llm_create_proposals_execute_all_gate_c_flow_classes(
    tmp_path: Path, text, proposal, flow, minor, category,
):
    app = create_app(
        asr_service=TranscriptASR(""), understanding_service=FakeUnderstanding(proposal, contract="v2"),
        database_path=tmp_path / "noted.db",
    )
    with TestClient(app) as client:
        response = post_text(client, text)
        assert response.status_code == 200
        body = response.json()
        assert body["state"] == "committed"
        assert body["path"] == "local_understanding"
        assert body["transaction"]["type"] == flow
        assert body["transaction"]["amount_minor"] == minor
        assert body["transaction"]["category"] == category
        assert body["undo_token"]


def test_contribution_is_not_spending_or_merchant_spending(tmp_path: Path):
    text = "Set aside RM300 for savings."
    app = create_app(
        asr_service=TranscriptASR(""),
        understanding_service=FakeUnderstanding(compact_create(
            amount="RM300", direction="contribution", item="savings",
        ), contract="v2"), database_path=tmp_path / "noted.db",
    )
    with TestClient(app) as client:
        assert post_text(client, text).json()["state"] == "committed"
        rows = app.state.database.recent_transactions()
    summary = summarize(rows)
    assert summary.contributions == 30000
    assert summary.spending == 0
    assert summary.retained == 0
    assert category_totals(rows) == {}
    assert merchant_spending_totals(rows) == {}


def test_voice_and_text_converge_on_the_same_capture_pipeline(tmp_path: Path):
    text = "Spent RM12.90 on coffee yesterday."
    app = create_app(asr_service=TranscriptASR(text), understanding_service=fixture_understanding(), database_path=tmp_path / "noted.db")
    with TestClient(app) as client:
        typed = post_text(client, text).json()
        voice = client.post(
            "/api/transactions/voice", content=wav_bytes(),
            headers={**CAPTURE_HEADERS, "X-Session-Id": "gate-c-voice", "Content-Type": "audio/wav"},
        ).json()
    assert typed["state"] == voice["state"] == "committed"
    assert typed["path"] == voice["path"] == "local_understanding"
    assert typed["transaction"]["amount_minor"] == voice["transaction"]["amount_minor"] == 1290
    assert typed["transaction"]["local_date"] == voice["transaction"]["local_date"] == "2026-09-16"


def test_voice_and_text_keep_natural_refunds_distinct_from_income(tmp_path: Path):
    text = "Got a RM40 refund from Shopee"
    app = create_app(asr_service=TranscriptASR(text), understanding_service=fixture_understanding(), database_path=tmp_path / "noted.db")
    with TestClient(app) as client:
        typed = post_text(client, text).json()
        voice = client.post(
            "/api/transactions/voice", content=wav_bytes(),
            headers={**CAPTURE_HEADERS, "X-Session-Id": "gate-c-refund-voice", "Content-Type": "audio/wav"},
        ).json()
    for result in (typed, voice):
        assert result["state"] == "committed"
        assert result["transaction"]["type"] == "refund"
        assert result["transaction"]["amount_minor"] == 4000
        assert result["transaction"]["merchant"] == "Shopee"
        assert result["transaction"]["category"] == "Shopping"


@pytest.mark.parametrize(
    ("text", "minor"),
    [
        ("Spent RM240 on groceries.", 24000),
        ("Spent RM12.90 on coffee.", 1290),
        ("Spent sixteen fifty at ZUS Coffee.", 1650),
        ("Oh and I spent 30 on Grab earlier.", 3000),
    ],
)
def test_financially_dangerous_amount_regressions_use_minor_units(tmp_path: Path, text: str, minor: int):
    app = create_app(asr_service=TranscriptASR(""), understanding_service=fixture_understanding(), database_path=tmp_path / "noted.db")
    with TestClient(app) as client:
        body = post_text(client, text).json()
        assert body["state"] == "committed"
        assert body["transaction"]["amount_minor"] == minor


def test_known_merchant_context_remains_authoritative(tmp_path: Path):
    app = create_app(asr_service=TranscriptASR(""), understanding_service=fixture_understanding(), database_path=tmp_path / "noted.db")
    with TestClient(app) as client:
        body = post_text(client, "Spent RM30 on Grab food earlier.").json()
    assert body["state"] == "committed"
    assert body["transaction"]["merchant"] == "Grab"
    assert body["transaction"]["category"] == "Food & Drink"


@pytest.mark.parametrize(
    ("text", "proposal"),
    [
        ("Actually make that RM35.", {"intent": "update_transaction", "target": {"reference": "previous"}, "changes": {"amount_expr": "RM35"}}),
        ("Delete the Grab one.", {"intent": "delete_transaction", "target": {"reference": "descriptor", "merchant_expr": "Grab"}}),
        ("How much did I spend this week?", {"intent": "query_transactions", "query": {"shape": "sum", "period_expr": "this week"}}),
    ],
)
def test_later_gate_intents_never_mutate(tmp_path: Path, text: str, proposal: dict):
    app = create_app(
        asr_service=TranscriptASR(""), understanding_service=FakeUnderstanding(proposal, contract="v2"),
        database_path=tmp_path / "noted.db",
    )
    with TestClient(app) as client:
        body = post_text(client, text).json()
        assert body["state"] == "not_understood"
        assert body["error_code"] == "unsupported_intent"
        assert client.get("/api/transactions").json() == []


def test_schema_invalid_proposal_is_stable_failure_without_mutation(tmp_path: Path):
    app = create_app(
        asr_service=TranscriptASR(""), understanding_service=FakeUnderstanding("{broken", contract="v2"),
        database_path=tmp_path / "noted.db",
    )
    with TestClient(app) as client:
        body = post_text(client, "Chicken rice was RM18.").json()
        assert body["state"] == "not_understood"
        assert body["error_code"] == "clarification_needed"
        assert client.get("/api/transactions").json() == []


@pytest.mark.parametrize(
    ("text", "proposal"),
    [
        ("Spent 1650 at a new stall.", compact_create(
            amount="1650", direction="expense", merchant="new stall",
        )),
        ("Spent money on lunch.", None),
        ("Spent RM20 on lunch on 31 February.", compact_create(
            amount="RM20", direction="expense", item="lunch", category="Food & Drink", date="31 February",
        )),
    ],
)
def test_ambiguous_or_missing_required_fields_clarify_without_mutation(tmp_path: Path, text, proposal):
    understanding = FakeUnderstanding(
        proposal or compact_create(amount="money", direction="expense"), contract="v2",
    )
    app = create_app(
        asr_service=TranscriptASR(""), understanding_service=understanding,
        database_path=tmp_path / "noted.db",
    )
    with TestClient(app) as client:
        body = post_text(client, text).json()
        assert body["state"] == "needs_clarification"
        assert body["clarification"]["question"]
        assert client.get("/api/transactions").json() == []


def test_failed_audit_write_rolls_back_and_returns_stable_failure(tmp_path: Path, monkeypatch):
    app = create_app(asr_service=TranscriptASR(""), understanding_service=fixture_understanding(), database_path=tmp_path / "noted.db")
    with TestClient(app) as client:
        def fail_log(*_args, **_kwargs):
            raise RuntimeError("simulated audit failure")

        monkeypatch.setattr(app.state.executor, "_log", fail_log)
        body = post_text(client, "Spent RM18 on chicken rice.").json()
        assert body["state"] == "not_understood"
        assert body["error_code"] == "execution_failed"
        assert client.get("/api/transactions").json() == []


def test_llm_proposal_stores_language_expression_not_minor_units(tmp_path: Path):
    text = "Put RM200 towards my savings goal."
    app = create_app(
        asr_service=TranscriptASR(""), understanding_service=FakeUnderstanding(compact_create(
            amount="RM200", direction="contribution", item="savings goal",
        ), contract="v2"), database_path=tmp_path / "noted.db",
    )
    with TestClient(app) as client:
        assert post_text(client, text).json()["state"] == "committed"
    with Database(tmp_path / "noted.db").connect() as connection:
        proposal = json.loads(connection.execute("SELECT raw_json FROM proposed_actions").fetchone()[0])
    assert proposal["amount_expr"] == "RM200"
    assert "amount_minor" not in proposal
