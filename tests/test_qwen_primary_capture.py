from __future__ import annotations

import io
import json
import wave

from fastapi.testclient import TestClient

from noted.api import create_app
from noted.llm import RawProposal
from noted.normalize import recover_amount


HEADERS = {"X-Session-Id": "qwen-primary", "X-Captured-At": "2026-09-22T12:00:00+08:00",
           "X-Timezone": "Asia/Kuala_Lumpur"}


class Responses:
    model_id = "fixture-qwen"
    contract = "v2"

    def __init__(self, responses):
        self.responses = responses
        self.calls = []
        self.frames = []

    def load(self): pass
    def close(self): pass

    def understand(self, transcript, frame):
        self.calls.append(transcript)
        self.frames.append(frame)
        return RawProposal(json.dumps(self.responses[transcript]), self.model_id, 0)


class TranscriptASR:
    model_id = "fixture-whisper"

    def __init__(self, transcript):
        self.transcript = transcript
        self.calls = 0

    def load(self): pass
    def close(self): pass

    def transcribe(self, audio):
        self.calls += 1
        return self.transcript


def wav_bytes():
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\0\0" * 4_800)
    return output.getvalue()


def test_parser_failure_does_not_preempt_one_qwen_call(tmp_path):
    text = "Lunch was 20."
    service = Responses({text: {"intent": "create_transaction", "amount_expr": "20",
                                "direction": "expense", "item_expr": "Lunch",
                                "category_hint": "Food & Drink"}})
    app = create_app(asr_service=TranscriptASR(text), understanding_service=service,
                     database_path=tmp_path / "capture.db")
    with TestClient(app) as client:
        result = client.post("/api/conversation/text", json={"text": text}, headers=HEADERS).json()
    assert service.calls == [text]
    assert "known_merchants_sample" not in service.frames[0]
    assert "recent_transactions" not in service.frames[0]
    assert result["path"] == "local_understanding"
    assert result["state"] == "committed"
    assert (result["transaction"]["amount_minor"], result["transaction"]["description"]) == (2000, "Lunch")


def test_model_refund_direction_is_preserved_through_voice(tmp_path):
    text = "Shopee gave me 42 back"
    service = Responses({text: {"intent": "create_transaction", "amount_expr": "42",
                                "direction": "refund", "merchant_expr": "Shopee"}})
    asr = TranscriptASR(text)
    app = create_app(asr_service=asr, understanding_service=service,
                     database_path=tmp_path / "capture.db")
    with TestClient(app) as client:
        result = client.post("/api/transactions/voice", content=wav_bytes(),
                             headers={**HEADERS, "Content-Type": "audio/wav"}).json()
    assert asr.calls == 1
    assert service.calls == [text]
    assert result["state"] == "committed"
    assert (result["transaction"]["type"], result["transaction"]["merchant"]) == ("refund", "Shopee")


def test_unspoken_merchant_is_rejected_after_qwen(tmp_path):
    text = "Coffee came to twelve fifty"
    service = Responses({text: {"intent": "create_transaction", "amount_expr": "twelve fifty",
                                "direction": "expense", "merchant_expr": "ZUS Coffee",
                                "item_expr": "Coffee"}})
    app = create_app(asr_service=TranscriptASR(text), understanding_service=service,
                     database_path=tmp_path / "capture.db")
    with TestClient(app) as client:
        result = client.post("/api/conversation/text", json={"text": text}, headers=HEADERS).json()
        assert client.get("/api/transactions").json() == []
    assert service.calls == [text]
    assert result["state"] == "not_understood"


def test_ambiguous_numeric_amount_clarifies_after_qwen(tmp_path):
    text = "Paid 1650 at the kiosk"
    service = Responses({text: {"intent": "create_transaction", "amount_expr": "1650",
                                "direction": "expense", "merchant_expr": "kiosk"}})
    app = create_app(asr_service=TranscriptASR(text), understanding_service=service,
                     database_path=tmp_path / "capture.db")
    with TestClient(app) as client:
        result = client.post("/api/conversation/text", json={"text": text}, headers=HEADERS).json()
        assert client.get("/api/transactions").json() == []
    assert service.calls == [text]
    assert result["state"] == "needs_clarification"
    assert result["clarification"]["alternatives_minor"] == [1650, 165000]


def test_alternative_amount_expression_cannot_silently_choose_first(tmp_path):
    assert recover_amount("20 or so").amount_minor == 2000
    assert recover_amount("18 or 80").amount_minor is None
    text = "Maybe 18 or 80 for the cab"
    service = Responses({text: {"intent": "create_transaction", "amount_expr": "18 or 80",
                                "direction": "expense", "item_expr": "cab"}})
    app = create_app(asr_service=TranscriptASR(text), understanding_service=service,
                     database_path=tmp_path / "capture.db")
    with TestClient(app) as client:
        result = client.post("/api/conversation/text", json={"text": text}, headers=HEADERS).json()
        assert client.get("/api/transactions").json() == []
    assert service.calls == [text]
    assert result["state"] == "needs_clarification"
