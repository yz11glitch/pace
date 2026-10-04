from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, RootModel, model_validator

from noted.actions import (
    AnswerClarificationAction,
    CategorizeTransactionAction,
    Category,
    CreateTransactionAction,
    DeleteTransactionAction,
    QuerySpec,
    QueryTransactionsAction,
    TargetDescriptor,
    TeachMemoryAction,
    TransactionChanges,
    TurnProposal,
    UnsupportedAction,
    UpdateTransactionAction,
)
from noted.models import TransactionType


class CompactModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CompactTarget(CompactModel):
    reference: Literal["previous", "last_created", "descriptor", "ordinal", "none"]
    merchant_expr: str | None = None
    item_expr: str | None = None
    amount_expr: str | None = None
    date_expr: str | None = None
    ordinal: int | None = Field(default=None, ge=1)


class CompactChanges(CompactModel):
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


class CompactQuery(CompactModel):
    shape: Literal["sum", "count", "average", "max_transaction", "top_categories", "top_merchants", "list", "compare_periods", "breakdown"]
    period_expr: str | None = None
    compare_period_expr: str | None = None
    category_hint: Category | None = None
    merchant_expr: str | None = None
    item_expr: str | None = None
    direction: TransactionType | None = None
    limit: int | None = Field(default=None, ge=1, le=50)


class CompactCreate(CompactModel):
    intent: Literal["create_transaction"]
    amount_expr: str
    direction: TransactionType
    merchant_expr: str | None = None
    item_expr: str | None = None
    category_hint: Category | None = None
    date_expr: str | None = None
    note: str | None = None


class CompactUpdate(CompactModel):
    intent: Literal["update_transaction"]
    target: CompactTarget
    changes: CompactChanges


class CompactCategorize(CompactModel):
    intent: Literal["categorize_transaction"]
    target: CompactTarget
    category_hint: Category
    negated_category_hint: Category | None = None
    teach: bool = False


class CompactDelete(CompactModel):
    intent: Literal["delete_transaction"]
    target: CompactTarget
    reason_hint: Literal["duplicate", "mistake", "other"] | None = None


class CompactQueryAction(CompactModel):
    intent: Literal["query_transactions"]
    query: CompactQuery


class CompactTeach(CompactModel):
    intent: Literal["teach_memory"]
    kind: Literal["merchant", "item"]
    surface_expr: str
    canonical_expr: str | None = None
    category_hint: Category | None = None
    subcategory_hint: str | None = None
    scope: Literal["default", "context"] = "default"
    context_keyword_expr: str | None = None


class CompactAnswer(CompactModel):
    intent: Literal["answer_clarification"]
    choice_ordinal: int | None = Field(default=None, ge=1)
    answer_expr: str | None = None
    polarity: Literal["affirm", "deny", "neither"] = "neither"


class CompactUnsupported(CompactModel):
    intent: Literal["unsupported"]
    reason_hint: str = "unsupported request"


CompactAction = Annotated[
    CompactCreate | CompactUpdate | CompactCategorize | CompactDelete
    | CompactQueryAction | CompactTeach | CompactAnswer | CompactUnsupported,
    Field(discriminator="intent"),
]


class CompactProposal(RootModel[CompactAction]):
    pass


def expand_compact(raw_json: str, transcript: str) -> TurnProposal:
    compact = CompactProposal.model_validate_json(raw_json).root
    common = {"confidence": 1.0, "evidence": transcript}
    if isinstance(compact, CompactCreate):
        action = CreateTransactionAction(**compact.model_dump(), **common)
    elif isinstance(compact, CompactUpdate):
        data = compact.model_dump()
        action = UpdateTransactionAction(
            intent=compact.intent,
            target=TargetDescriptor(**data["target"]),
            changes=TransactionChanges(**data["changes"]),
            **common,
        )
    elif isinstance(compact, CompactCategorize):
        data = compact.model_dump()
        action = CategorizeTransactionAction(**{**data, "target": TargetDescriptor(**data["target"])}, **common)
    elif isinstance(compact, CompactDelete):
        data = compact.model_dump()
        action = DeleteTransactionAction(**{**data, "target": TargetDescriptor(**data["target"])}, **common)
    elif isinstance(compact, CompactQueryAction):
        data = compact.model_dump()
        action = QueryTransactionsAction(intent=compact.intent, query=QuerySpec(**data["query"]), **common)
    elif isinstance(compact, CompactTeach):
        action = TeachMemoryAction(**compact.model_dump(), **common)
    elif isinstance(compact, CompactAnswer):
        action = AnswerClarificationAction(**compact.model_dump(), **common)
    else:
        action = UnsupportedAction(**compact.model_dump(), **common)
    turn_kind = {
        "update_transaction": "correction",
        "categorize_transaction": "correction",
        "query_transactions": "question",
        "answer_clarification": "answer",
        "unsupported": "question" if transcript.rstrip().endswith("?") else "statement",
    }.get(action.intent, "statement")
    return TurnProposal(schema_version=1, turn_kind=turn_kind, actions=[action])
