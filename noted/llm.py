from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import urlparse

from pydantic import ValidationError

from noted.actions import TurnProposal
from noted.compact import CompactProposal, expand_compact
from noted.normalize import canonical_text


PROMPT_VERSION = "understand_v2_primary_capture_20260922"


ACTION_MODELS = {
    "create_transaction": "CreateTransactionAction",
    "update_transaction": "UpdateTransactionAction",
    "categorize_transaction": "CategorizeTransactionAction",
    "delete_transaction": "DeleteTransactionAction",
    "query_transactions": "QueryTransactionsAction",
    "teach_memory": "TeachMemoryAction",
    "answer_clarification": "AnswerClarificationAction",
    "unsupported": "UnsupportedAction",
}


def llama_json_schema(intent: str | None = None, *, full_proposal: bool = False) -> dict:
    """Build strict, non-recursive schemas compatible with llama.cpp's sampler."""
    if intent is None and not full_proposal:
        return {
            "type": "object", "additionalProperties": False,
            "properties": {
                "intent": {"type": "string", "enum": list(ACTION_MODELS)},
                "turn_kind": {"type": "string", "enum": ["statement", "question", "correction", "answer", "mixed"]},
            },
            "required": ["intent", "turn_kind"],
        }
    source = TurnProposal.model_json_schema()
    definitions = source.get("$defs", {})

    def inline(value):
        if isinstance(value, list):
            return [inline(item) for item in value]
        if not isinstance(value, dict):
            return value
        if "$ref" in value:
            name = value["$ref"].rsplit("/", 1)[-1]
            return inline(definitions[name])
        return {
            key: inline(item) for key, item in value.items()
            if key not in {"$defs", "title", "default", "discriminator"}
        }

    if intent is not None and intent not in ACTION_MODELS:
        raise ValueError("unsupported intent schema")
    action_schema = (
        inline(definitions[ACTION_MODELS[intent]])
        if intent is not None
        else {"oneOf": [inline(definitions[name]) for name in ACTION_MODELS.values()]}
    )

    def require_declared_properties(value):
        if isinstance(value, list):
            for item in value: require_declared_properties(item)
        elif isinstance(value, dict):
            if value.get("type") == "object" and value.get("properties"):
                value["required"] = list(value["properties"])
            for item in value.values(): require_declared_properties(item)

    require_declared_properties(action_schema)
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "schema_version": {"type": "integer", "const": 1},
            "turn_kind": {"type": "string", "enum": ["statement", "question", "correction", "answer", "mixed"]},
            "actions": {
                "type": "array", "minItems": 1, "maxItems": 1, "items": action_schema,
            },
        },
        "required": ["schema_version", "turn_kind", "actions"],
    }


def compact_json_schema() -> dict:
    """Return an inlined, intent-first schema with optional properties omittable."""
    source = CompactProposal.model_json_schema()
    definitions = source.get("$defs", {})

    def inline(value):
        if isinstance(value, list):
            return [inline(item) for item in value]
        if not isinstance(value, dict):
            return value
        if "$ref" in value:
            return inline(definitions[value["$ref"].rsplit("/", 1)[-1]])
        return {
            key: inline(item) for key, item in value.items()
            if key not in {"$defs", "title", "default", "discriminator"}
        }

    return inline(source)


@dataclass(frozen=True)
class RawProposal:
    raw_json: str
    model: str
    latency_ms: int
    timings: dict | None = None


@dataclass(frozen=True)
class UnderstandingOutcome:
    status: str
    proposal: TurnProposal | None
    raw_json: str | None
    model: str | None
    latency_ms: int
    error: str | None = None


class UnderstandingService(Protocol):
    model_id: str

    def load(self) -> None: ...
    def understand(self, transcript: str, frame: str) -> RawProposal: ...
    def close(self) -> None: ...


class FakeUnderstanding:
    def __init__(self, raw_json: str | dict, model_id: str = "fake-understanding", contract: str = "v1"):
        self.raw_json = json.dumps(raw_json) if isinstance(raw_json, dict) else raw_json
        self.model_id = model_id
        self.contract = contract

    def load(self) -> None: pass

    def understand(self, transcript: str, frame: str) -> RawProposal:
        return RawProposal(self.raw_json, self.model_id, 0)

    def close(self) -> None: pass


class DisabledUnderstanding:
    model_id = "disabled"

    def load(self) -> None: pass

    def understand(self, transcript: str, frame: str) -> RawProposal:
        raise RuntimeError("shadow understanding is disabled; set NOTED_LLM_ENABLED=1")

    def close(self) -> None: pass


class LlamaServerUnderstanding:
    """Local llama.cpp client. It receives text plus a display-only frame, never a DB handle."""

    def __init__(self, base_url: str = "http://127.0.0.1:8080", model_id: str = "Qwen3.5-4B-Instruct-Q4_K_M", passes: int = 1, contract: str = "v2", timeout_seconds: float = 8.0):
        parsed = urlparse(base_url)
        if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("the understanding server must be local HTTP")
        self.base_url = base_url.rstrip("/")
        self.model_id = model_id
        if passes not in {1, 2}:
            raise ValueError("understanding inference passes must be 1 or 2")
        if contract not in {"v1", "v2"}:
            raise ValueError("understanding contract must be v1 or v2")
        self.passes = passes
        self.contract = contract
        self.timeout_seconds = timeout_seconds
        self._prompt = ""

    def load(self) -> None:
        path = Path(__file__).resolve().parents[1] / "prompts" / f"understand_{self.contract}.txt"
        self._prompt = path.read_text(encoding="utf-8")

    def understand(self, transcript: str, frame: str) -> RawProposal:
        if not self._prompt:
            self.load()
        messages = [
            {"role": "system", "content": self._prompt},
            {"role": "user", "content": f"{frame}\n\nTRANSCRIPT\n{transcript}"},
        ]
        started = time.perf_counter()
        if self.contract == "v2":
            content, timings = self._complete(messages, compact_json_schema(), 192)
            return RawProposal(
                raw_json=content, model=self.model_id,
                latency_ms=round((time.perf_counter() - started) * 1000), timings=timings,
            )
        if self.passes == 1:
            content, timings = self._complete(messages, llama_json_schema(full_proposal=True), 256)
            return RawProposal(
                raw_json=content, model=self.model_id,
                latency_ms=round((time.perf_counter() - started) * 1000), timings=timings,
            )
        selection_raw, _ = self._complete(messages, llama_json_schema(), 32)
        try:
            selection = json.loads(selection_raw)
            intent = selection["intent"]
            turn_kind = selection["turn_kind"]
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            raise RuntimeError("local understanding returned an invalid intent selection") from exc
        extraction_messages = [
            messages[0],
            {"role": "user", "content": messages[1]["content"] + f"\n\nSelected intent: {intent}. Selected turn_kind: {turn_kind}. Extract that action now."},
        ]
        content, timings = self._complete(extraction_messages, llama_json_schema(intent), 256)
        return RawProposal(
            raw_json=content, model=self.model_id,
            latency_ms=round((time.perf_counter() - started) * 1000), timings=timings,
        )

    def _complete(self, messages: list[dict], schema: dict, max_tokens: int) -> tuple[str, dict]:
        prompt = "".join(f"<|im_start|>{message['role']}\n{message['content']}<|im_end|>\n" for message in messages)
        prompt += "<|im_start|>assistant\n"
        payload = {
            "prompt": prompt,
            "json_schema": schema,
            "temperature": 0.0,
            "seed": 0,
            "n_predict": max_tokens,
            "stream": False,
        }
        request = urllib.request.Request(
            f"{self.base_url}/completion",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                body = json.load(response)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"local understanding failed: {exc}") from exc
        try:
            content = body["content"]
        except (KeyError, TypeError) as exc:
            raise RuntimeError("local understanding returned no structured content") from exc
        timing = body.get("timings", {})
        timing["cached_prompt_n"] = timing.get("cache_n")
        timing["tokens_cached_after"] = body.get("tokens_cached")
        return content, timing

    def close(self) -> None: pass


def validate_raw_proposal(raw: RawProposal, transcript: str) -> UnderstandingOutcome:
    try:
        proposal = TurnProposal.model_validate_json(raw.raw_json)
        _validate_verbatim_spans(proposal, transcript)
        _validate_intent_coherence(proposal)
    except (ValidationError, ValueError) as exc:
        return UnderstandingOutcome(
            status="clarification_needed", proposal=None, raw_json=raw.raw_json,
            model=raw.model, latency_ms=raw.latency_ms, error=str(exc),
        )
    return UnderstandingOutcome(
        status="validated", proposal=proposal, raw_json=raw.raw_json,
        model=raw.model, latency_ms=raw.latency_ms,
    )


def validate_compact_proposal(raw: RawProposal, transcript: str) -> UnderstandingOutcome:
    try:
        proposal = expand_compact(raw.raw_json, transcript)
        _validate_verbatim_spans(proposal, transcript)
        _validate_intent_coherence(proposal)
    except (ValidationError, ValueError) as exc:
        return UnderstandingOutcome(
            status="clarification_needed", proposal=None, raw_json=raw.raw_json,
            model=raw.model, latency_ms=raw.latency_ms, error=str(exc),
        )
    return UnderstandingOutcome(
        status="validated", proposal=proposal, raw_json=raw.raw_json,
        model=raw.model, latency_ms=raw.latency_ms,
    )


def understand_safely(service: UnderstandingService, transcript: str, frame: str) -> UnderstandingOutcome:
    if len(transcript.split()) > 200:
        return UnderstandingOutcome("understanding_failed", None, None, service.model_id, 0, "transcript exceeds 200 words")
    try:
        raw = service.understand(transcript, frame)
        if getattr(service, "contract", "v1") == "v2":
            return validate_compact_proposal(raw, transcript)
        return validate_raw_proposal(raw, transcript)
    except Exception as exc:
        return UnderstandingOutcome("understanding_failed", None, None, service.model_id, 0, str(exc))


def _is_span(value: str | None, transcript: str) -> bool:
    return value is None or canonical_text(value) in canonical_text(transcript)


def _validate_verbatim_spans(proposal: TurnProposal, transcript: str) -> None:
    for action in proposal.actions:
        if not _is_span(action.evidence, transcript):
            raise ValueError("evidence is not a transcript substring")
        candidates = []
        for name in ("amount_expr", "merchant_expr", "item_expr", "date_expr", "surface_expr", "context_keyword_expr", "answer_expr"):
            candidates.append(getattr(action, name, None))
        target = getattr(action, "target", None)
        changes = getattr(action, "changes", None)
        query = getattr(action, "query", None)
        for container in (target, changes, query):
            if container:
                for name in ("amount_expr", "merchant_expr", "item_expr", "date_expr", "period_expr", "compare_period_expr"):
                    candidates.append(getattr(container, name, None))
        if not all(_is_span(value, transcript) for value in candidates):
            raise ValueError("an extracted expression is not a transcript substring")


def _validate_intent_coherence(proposal: TurnProposal) -> None:
    if len(proposal.actions) > 1:
        evidence = [canonical_text(action.evidence) for action in proposal.actions]
        if len(set(evidence)) != len(evidence):
            raise ValueError("ambiguous intents share the same evidence")
