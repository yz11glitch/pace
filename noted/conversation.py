from __future__ import annotations

import time
from datetime import datetime
from zoneinfo import ZoneInfo

from noted.actions import (
    CaptureClarification, CaptureResult, CreateTransactionAction,
    DeterministicResolution, TurnProposal, UnsupportedAction,
)
from noted.capture_trace import CaptureTrace, trace_event
from noted.dates import resolve_date_expr
from noted.db import Database
from noted.merchants import resolve_merchant_alias
from noted.models import TransactionCreate
from noted.normalize import AmountResolution, recover_amount
from noted.execute import RequestIdConflictError


def build_understanding_frame(captured_at: datetime, tz: str, database: Database) -> str:
    local = captured_at.astimezone(ZoneInfo(tz))
    # Capture does not resolve conversational references. Supplying unrelated
    # transaction or merchant names here can make the model invent a source;
    # trusted merchant memory is resolved only after verbatim extraction.
    return "\n".join([
        "CONTEXT",
        f"  now_local: {local.strftime('%Y-%m-%d %H:%M')} ({tz})",
        "  pending_question: none",
    ])


def resolve_create(action: CreateTransactionAction, *, captured_at: datetime, tz: str,
                   database: Database, amount: AmountResolution | None = None,
                   occurred: tuple[datetime, str] | None = None) -> DeterministicResolution | None:
    amount = amount or recover_amount(action.amount_expr, whole_bare=action.direction in {"income", "contribution"})
    occurred = occurred or resolve_date_expr(action.date_expr or "today", captured_at, tz)
    if amount.amount_minor is None or occurred is None or action.direction is None:
        return None
    merchant = resolve_merchant_alias(action.merchant_expr, database, context=action.evidence)
    category = None if action.direction == "contribution" else (
        (merchant.category if merchant and merchant.category else action.category_hint) or (
            "Income" if action.direction == "income" else "Other"
        )
    )
    subcategory = merchant.subcategory if merchant and action.direction != "contribution" else None
    draft = TransactionCreate(
        type=action.direction, amount_minor=amount.amount_minor, currency="MYR",
        merchant_id=merchant.merchant_id if merchant else None,
        merchant=merchant.display_name if merchant else action.merchant_expr,
        description=action.item_expr, category=category, subcategory=subcategory,
        occurred_at=occurred[0], local_date=occurred[1], raw_transcript=action.evidence,
    )
    return DeterministicResolution(
        draft=draft, amount_rung=amount.rung,
        merchant_alias_id=merchant.alias_id if merchant else None,
    )


def _clarification(reason: str, *, alternatives: tuple[int, ...] = ()) -> CaptureClarification:
    if alternatives:
        question = "Which amount did you mean?"
    elif "amount" in reason.casefold():
        question = "What amount should I record?"
    elif "date" in reason.casefold():
        question = "When did this transaction happen?"
    elif "type" in reason.casefold() or "direction" in reason.casefold():
        question = "Was this spending, income, a refund, or a savings contribution?"
    else:
        question = "What transaction should I record?"
    return CaptureClarification(
        reason=reason, question=question, alternatives_minor=list(alternatives),
    )


def _action_fields(action) -> dict:
    if isinstance(action, CreateTransactionAction):
        return {"intent": action.intent, "direction": action.direction,
                "amount_expr": action.amount_expr, "merchant_expr": action.merchant_expr,
                "category_hint": action.category_hint, "date_expr": action.date_expr}
    return {"intent": action.intent}


def process_capture(*, transcript: str, session_id: str, captured_at: datetime, tz: str,
                    database: Database, executor, understanding, request_id: str | None = None,
                    request_fingerprint: str | None = None,
                    trace: CaptureTrace | None = None) -> CaptureResult:
    """The sole voice/text transcript-to-create pipeline for Gate C."""
    from noted.llm import PROMPT_VERSION, understand_safely

    if request_id is not None and request_fingerprint is not None:
        replay = executor.replay(request_id, request_fingerprint)
        if replay is not None:
            trace_event(trace, "qwen", "skipped", reason="idempotent_replay")
            trace_event(trace, "merchant_resolution", "skipped", reason="idempotent_replay")
            trace_event(trace, "validation", "skipped", reason="idempotent_replay")
            trace_event(trace, "final", "duplicate_ignored", transaction_id=replay.executed.transaction.id)
            return CaptureResult(
                state="duplicate_ignored", turn_id=replay.turn_id, session_id=replay.session_id,
                transcript=replay.transcript, reply=replay.reply,
                transaction=replay.executed.transaction, executed=[replay.executed],
                undo_token=replay.executed.undo_token, path=replay.path,
            )

    if not transcript.strip():
        # Whisper supplied no language to interpret. This is an input failure,
        # not a deterministic interpretation of a natural-language capture.
        reason = "ASR returned an empty transcript"
        trace_event(trace, "qwen", "skipped", reason="empty_transcript")
        trace_event(trace, "normalization", "skipped", reason="empty_transcript")
        trace_event(trace, "merchant_resolution", "skipped", reason="empty_transcript")
        trace_event(trace, "validation", "failed", reason=reason)
        fallback = TurnProposal(turn_kind="statement", actions=[UnsupportedAction(
            intent="unsupported", reason_hint=reason, evidence=transcript, confidence=1,
        )])
        turn_id, _ = executor.record_turn(
            session_id=session_id, captured_at=captured_at, timezone_name=tz,
            transcript=transcript, proposal=fallback, llm_invoked=False,
            action_status="rejected", validation_error=reason,
        )
        clarification = CaptureClarification(reason=reason, question="Please try speaking again.")
        reply = f"{clarification.question} Nothing was saved."
        executor.set_turn_reply(turn_id, reply)
        trace_event(trace, "final", "needs_clarification", reason=reason)
        return CaptureResult(
            state="needs_clarification", turn_id=turn_id, session_id=session_id,
            transcript=transcript, reply=reply, clarification=clarification,
        )

    # Natural-language capture has one semantic interpreter. The legacy parser
    # remains available for its historical regression corpus, never as a gate here.
    frame = build_understanding_frame(captured_at, tz, database)
    llm_outcome = understand_safely(understanding, transcript, frame)
    path = "local_understanding"
    proposal = llm_outcome.proposal
    trace_event(trace, "qwen", "passed" if proposal else "failed",
                model=llm_outcome.model, latency_ms=llm_outcome.latency_ms,
                proposal=_action_fields(proposal.actions[0]) if proposal else None,
                error=llm_outcome.error)
    if proposal is None:
        trace_event(trace, "normalization", "skipped", reason="no_valid_proposal")
        trace_event(trace, "merchant_resolution", "skipped", reason="no_valid_proposal")
        trace_event(trace, "validation", "skipped", reason="no_valid_proposal")
        fallback = TurnProposal(turn_kind="statement", actions=[UnsupportedAction(
            intent="unsupported", reason_hint="understanding_failed",
            evidence=transcript, confidence=0,
        )])
        turn_id, _ = executor.record_turn(
            session_id=session_id, captured_at=captured_at, timezone_name=tz,
            transcript=transcript, proposal=fallback, llm_model=llm_outcome.model,
            llm_ms=llm_outcome.latency_ms, prompt_version=PROMPT_VERSION,
            llm_raw_output=llm_outcome.raw_json, llm_invoked=True,
            action_status="rejected", validation_error=llm_outcome.error,
        )
        trace_event(trace, "final", "not_understood", reason=llm_outcome.status)
        return CaptureResult(
            state="not_understood", turn_id=turn_id, session_id=session_id,
            transcript=transcript,
            reply="I couldn't understand that safely. Nothing was saved.",
            error_code=llm_outcome.status, path=path,
            timings_ms={"understand": llm_outcome.latency_ms},
        )

    action = proposal.actions[0]
    llm_ms = llm_outcome.latency_ms
    turn_id, proposed_ids = executor.record_turn(
        session_id=session_id, captured_at=captured_at, timezone_name=tz,
        transcript=transcript, proposal=proposal,
        llm_model=llm_outcome.model, llm_ms=llm_ms,
        prompt_version=PROMPT_VERSION,
        llm_raw_output=llm_outcome.raw_json,
        llm_invoked=True,
        action_status="resolved" if isinstance(action, CreateTransactionAction) else "rejected",
        validation_error=None if isinstance(action, CreateTransactionAction) else "intent is outside Gate C",
    )
    if not isinstance(action, CreateTransactionAction):
        if isinstance(action, UnsupportedAction) and "amount" in action.reason_hint.casefold():
            trace_event(trace, "normalization", "failed", reason=action.reason_hint)
            trace_event(trace, "merchant_resolution", "skipped", reason="unresolved_amount")
            trace_event(trace, "validation", "failed", reason=action.reason_hint)
            clarification = _clarification(action.reason_hint)
            reply = f"{clarification.question} Nothing was saved."
            executor.set_turn_reply(turn_id, reply)
            trace_event(trace, "final", "needs_clarification", reason=action.reason_hint)
            return CaptureResult(
                state="needs_clarification", turn_id=turn_id, session_id=session_id,
                transcript=transcript, reply=reply, clarification=clarification,
                path=path, timings_ms={"understand": llm_ms},
            )
        trace_event(trace, "normalization", "skipped", reason="unsupported_intent")
        trace_event(trace, "merchant_resolution", "skipped", reason="unsupported_intent")
        trace_event(trace, "validation", "failed", reason="unsupported_intent")
        reply = "That request isn't available in natural capture yet. Nothing was saved."
        executor.set_turn_reply(turn_id, reply)
        trace_event(trace, "final", "not_understood", reason="unsupported_intent")
        return CaptureResult(
            state="not_understood", turn_id=turn_id, session_id=session_id,
            transcript=transcript, reply=reply, error_code="unsupported_intent",
            path=path, timings_ms={"understand": llm_ms},
        )

    resolve_started = time.perf_counter()
    amount = None
    occurred = None
    try:
        amount = recover_amount(action.amount_expr, whole_bare=action.direction in {"income", "contribution"})
        occurred = resolve_date_expr(action.date_expr or "today", captured_at, tz)
        if amount.amount_minor is None or occurred is None or action.direction is None:
            resolved = None
        else:
            trace_event(trace, "normalization", "passed", amount_minor=amount.amount_minor,
                        amount_rung=amount.rung, local_date=occurred[1], direction=action.direction)
            resolved = resolve_create(action, captured_at=captured_at, tz=tz, database=database,
                                      amount=amount, occurred=occurred)
    except (ValueError, TypeError) as exc:
        resolved = None
        resolution_error = str(exc)
    else:
        resolution_error = "transaction fields could not be resolved safely"
    resolve_ms = round((time.perf_counter() - resolve_started) * 1000)
    if resolved is None:
        reason = (amount.reason if amount is not None and amount.amount_minor is None
                  else "invalid date expression" if occurred is None and amount is not None
                  else resolution_error)
        trace_event(trace, "normalization", "failed", reason=reason)
        trace_event(trace, "merchant_resolution", "skipped", reason="validation_failed")
        trace_event(trace, "validation", "failed", reason=reason)
        clarification = _clarification(reason, alternatives=amount.alternatives_minor if amount else ())
        reply = f"{clarification.question} Nothing was saved."
        executor.set_turn_reply(turn_id, reply)
        trace_event(trace, "final", "needs_clarification", reason=reason)
        return CaptureResult(
            state="needs_clarification", turn_id=turn_id, session_id=session_id,
            transcript=transcript, reply=reply, clarification=clarification,
            path=path, timings_ms={"understand": llm_ms, "resolve": resolve_ms},
        )

    trace_event(trace, "merchant_resolution", "passed",
                extracted=action.merchant_expr, canonical=resolved.draft.merchant,
                matched=resolved.draft.merchant_id is not None)
    trace_event(trace, "validation", "passed", direction=resolved.draft.type,
                amount_minor=resolved.draft.amount_minor, category=resolved.draft.category)
    execute_started = time.perf_counter()
    try:
        transaction_label = resolved.draft.merchant or resolved.draft.description
        canonical_reply = f"Saved — RM{resolved.draft.amount_minor / 100:.2f}" + (
            f", {transaction_label}" if transaction_label else ""
        ) + "."
        outcome = executor.create_transaction(
            resolved.draft, turn_id=turn_id, proposed_action_id=proposed_ids[0],
            merchant_alias_id=resolved.merchant_alias_id,
            request_id=request_id, request_fingerprint=request_fingerprint,
            capture_path=path, reply=canonical_reply,
        )
        if request_id is not None:
            executed = outcome.executed
            if outcome.duplicate:
                trace_event(trace, "final", "duplicate_ignored", transaction_id=executed.transaction.id)
                return CaptureResult(
                    state="duplicate_ignored", turn_id=outcome.turn_id,
                    session_id=outcome.session_id, transcript=outcome.transcript,
                    reply=outcome.reply, transaction=executed.transaction,
                    executed=[executed], undo_token=executed.undo_token, path=outcome.path,
                )
        else:
            executed = outcome
    except RequestIdConflictError:
        raise
    except Exception:
        trace_event(trace, "final", "execution_failed")
        reply = "I couldn't save that transaction. Nothing was committed."
        executor.set_turn_reply(turn_id, reply)
        return CaptureResult(
            state="not_understood", turn_id=turn_id, session_id=session_id,
            transcript=transcript, reply=reply, error_code="execution_failed", path=path,
            timings_ms={"understand": llm_ms, "resolve": resolve_ms},
        )
    execute_ms = round((time.perf_counter() - execute_started) * 1000)
    transaction = executed.transaction
    label = transaction.merchant or transaction.description
    reply = f"Saved — RM{transaction.amount:.2f}" + (f", {label}" if label else "") + "."
    if request_id is None:
        executor.set_turn_reply(turn_id, reply)
    trace_event(trace, "final", "committed", transaction_id=transaction.id,
                direction=transaction.type, amount_minor=transaction.amount_minor,
                merchant=transaction.merchant, category=transaction.category)
    return CaptureResult(
        state="committed", turn_id=turn_id, session_id=session_id,
        transcript=transcript, reply=reply, transaction=transaction,
        executed=[executed], undo_token=executed.undo_token, path=path,
        timings_ms={
            "understand": llm_ms, "resolve": resolve_ms, "execute": execute_ms,
        },
    )
