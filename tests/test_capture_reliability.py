from __future__ import annotations

import io
import json
import wave
from pathlib import Path

from fastapi.testclient import TestClient

from noted.api import create_app
from noted.capture_trace import CaptureTraceBuffer
from noted.llm import RawProposal
from noted.merchants import resolve_merchant_alias
from noted.normalize import recover_amount


CORPUS = Path(__file__).parent / "data" / "capture_utterances.jsonl"
CASES = [json.loads(line) for line in CORPUS.read_text(encoding="utf-8").splitlines()]
HEADERS = {"X-Session-Id": "corpus-test", "X-Captured-At": "2026-09-17T14:30:00+08:00",
           "X-Timezone": "Asia/Kuala_Lumpur"}


class FixtureUnderstanding:
    model_id = "fixture-understanding"
    contract = "v2"

    def __init__(self, cases=CASES):
        self.proposals = {case["text"]: case["proposal"] for case in cases}
        self.calls: list[str] = []

    def load(self): pass
    def understand(self, transcript: str, _frame: str) -> RawProposal:
        self.calls.append(transcript)
        return RawProposal(json.dumps(self.proposals[transcript]), self.model_id, 0)
    def close(self): pass


class TranscriptASR:
    model_id = "fixture-whisper"

    def __init__(self, transcript: str):
        self.transcript = transcript

    def load(self): pass
    def transcribe(self, _audio: bytes) -> str: return self.transcript
    def close(self): pass


def wav_bytes() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\0\0" * 4_800)
    return output.getvalue()


def test_realistic_utterance_corpus_through_text_api(tmp_path: Path):
    understanding = FixtureUnderstanding()
    app = create_app(asr_service=TranscriptASR(""), understanding_service=understanding,
                     database_path=tmp_path / "corpus.db")
    with TestClient(app) as client:
        for case in CASES:
            response = client.post("/api/conversation/text", json={"text": case["text"]}, headers=HEADERS)
            assert response.status_code == 200, (case["id"], response.text)
            result = response.json()
            assert result["state"] == "committed", (case["id"], result)
            actual = result["transaction"]
            for field, expected in case["expected"].items():
                assert actual[field] == expected, (case["id"], field, actual[field], expected)
        assert "AEON groceries 36" in understanding.calls
        assert "Starbucks 18 bucks" in understanding.calls
        assert "Refund from Lazada 55" in understanding.calls
        assert resolve_merchant_alias("abc cafe", app.state.database) is None


def test_bare_amount_safety_is_flow_specific(tmp_path: Path):
    assert recover_amount("800").amount_minor is None
    assert recover_amount("1200").amount_minor is None
    service = FixtureUnderstanding([{
        "text": "Spent 800 at a new stall?",
        "proposal": {"intent": "create_transaction", "amount_expr": "800", "direction": "expense"},
    }])
    app = create_app(asr_service=TranscriptASR(""), understanding_service=service,
                     database_path=tmp_path / "unsafe.db")
    with TestClient(app) as client:
        response = client.post("/api/conversation/text", json={"text": "Spent 800 at a new stall?"}, headers=HEADERS)
        assert response.json()["state"] == "needs_clarification"
        assert client.get("/api/transactions").json() == []


def test_trace_shows_text_and_voice_stages_and_validation_failure(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("NOTED_CAPTURE_TRACE", "1")
    service = FixtureUnderstanding([
        {"text": "Was it RM14.50 at Zeus Coffee?",
         "proposal": {"intent": "create_transaction", "amount_expr": "RM14.50",
                      "direction": "expense", "merchant_expr": "Zeus Coffee", "category_hint": "Shopping"}},
        {"text": "Zeus Coffee fourteen fifty",
         "proposal": {"intent": "create_transaction", "amount_expr": "fourteen fifty",
                      "direction": "expense", "merchant_expr": "Zeus Coffee", "category_hint": "Shopping"}},
        {"text": "Spent 1650 at a new stall.",
         "proposal": {"intent": "create_transaction", "amount_expr": "1650",
                      "direction": "expense", "merchant_expr": "new stall"}},
    ])
    app = create_app(asr_service=TranscriptASR("Zeus Coffee fourteen fifty"),
                     understanding_service=service, database_path=tmp_path / "trace.db")
    with TestClient(app) as client:
        text_result = client.post("/api/conversation/text", json={"text": "Was it RM14.50 at Zeus Coffee?"}, headers=HEADERS)
        assert text_result.json()["state"] == "committed"
        voice_result = client.post("/api/transactions/voice", content=wav_bytes(), headers={
            **HEADERS, "X-Session-Id": "voice-trace", "Content-Type": "audio/wav"})
        assert voice_result.json()["state"] == "committed"
        failed = client.post("/api/conversation/text", json={"text": "Spent 1650 at a new stall."}, headers=HEADERS)
        assert failed.json()["state"] == "needs_clarification"
        response = client.get("/api/dev/capture-traces")
        assert response.status_code == 200
        traces = response.json()["traces"]
        assert response.json()["capacity"] == 50
        assert len(traces) == 3
        by_kind = {trace["kind"]: trace for trace in traces if trace["stages"][-1]["status"] == "committed"}
        text_stages = {stage["stage"]: stage for stage in by_kind["text"]["stages"]}
        assert set(text_stages) == {"input", "qwen", "normalization", "merchant_resolution", "validation", "final"}
        assert text_stages["qwen"]["proposal"]["merchant_expr"] == "Zeus Coffee"
        assert text_stages["merchant_resolution"]["canonical"] == "ZUS Coffee"
        voice_stages = {stage["stage"]: stage for stage in by_kind["audio"]["stages"]}
        assert voice_stages["whisper"]["transcript"] == "Zeus Coffee fourteen fifty"
        assert voice_stages["final"]["merchant"] == "ZUS Coffee"
        assert not any("audio_bytes" in stage for trace in traces for stage in trace["stages"])
        failed_stages = {stage["stage"]: stage for stage in traces[0]["stages"]}
        assert failed_stages["validation"]["status"] == "failed"
        assert failed_stages["final"]["status"] == "needs_clarification"


def test_trace_is_opt_in_local_and_bounded(tmp_path: Path):
    buffer = CaptureTraceBuffer(enabled=True, capacity=2)
    for _ in range(3):
        trace = buffer.begin("text")
        trace.add("input", "accepted", transcript="x" * 2000)
        buffer.finish(trace)
    assert len(buffer.recent()) == 2
    assert len(buffer.recent()[0]["stages"][0]["transcript"]) == 1000
    app = create_app(asr_service=TranscriptASR(""), database_path=tmp_path / "disabled.db")
    with TestClient(app) as client:
        assert client.get("/api/dev/capture-traces").status_code == 404


def test_empty_whisper_result_is_identified_in_trace(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("NOTED_CAPTURE_TRACE", "1")
    app = create_app(asr_service=TranscriptASR(""), database_path=tmp_path / "empty-asr.db")
    with TestClient(app) as client:
        response = client.post("/api/transactions/voice", content=wav_bytes(), headers={
            **HEADERS, "Content-Type": "audio/wav"})
        assert response.json()["state"] == "needs_clarification"
        trace = client.get("/api/dev/capture-traces").json()["traces"][0]
        whisper = next(stage for stage in trace["stages"] if stage["stage"] == "whisper")
        assert (whisper["status"], whisper["reason"]) == ("failed", "empty_transcript")
