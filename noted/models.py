from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, computed_field, field_validator, model_validator


TransactionType = Literal["expense", "income", "refund", "contribution"]


class TransactionCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: TransactionType
    amount_minor: int = Field(gt=0, le=100_000_000_00)
    currency: Literal["MYR"] = "MYR"
    merchant_id: str | None = None
    merchant: str | None = Field(default=None, max_length=200)
    description: str | None = Field(default=None, max_length=500)
    category: str | None = Field(default=None, min_length=1, max_length=100)
    subcategory: str | None = Field(default=None, max_length=100)
    occurred_at: datetime
    local_date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    raw_transcript: str = Field(min_length=1, max_length=5_000)

    @field_validator("occurred_at")
    @classmethod
    def require_aware_datetime(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("occurred_at must include a timezone")
        return value

    @model_validator(mode="after")
    def require_category_for_flow_class(self):
        if (self.type == "contribution") != (self.category is None):
            raise ValueError("category must be null exactly when type is contribution")
        return self


class Transaction(TransactionCreate):
    id: str
    created_at: datetime
    updated_at: datetime | None = None
    deleted_at: datetime | None = None
    status: Literal["confirmed", "needs_review"] = "confirmed"

    @computed_field(return_type=float)
    @property
    def amount(self) -> float:
        return self.amount_minor / 100


class ConfirmationRequired(BaseModel):
    status: Literal["confirmation_required"] = "confirmation_required"
    reason: str
    raw_transcript: str
    alternatives: list[float] = Field(default_factory=list)


class PaceProfileInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    income_amount_minor: int = Field(ge=0, le=100_000_000_00)
    income_frequency: Literal["monthly"] = "monthly"
    next_income_date: date
    fixed_commitments_minor: int = Field(ge=0, le=100_000_000_00)
    savings_target_minor: int = Field(ge=0, le=100_000_000_00)
    savings_mode: Literal["fixed", "percentage"] = "fixed"
    savings_percentage_basis_points: int = Field(default=0, ge=0, le=10_000)

    @model_validator(mode="after")
    def require_feasible_baseline(self):
        if self.savings_mode == "fixed" and self.fixed_commitments_minor + self.savings_target_minor > self.income_amount_minor:
            raise ValueError("fixed commitments plus savings target cannot exceed income")
        return self


class PaceProfile(PaceProfileInput):
    currency: Literal["MYR"] = "MYR"
    created_at: datetime
    updated_at: datetime
