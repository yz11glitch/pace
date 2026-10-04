from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Any


Row = Mapping[str, Any] | Any


def _value(row: Row, field: str) -> Any:
    if isinstance(row, Mapping):
        return row[field]
    try:
        return getattr(row, field)
    except AttributeError:
        return row[field]


def _optional_value(row: Row, field: str) -> Any:
    try:
        return _value(row, field)
    except (AttributeError, IndexError, KeyError, TypeError):
        return None


def _active(rows: Iterable[Row]) -> list[Row]:
    return [
        row for row in rows
        if _optional_value(row, "deleted_at") is None
    ]


def income(rows: Iterable[Row]) -> int:
    return sum(_value(row, "amount_minor") for row in _active(rows) if _value(row, "type") == "income")


def spending(rows: Iterable[Row]) -> int:
    active = _active(rows)
    expenses = sum(_value(row, "amount_minor") for row in active if _value(row, "type") == "expense")
    refunds = sum(_value(row, "amount_minor") for row in active if _value(row, "type") == "refund")
    return expenses - refunds


def contributions(rows: Iterable[Row]) -> int:
    return sum(_value(row, "amount_minor") for row in _active(rows) if _value(row, "type") == "contribution")


def retained(rows: Iterable[Row]) -> int:
    materialized = list(rows)
    return income(materialized) - spending(materialized)


def unallocated_surplus(rows: Iterable[Row]) -> int:
    materialized = list(rows)
    return retained(materialized) - contributions(materialized)


def spendable(rows: Iterable[Row]) -> int:
    materialized = list(rows)
    return income(materialized) - contributions(materialized)


def savings_rate(rows: Iterable[Row]) -> float | None:
    materialized = list(rows)
    income_total = income(materialized)
    return retained(materialized) / income_total if income_total > 0 else None


def contribution_rate(rows: Iterable[Row]) -> float | None:
    materialized = list(rows)
    income_total = income(materialized)
    return contributions(materialized) / income_total if income_total > 0 else None


@dataclass(frozen=True)
class FinancialSummary:
    income: int
    spending: int
    contributions: int
    retained: int
    unallocated_surplus: int
    spendable: int
    savings_rate: float | None
    contribution_rate: float | None


def summarize(rows: Iterable[Row]) -> FinancialSummary:
    materialized = list(rows)
    income_total = income(materialized)
    spending_total = spending(materialized)
    contribution_total = contributions(materialized)
    retained_total = retained(materialized)
    return FinancialSummary(
        income=income_total,
        spending=spending_total,
        contributions=contribution_total,
        retained=retained_total,
        unallocated_surplus=unallocated_surplus(materialized),
        spendable=spendable(materialized),
        savings_rate=savings_rate(materialized),
        contribution_rate=contribution_rate(materialized),
    )


def category_totals(rows: Iterable[Row]) -> dict[str, int]:
    totals: defaultdict[str, int] = defaultdict(int)
    for row in _active(rows):
        flow_class = _value(row, "type")
        if flow_class not in {"expense", "refund"}:
            continue
        category = _value(row, "category")
        totals[category] += _value(row, "amount_minor") * (1 if flow_class == "expense" else -1)
    return dict(totals)


def merchant_spending_totals(rows: Iterable[Row]) -> dict[str, int]:
    totals: defaultdict[str, int] = defaultdict(int)
    for row in _active(rows):
        flow_class = _value(row, "type")
        merchant = _value(row, "merchant")
        if flow_class not in {"expense", "refund"} or merchant is None:
            continue
        totals[merchant] += _value(row, "amount_minor") * (1 if flow_class == "expense" else -1)
    return dict(totals)
