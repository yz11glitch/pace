from __future__ import annotations

import io
import wave
from datetime import datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.api import create_app
from noted.conversation import resolve_create
from noted.actions import CreateTransactionAction
from noted.db import Database
from noted.llm import FakeUnderstanding
from noted.merchants import resolve_merchant_alias


CAPTURED = datetime.fromisoformat("2026-09-17T14:30:00+08:00")
HEADERS = {"X-Session-Id": "merchant-test", "X-Captured-At": CAPTURED.isoformat(),
           "X-Timezone": "Asia/Kuala_Lumpur"}


@pytest.fixture
def database(tmp_path: Path) -> Database:
    db = Database(tmp_path / "memory.db")
    db.bootstrap()
    return db


@pytest.mark.parametrize(("name", "canonical"), [
    ("zus", "ZUS Coffee"), ("zeus coffee", "ZUS Coffee"),
    ("mcd", "McDonald's"), ("  ZEU S  ", None),
    ("  ZEUS   COFFEE  ", "ZUS Coffee"),
    ("McDonald's", "McDonald's"), ("mcdonald's", "McDonald's"),
    ("ZUS-Coffee", "ZUS Coffee"), ("zeus coffees", None), ("ZUS Café", None),
])
def test_exact_alias_and_safe_normalization(database: Database, name: str, canonical: str | None):
    match = resolve_merchant_alias(name, database)
    assert (match.display_name if match else None) == canonical
    if match:
        assert match.method == "exact_alias"


def test_extracted_merchant_resolution_and_category_precedence(database: Database):
    def draft(name: str | None, category: str = "Shopping"):
        action = CreateTransactionAction(
            intent="create_transaction", amount_expr="RM14.50", direction="expense",
            merchant_expr=name, category_hint=category, evidence="RM14.50 at some place",
        )
        return resolve_create(action, captured_at=CAPTURED, tz="Asia/Kuala_Lumpur", database=database).draft

    known = draft("mcd")
    assert (known.merchant, known.category, known.merchant_id) == (
        "McDonald's", "Food & Drink", "merchant-mcdonalds")
    unknown = draft("ABC Cafe")
    assert (unknown.merchant, unknown.category, unknown.merchant_id) == ("ABC Cafe", "Shopping", None)
    assert draft(None).merchant is None
    assert draft("   ").merchant_id is None
    no_extracted_merchant = CreateTransactionAction(
        intent="create_transaction", amount_expr="RM14.50", direction="expense",
        merchant_expr=None, category_hint="Shopping", evidence="Spent RM14.50 at ZUS Coffee",
    )
    assert resolve_create(no_extracted_merchant, captured_at=CAPTURED,
                          tz="Asia/Kuala_Lumpur", database=database).draft.merchant_id is None
    with database.connect() as connection:
        assert connection.execute("SELECT count(*) FROM merchants WHERE display_name = 'ABC Cafe'").fetchone()[0] == 0
        assert connection.execute("SELECT count(*) FROM merchant_aliases WHERE alias_key = 'abc cafe'").fetchone()[0] == 0

        # The legacy merchant table requires a category; blank means no remembered category.
        connection.execute("INSERT INTO merchants (id, canonical_key, display_name, category) VALUES (?, ?, ?, ?)",
                           ("merchant-no-category", "personal place", "Personal Place", ""))
        connection.execute("INSERT INTO merchant_aliases (merchant_id, alias_key, source) VALUES (?, ?, ?)",
                           ("merchant-no-category", "pp", "user"))
    assert (draft("pp").merchant, draft("pp").category) == ("Personal Place", "Shopping")
    assert draft("pp", "Transport").category == "Transport"


def test_exact_alias_is_whole_field_and_outranks_other_aliases(database: Database):
    with database.connect() as connection:
        connection.execute("INSERT INTO merchants (id, canonical_key, display_name, category) VALUES (?, ?, ?, ?)",
                           ("merchant-coffee", "coffee", "Coffee", "Other"))
        connection.execute("INSERT INTO merchant_aliases (merchant_id, alias_key, source) VALUES (?, ?, ?)",
                           ("merchant-coffee", "coffee", "user"))
    assert resolve_merchant_alias("zeus coffee", database).display_name == "ZUS Coffee"
    assert resolve_merchant_alias("zeus coffee shop", database) is None


def test_untrusted_asr_variant_is_not_resolved(database: Database):
    with database.connect() as connection:
        connection.execute("INSERT INTO merchant_aliases (merchant_id, alias_key, source) VALUES (?, ?, ?)",
                           ("merchant-zus", "unverified variant", "asr_variant"))
    assert resolve_merchant_alias("unverified variant", database) is None


class TranscriptASR:
    model_id = "test-asr"

    def __init__(self, transcript: str):
        self.transcript = transcript
        self.calls = 0

    def load(self): pass
    def transcribe(self, _audio: bytes) -> str:
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


def test_voice_and_text_share_post_qwen_resolution(tmp_path: Path):
    text = "Was it RM14.50 at Zeus Coffee?"
    proposal = {"intent": "create_transaction", "amount_expr": "RM14.50", "direction": "expense",
                "merchant_expr": "Zeus Coffee", "category_hint": "Shopping"}
    asr = TranscriptASR(text)
    understanding = FakeUnderstanding(proposal, contract="v2")
    app = create_app(asr_service=asr, understanding_service=understanding,
                     database_path=tmp_path / "capture.db")
    with TestClient(app) as client:
        typed = client.post("/api/conversation/text", json={"text": text}, headers=HEADERS).json()
        voice = client.post("/api/transactions/voice", content=wav_bytes(), headers={
            **HEADERS, "X-Session-Id": "merchant-voice", "Content-Type": "audio/wav"}).json()
    assert asr.calls == 1
    for result in (typed, voice):
        assert result["state"] == "committed"
        assert result["path"] == "local_understanding"
        assert (result["transaction"]["merchant"], result["transaction"]["category"],
                result["transaction"]["amount_minor"]) == ("ZUS Coffee", "Food & Drink", 1450)


def test_unknown_qwen_merchant_saves_without_teaching_memory(tmp_path: Path):
    text = "Was that RM12 at ABC Cafe?"
    proposal = {"intent": "create_transaction", "amount_expr": "RM12", "direction": "expense",
                "merchant_expr": "ABC Cafe", "category_hint": "Food & Drink"}
    app = create_app(asr_service=TranscriptASR(""),
                     understanding_service=FakeUnderstanding(proposal, contract="v2"),
                     database_path=tmp_path / "unknown.db")
    with TestClient(app) as client:
        result = client.post("/api/conversation/text", json={"text": text}, headers=HEADERS).json()
    assert result["state"] == "committed"
    assert result["transaction"]["merchant"] == "ABC Cafe"
    assert result["transaction"]["category"] == "Food & Drink"
    with app.state.database.connect() as connection:
        assert connection.execute("SELECT count(*) FROM merchants WHERE display_name = 'ABC Cafe'").fetchone()[0] == 0
        assert connection.execute("SELECT count(*) FROM merchant_aliases WHERE alias_key = 'abc cafe'").fetchone()[0] == 0


def test_migration_preserves_populated_legacy_database(tmp_path: Path):
    db = Database(tmp_path / "populated.db")
    db.bootstrap()
    with db.connect() as connection:
        connection.execute("DELETE FROM schema_migrations WHERE version = '008_merchant_aliases'")
        connection.execute("DELETE FROM merchant_aliases WHERE alias_key IN ('mcd', 'zeus')")
        connection.execute("""INSERT INTO transactions
            (id, type, amount_minor, merchant, category, occurred_at, local_date, raw_transcript, created_at)
            VALUES ('legacy', 'expense', 1234, 'Unchanged', 'Other', ?, '2026-09-17', 'old', ?)""",
            (CAPTURED.isoformat(), CAPTURED.isoformat()))
    db.bootstrap()
    assert db.transaction("legacy").merchant == "Unchanged"
    assert db.transaction("legacy").amount_minor == 1234
    assert resolve_merchant_alias("mcd", db).display_name == "McDonald's"
    assert resolve_merchant_alias("zeus", db).display_name == "ZUS Coffee"
    db.bootstrap()
    with db.connect() as connection:
        assert connection.execute("SELECT count(*) FROM merchant_aliases WHERE alias_key = 'mcd'").fetchone()[0] == 1
