from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from noted.normalize import canonical_text, recover_amount
from noted.db import Database
from noted.merchants import MerchantMatch, resolve_merchant
from noted.models import TransactionCreate


@dataclass(frozen=True)
class ParseFailure:
    reason: str
    alternatives_minor: tuple[int, ...] = ()


@dataclass(frozen=True)
class ParseResult:
    transaction: TransactionCreate | None
    failure: ParseFailure | None
    merchant_match: MerchantMatch | None = None


EXPENSE_CUES = re.compile(r"\b(spent|spend|paid|pay|bought|buy|charged|cost|topped?\s+up|purchase|order)\b")
INCOME_CUES = re.compile(
    r"\b(?:got\s+paid|salary|income|received|earned|payday|"
    r"got\b.*\b(?:commission|bonus)|made\b.*\bfrom\s+freelance)\b"
)
REFUND_CUES = re.compile(r"\b(refund|refunded|reimbursement|reimbursed|cashback|got\b.*\bback\s+from)\b")
CONTRIBUTION_CUES = re.compile(
    r"\b(?:set\s+aside|put\b.*\b(?:into|towards?)\s+(?:savings?|investments?)|"
    r"saved\s+\d+\s+(?:this\s+month|for\s+savings?))\b"
)
DESCRIPTION_TERMS = (
    "flat white", "roti canai", "groceries", "coffee", "lunch", "meal", "petrol",
    "fuel", "ride", "hotel", "subscription", "shopping",
)


def _has_multiple_amounts(text: str) -> bool:
    normalized = canonical_text(text)
    if len(re.findall(r"\bringgit\b", normalized)) > 1:
        return True
    if len(re.findall(r"(?:\brm\s*|\$\s*)\d", normalized)) > 1:
        return True
    return len(re.findall(r"\b\d+\.\d{1,2}\b", normalized)) > 1


def _captured_local(captured_at: datetime, timezone_name: str) -> datetime:
    if captured_at.tzinfo is None or captured_at.utcoffset() is None:
        raise ValueError("captured_at must include a timezone")
    try:
        return captured_at.astimezone(ZoneInfo(timezone_name))
    except ZoneInfoNotFoundError as exc:
        raise ValueError(f"unknown timezone: {timezone_name}") from exc


def _occurred_at(text: str, captured_at: datetime, timezone_name: str) -> tuple[datetime, str]:
    local = _captured_local(captured_at, timezone_name)
    normalized = canonical_text(text)
    days = 2 if re.search(r"\btwo days ago\b", normalized) else 1 if re.search(r"\byesterday\b", normalized) else 0
    occurred_local = local - timedelta(days=days)
    return occurred_local.astimezone(timezone.utc), occurred_local.date().isoformat()


def _description(text: str) -> str | None:
    normalized = canonical_text(text)
    return next((term for term in DESCRIPTION_TERMS if re.search(rf"\b{re.escape(term)}\b", normalized)), None)


def _fallback_category(text: str, transaction_type: str) -> tuple[str, str | None]:
    normalized = canonical_text(text)
    if transaction_type == "income":
        return "Income", None
    if re.search(r"\b(groceries|grocery)\b", normalized):
        return "Groceries", None
    if re.search(r"\b(coffee|flat white|food|meal|lunch|roti canai)\b", normalized):
        return "Food & Drink", "Coffee" if "coffee" in normalized else None
    if re.search(r"\b(ride|car|transport|petrol|fuel)\b", normalized):
        return "Transport", "Fuel" if re.search(r"\b(petrol|fuel)\b", normalized) else None
    if re.search(r"\b(shopping|shop|order)\b", normalized):
        return "Shopping", None
    return "Other", None


def clear_flow(text: str) -> str | None:
    normalized = canonical_text(text)
    if REFUND_CUES.search(normalized):
        return "refund"
    if CONTRIBUTION_CUES.search(normalized):
        return "contribution"
    if INCOME_CUES.search(normalized):
        return "income"
    if EXPENSE_CUES.search(normalized):
        return "expense"
    return None


def parse_transaction(
    transcript: str,
    *,
    captured_at: datetime,
    timezone_name: str,
    database: Database,
) -> ParseResult:
    transcript = transcript.strip()
    if not transcript:
        return ParseResult(None, ParseFailure("ASR returned an empty transcript"))
    if _has_multiple_amounts(transcript):
        return ParseResult(None, ParseFailure("multiple monetary amounts require confirmation"))

    flow = clear_flow(transcript)
    amount = recover_amount(transcript, whole_bare=flow in {"income", "contribution"})
    if amount.amount_minor is None:
        reason = amount.reason or "amount could not be recovered confidently"
        return ParseResult(None, ParseFailure(reason, amount.alternatives_minor))

    normalized = canonical_text(transcript)
    merchant = resolve_merchant(transcript, database)
    if flow:
        transaction_type = flow
    elif merchant or _description(transcript):
        transaction_type = "expense"
    else:
        return ParseResult(None, ParseFailure("transaction type could not be determined confidently"), merchant)

    occurred_at, local_date = _occurred_at(transcript, captured_at, timezone_name)
    category, subcategory = (
        (None, None) if transaction_type == "contribution" else
        (merchant.category, merchant.subcategory) if merchant else
        _fallback_category(transcript, transaction_type)
    )
    transaction = TransactionCreate(
        type=transaction_type,
        amount_minor=amount.amount_minor,
        currency="MYR",
        merchant_id=merchant.merchant_id if merchant else None,
        merchant=merchant.display_name if merchant else None,
        description=_description(transcript),
        category=category,
        subcategory=subcategory,
        occurred_at=occurred_at,
        local_date=local_date,
        raw_transcript=transcript,
    )
    return ParseResult(transaction, None, merchant)
