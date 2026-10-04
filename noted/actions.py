from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from noted.models import Transaction, TransactionCreate, TransactionType


Category = Literal[
    "Food & Drink", "Groceries", "Transport", "Shopping", "Bills & Utilities",
    "Health", "Entertainment", "Education", "Services", "Travel",
    "Gifts & Donations", "Income", "Other",
]
QueryShape = Literal[
    "sum", "count", "average", "max_transaction", "top_categories",
    "top_merchants", "list", "compare_periods", "breakdown",
]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class TargetDescriptor(StrictModel):
    reference: Literal["previous", "last_created", "descriptor", "ordinal", "none"] = "none"
    merchant_expr: str | None = None
    item_expr: str | None = None
    amount_expr: str | None = None
    date_expr: str | None = None
    ordinal: int | None = Field(default=None, ge=1)


class TransactionChanges(StrictModel):
    amount_expr: str | None = None
    direction: TransactionType | None = None
    merchant_expr: str | None = None
    item_expr: str | None = None
    category_hint: Category | None = None
    date_expr: str | None = None
    note: str | None = None

    @model_validator(mode="after")
    def require_change(self):
        if not any(value is not None for value in self.model_dump().values()):
            raise ValueError("at least one change is required")
        return self


class ProposedBase(StrictModel):
    confidence: float = Field(default=1.0, ge=0, le=1)
    evidence: str


class CreateTransactionAction(ProposedBase):
    intent: Literal["create_transaction"]
    amount_expr: str
    direction: TransactionType | None = None
    merchant_expr: str | None = None
    item_expr: str | None = None
    category_hint: Category | None = None
    date_expr: str | None = None
    note: str | None = None


class UpdateTransactionAction(ProposedBase):
    intent: Literal["update_transaction"]
    target: TargetDescriptor
    changes: TransactionChanges


class CategorizeTransactionAction(ProposedBase):
    intent: Literal["categorize_transaction"]
    target: TargetDescriptor
    category_hint: Category
    negated_category_hint: Category | None = None
    teach: bool = False


class DeleteTransactionAction(ProposedBase):
    intent: Literal["delete_transaction"]
    target: TargetDescriptor
    reason_hint: Literal["duplicate", "mistake", "other"] | None = None


class QuerySpec(StrictModel):
    shape: QueryShape
    period_expr: str | None = None
    compare_period_expr: str | None = None
    category_hint: Category | None = None
    merchant_expr: str | None = None
    item_expr: str | None = None
    direction: TransactionType | None = None
    limit: int | None = Field(default=None, ge=1, le=50)


class QueryTransactionsAction(ProposedBase):
    intent: Literal["query_transactions"]
    query: QuerySpec


class TeachMemoryAction(ProposedBase):
    intent: Literal["teach_memory"]
    kind: Literal["merchant", "item"]
    surface_expr: str
    canonical_expr: str | None = None
    category_hint: Category | None = None
    subcategory_hint: str | None = None
    scope: Literal["default", "context"] = "default"
    context_keyword_expr: str | None = None


class AnswerClarificationAction(ProposedBase):
    intent: Literal["answer_clarification"]
    choice_ordinal: int | None = Field(default=None, ge=1)
    answer_expr: str | None = None
    polarity: Literal["affirm", "deny", "neither"] = "neither"


class UnsupportedAction(ProposedBase):
    intent: Literal["unsupported"]
    reason_hint: str


ProposedAction = Annotated[
    CreateTransactionAction | UpdateTransactionAction | CategorizeTransactionAction
    | DeleteTransactionAction | QueryTransactionsAction | TeachMemoryAction
    | AnswerClarificationAction | UnsupportedAction,
    Field(discriminator="intent"),
]


class TurnProposal(StrictModel):
    schema_version: Literal[1] = 1
    turn_kind: Literal["statement", "question", "correction", "answer", "mixed"]
    actions: list[ProposedAction] = Field(min_length=1, max_length=4)


class ResolvedAction(StrictModel):
    action_id: str
    kind: str
    payload: dict[str, Any]
    target_id: str | None = None
    risk: Literal["auto", "confirm"] = "auto"
    resolution: dict[str, Any] = Field(default_factory=dict)


class ClarificationChoice(StrictModel):
    ordinal: int = Field(ge=1)
    ref: str
    label: str


class ClarificationRequest(StrictModel):
    question_id: str
    kind: Literal["ambiguous_amount", "ambiguous_target", "missing_slot", "unknown_merchant", "bulk_destructive"]
    prompt: str
    choices: list[ClarificationChoice] = Field(default_factory=list)
    held_action_id: str | None = None
    expires_at: datetime


class ExecutedAction(StrictModel):
    action_id: str
    kind: str
    transaction: Transaction
    undo_token: str
    undone: bool = False


class Timings(StrictModel):
    asr: int = 0
    understand: int = 0
    resolve: int = 0
    execute: int = 0


class ShadowUnderstanding(StrictModel):
    status: Literal["validated", "clarification_needed", "understanding_failed"]
    proposal: TurnProposal | None = None
    model: str | None = None
    prompt_version: str
    latency_ms: int = Field(ge=0)
    error: str | None = None


class TurnResult(StrictModel):
    turn_id: str
    session_id: str
    transcript: str
    reply: str
    executed: list[ExecutedAction] = Field(default_factory=list)
    pending: ClarificationRequest | None = None
    query_result: dict[str, Any] | None = None
    timings_ms: Timings = Field(default_factory=Timings)
    shadow: ShadowUnderstanding | None = None


class CaptureClarification(StrictModel):
    reason: str
    question: str
    alternatives_minor: list[int] = Field(default_factory=list)


class CaptureResult(StrictModel):
    state: Literal[
        "processing", "committed", "needs_clarification", "not_understood",
        "duplicate_ignored",
    ]
    request_id: str | None = None
    turn_id: str | None = None
    session_id: str
    transcript: str
    reply: str
    transaction: Transaction | None = None
    executed: list[ExecutedAction] = Field(default_factory=list)
    undo_token: str | None = None
    clarification: CaptureClarification | None = None
    error_code: str | None = None
    path: Literal["deterministic_fast_path", "local_understanding"] | None = None
    timings_ms: Timings = Field(default_factory=Timings)


class TransactionPatch(StrictModel):
    type: TransactionType | None = None
    amount_minor: int | None = Field(default=None, gt=0, le=100_000_000_00)
    merchant_id: str | None = None
    merchant: str | None = Field(default=None, max_length=200)
    description: str | None = Field(default=None, max_length=500)
    category: str | None = Field(default=None, min_length=1, max_length=100)
    subcategory: str | None = Field(default=None, max_length=100)
    occurred_at: datetime | None = None
    local_date: str | None = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    raw_transcript: str | None = Field(default=None, min_length=1, max_length=5_000)
    status: Literal["confirmed", "needs_review"] | None = None

    @field_validator("occurred_at")
    @classmethod
    def require_aware_datetime(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("occurred_at must include a timezone")
        return value


class DeterministicResolution(StrictModel):
    draft: TransactionCreate
    amount_rung: int | None = None
    merchant_alias_id: int | None = None
