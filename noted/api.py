from __future__ import annotations

import os
import re
import hashlib
import json
import time
import uuid
from contextlib import asynccontextmanager
from datetime import date, datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from noted.audio import AudioValidationError, inspect_wav_bytes
from noted.asr import ASRService, ConfiguredASR, DEFAULT_ASR_MODEL
from noted.actions import CaptureResult, ShadowUnderstanding, TransactionPatch, TurnResult, TurnProposal, UnsupportedAction
from noted.conversation import build_understanding_frame, process_capture
from noted.capture_trace import CaptureTraceBuffer, trace_event
from noted.db import Database
from noted.execute import (
    ActionExecutor, ActionNotFoundError, DeletedTransactionError,
    RequestIdConflictError, TransactionNotFoundError, UndoConflictError, UndoNotSupportedError,
)
from noted.home import home_summary
from noted.llm import DisabledUnderstanding, LlamaServerUnderstanding, PROMPT_VERSION, UnderstandingService, understand_safely
from noted.models import PaceProfileInput, Transaction, TransactionCreate


ROOT = Path(__file__).resolve().parents[1]
MAX_AUDIO_BYTES = 4 * 1024 * 1024
SESSION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
REQUEST_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")


def _captured(value: str | None) -> datetime:
    captured_at = datetime.fromisoformat(value.replace("Z", "+00:00")) if value else datetime.now(timezone.utc)
    if captured_at.tzinfo is None or captured_at.utcoffset() is None:
        raise ValueError("X-Captured-At must include a timezone")
    return captured_at


def _request_identity(value: str | None) -> str:
    request_id = value or str(uuid.uuid4())
    if not REQUEST_ID.fullmatch(request_id):
        raise ValueError("invalid X-Request-Id")
    return request_id


def _fingerprint(kind: str, payload: bytes | str, captured_at: datetime, timezone_name: str) -> str:
    body_hash = hashlib.sha256(payload if isinstance(payload, bytes) else payload.encode("utf-8")).hexdigest()
    logical = json.dumps({
        "kind": kind, "body_sha256": body_hash,
        "captured_at": captured_at.isoformat(), "timezone": timezone_name,
    }, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(logical.encode("utf-8")).hexdigest()


def _request_conflict(request_id: str | None, exc: RequestIdConflictError) -> JSONResponse:
    return JSONResponse(status_code=409, content={
        "error": "request_id_conflict", "detail": str(exc), "request_id": request_id,
    })


def create_app(
    *,
    asr_service: ASRService | None = None,
    understanding_service: UnderstandingService | None = None,
    database_path: Path | None = None,
    now_provider=None,
) -> FastAPI:
    configured_asr = asr_service
    configured_understanding = understanding_service
    if configured_understanding is None:
        configured_understanding = LlamaServerUnderstanding(
            os.environ.get("NOTED_LLM_URL", "http://127.0.0.1:8080"),
            os.environ.get("NOTED_LLM_MODEL", "Qwen3.5-4B-Instruct-Q4_K_M"),
            int(os.environ.get("NOTED_LLM_PASSES", "1")),
            timeout_seconds=float(os.environ.get("NOTED_LLM_TIMEOUT_SECONDS", "8")),
        ) if os.environ.get("NOTED_LLM_ENABLED", "1") == "1" else DisabledUnderstanding()
    database = Database(database_path or Path(os.environ.get("NOTED_DB_PATH", ROOT / "data" / "noted.db")))
    clock = now_provider or (lambda: datetime.now(timezone.utc))

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        database.bootstrap()
        service = configured_asr or ConfiguredASR(os.environ.get("NOTED_ASR_MODEL", DEFAULT_ASR_MODEL))
        service.load()
        configured_understanding.load()
        app.state.asr = service
        app.state.understanding = configured_understanding
        app.state.database = database
        app.state.executor = ActionExecutor(database)
        try:
            yield
        finally:
            service.close()
            configured_understanding.close()

    application = FastAPI(title="Pace reference engine", version="0.1.0", lifespan=lifespan)
    trace_buffer = CaptureTraceBuffer(enabled=os.environ.get("NOTED_CAPTURE_TRACE") == "1")

    @application.middleware("http")
    async def capture_trace_middleware(request: Request, call_next):
        kind = {"/api/transactions/voice": "audio", "/api/conversation/text": "text"}.get(request.url.path)
        trace = trace_buffer.begin(kind) if kind else None
        request.state.capture_trace = trace
        trace_event(trace, "input", "received", kind=kind)
        try:
            response = await call_next(request)
            if trace is not None and not trace.has_final():
                trace.add("final", "http_result", http_status=response.status_code)
            return response
        except Exception as exc:
            trace_event(trace, "final", "failed", error=type(exc).__name__)
            raise
        finally:
            trace_buffer.finish(trace)

    @application.get("/api/dev/capture-traces")
    def get_capture_traces(request: Request, limit: int = Query(default=20, ge=1, le=50)):
        if (not trace_buffer.enabled or request.client is None
                or request.client.host not in {"127.0.0.1", "::1", "localhost", "testclient"}):
            raise HTTPException(status_code=404, detail="not found")
        return {"capacity": trace_buffer.capacity, "traces": trace_buffer.recent(limit)}

    @application.post("/api/transactions/voice", response_model=CaptureResult)
    async def create_voice_transaction(
        request: Request,
        x_captured_at: str | None = Header(default=None),
        x_timezone: str = Header(default="UTC"),
        x_session_id: str = Header(default="voice-default"),
        x_request_id: str | None = Header(default=None),
    ):
        content_type = request.headers.get("content-type", "").lower()
        if not content_type.startswith("audio/wav"):
            trace_event(request.state.capture_trace, "input", "failed", reason="invalid_content_type")
            return JSONResponse(status_code=415, content={"error": "Expected Content-Type: audio/wav"})
        body = await request.body()
        if len(body) > MAX_AUDIO_BYTES:
            trace_event(request.state.capture_trace, "input", "failed", reason="audio_too_large")
            return JSONResponse(status_code=413, content={"error": f"Audio exceeds {MAX_AUDIO_BYTES} bytes"})
        try:
            facts = inspect_wav_bytes(body)
        except AudioValidationError as exc:
            trace_event(request.state.capture_trace, "input", "failed", reason=str(exc))
            return JSONResponse(status_code=400, content={"error": str(exc)})
        if not 250 <= int(facts["duration_ms"]) <= 30_000:
            trace_event(request.state.capture_trace, "input", "failed", reason="audio_duration")
            return JSONResponse(status_code=400, content={"error": "Audio must be between 0.25 and 30 seconds"})
        trace_event(request.state.capture_trace, "input", "accepted", duration_ms=facts["duration_ms"])
        try:
            captured_at = _captured(x_captured_at)
            request_id = _request_identity(x_request_id)
            request_fingerprint = _fingerprint("voice", body, captured_at, x_timezone)
            asr_started = time.perf_counter()
            try:
                transcript = request.app.state.asr.transcribe(body).strip()
            except Exception as exc:
                trace_event(request.state.capture_trace, "whisper", "failed", error=str(exc))
                raise
            trace_event(request.state.capture_trace, "whisper", "passed" if transcript else "failed",
                        transcript=transcript, reason=None if transcript else "empty_transcript",
                        model=request.app.state.asr.model_id,
                        latency_ms=round((time.perf_counter() - asr_started) * 1000))
            if not SESSION_ID.fullmatch(x_session_id):
                raise ValueError("invalid X-Session-Id")
            result = process_capture(
                transcript=transcript, session_id=x_session_id, captured_at=captured_at,
                tz=x_timezone, database=request.app.state.database,
                executor=request.app.state.executor,
                understanding=request.app.state.understanding,
                request_id=request_id, request_fingerprint=request_fingerprint,
                trace=request.state.capture_trace,
            )
            result.request_id = request_id
        except RequestIdConflictError as exc:
            return _request_conflict(x_request_id, exc)
        except ValueError as exc:
            return JSONResponse(status_code=400, content={"error": str(exc)})
        except Exception as exc:
            return JSONResponse(status_code=503, content={"error": "Transcription failed", "detail": str(exc)})
        return result

    @application.post("/api/transactions", response_model=Transaction)
    def create_manual_transaction(
        draft: TransactionCreate,
        request: Request,
        x_request_id: str | None = Header(default=None),
    ):
        try:
            request_id = _request_identity(x_request_id)
            serialized = draft.model_dump_json()
            outcome = request.app.state.executor.create_transaction(
                draft,
                turn_id=None,
                request_id=request_id,
                request_fingerprint=_fingerprint(
                    "manual", serialized, draft.occurred_at, draft.occurred_at.tzname() or "manual",
                ),
                capture_path="manual",
            )
        except RequestIdConflictError as exc:
            return _request_conflict(x_request_id, exc)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return outcome.executed.transaction

    @application.get(
        "/api/transactions", response_model=list[Transaction],
        response_model_exclude={"__all__": {"updated_at", "deleted_at", "status"}},
    )
    def list_transactions(
        request: Request,
        limit: int = Query(default=50, ge=1, le=200),
        start_date: date | None = Query(default=None),
        end_date: date | None = Query(default=None),
        q: str | None = Query(default=None),
    ):
        if start_date is not None and end_date is not None and start_date > end_date:
            raise HTTPException(status_code=422, detail="start_date must be on or before end_date")
        return request.app.state.database.search_transactions(
            limit=limit, start_date=start_date, end_date=end_date, query=q,
        )

    @application.get("/api/profile")
    def get_profile(request: Request):
        profile = request.app.state.database.pace_profile()
        return {
            "setup_complete": profile is not None,
            "profile": profile.model_dump(mode="json") if profile else None,
        }

    @application.put("/api/profile")
    def put_profile(profile: PaceProfileInput, request: Request):
        stored = request.app.state.executor.set_pace_profile(profile)
        return {"setup_complete": True, "profile": stored.model_dump(mode="json")}

    @application.get("/api/home")
    def get_home(
        request: Request,
        x_timezone: str = Header(default="Asia/Kuala_Lumpur"),
    ):
        try:
            return home_summary(
                request.app.state.database, now=clock(), timezone_name=x_timezone,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @application.post("/api/conversation/text", response_model=CaptureResult)
    def create_text_turn(
        body: dict,
        request: Request,
        x_session_id: str = Header(),
        x_captured_at: str | None = Header(default=None),
        x_timezone: str = Header(default="UTC"),
        x_request_id: str | None = Header(default=None),
    ):
        if not SESSION_ID.fullmatch(x_session_id):
            raise HTTPException(status_code=400, detail="invalid X-Session-Id")
        if set(body) != {"text"} or not isinstance(body["text"], str) or not body["text"].strip():
            trace_event(request.state.capture_trace, "input", "failed", reason="invalid_text_body")
            raise HTTPException(status_code=422, detail="body must contain one non-empty text field")
        trace_event(request.state.capture_trace, "input", "accepted", transcript=body["text"])
        try:
            captured_at = _captured(x_captured_at)
            request_id = _request_identity(x_request_id)
            result = process_capture(
                transcript=body["text"], session_id=x_session_id,
                captured_at=captured_at, tz=x_timezone,
                database=request.app.state.database, executor=request.app.state.executor,
                understanding=request.app.state.understanding,
                request_id=request_id,
                request_fingerprint=_fingerprint("text", body["text"], captured_at, x_timezone),
                trace=request.state.capture_trace,
            )
            result.request_id = request_id
        except RequestIdConflictError as exc:
            return _request_conflict(x_request_id, exc)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return result

    @application.post("/api/conversation/shadow", response_model=ShadowUnderstanding)
    def shadow_text_turn(
        body: dict,
        request: Request,
        x_session_id: str = Header(),
        x_captured_at: str | None = Header(default=None),
        x_timezone: str = Header(default="UTC"),
    ):
        if not SESSION_ID.fullmatch(x_session_id):
            raise HTTPException(status_code=400, detail="invalid X-Session-Id")
        if set(body) != {"text"} or not isinstance(body["text"], str) or not body["text"].strip():
            raise HTTPException(status_code=422, detail="body must contain one non-empty text field")
        try:
            captured_at = _captured(x_captured_at)
            frame = build_understanding_frame(captured_at, x_timezone, request.app.state.database)
            outcome = understand_safely(request.app.state.understanding, body["text"], frame)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        persistence_proposal = outcome.proposal or TurnProposal(
            turn_kind="statement", actions=[UnsupportedAction(
                intent="unsupported", reason_hint="understanding_failed",
                evidence=body["text"], confidence=0,
            )],
        )
        request.app.state.executor.record_turn(
            session_id=x_session_id, captured_at=captured_at, timezone_name=x_timezone,
            transcript=body["text"], proposal=persistence_proposal,
            llm_model=outcome.model, llm_ms=outcome.latency_ms,
            prompt_version=PROMPT_VERSION, llm_raw_output=outcome.raw_json,
            llm_invoked=True, action_status="rejected", validation_error=outcome.error,
        )
        return ShadowUnderstanding(
            status=outcome.status, proposal=outcome.proposal, model=outcome.model,
            prompt_version=PROMPT_VERSION, latency_ms=outcome.latency_ms, error=outcome.error,
        )

    @application.post("/api/actions/{action_id}/undo", response_model=TurnResult)
    def undo_action(action_id: str, request: Request):
        context = request.app.state.database.action_context(action_id)
        if context is None:
            raise HTTPException(status_code=404, detail="action not found")
        try:
            executed = request.app.state.executor.undo(action_id)
        except ActionNotFoundError as exc:
            raise HTTPException(status_code=404, detail="action not found") from exc
        except (UndoConflictError, UndoNotSupportedError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        return TurnResult(
            turn_id=context["turn_id"] or "", session_id=context["session_id"] or "",
            transcript=context["user_text"] or "", reply="Undone.", executed=[executed],
        )

    @application.get("/api/conversation/session")
    def get_session(request: Request, x_session_id: str = Header()):
        if not SESSION_ID.fullmatch(x_session_id):
            raise HTTPException(status_code=400, detail="invalid X-Session-Id")
        row = request.app.state.database.session(x_session_id)
        return {
            "session": dict(row) if row else None,
            "focus": [transaction.model_dump(mode="json") for transaction in request.app.state.database.recent_transactions(8)],
            "pending": None,
        }

    @application.patch("/api/transactions/{transaction_id}", response_model=Transaction)
    def patch_transaction(transaction_id: str, patch: TransactionPatch, request: Request):
        changes = patch.model_dump(exclude_unset=True)
        try:
            return request.app.state.executor.update_transaction(
                transaction_id, changes, explicit_user_edit=True,
            ).transaction
        except TransactionNotFoundError as exc:
            raise HTTPException(status_code=404, detail="transaction not found") from exc
        except DeletedTransactionError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @application.delete("/api/transactions/{transaction_id}", status_code=204)
    def delete_transaction(transaction_id: str, request: Request):
        try:
            request.app.state.executor.soft_delete_transaction(transaction_id)
        except TransactionNotFoundError as exc:
            raise HTTPException(status_code=404, detail="transaction not found") from exc
        return Response(status_code=204)

    application.mount("/", StaticFiles(directory=ROOT / "public", html=True), name="public")
    return application


app = create_app()
