"""Cycle planning oracle for the native port (blueprint §3.3, decisions O1/O2).

Pure functions only. This is the reference the Swift engine must reproduce; the
PWA's calendar-month ``home.home_summary`` is left unchanged while it is in use.

- Cycle: a monthly payday anchor N (1-31). The cycle runs from day N to the day
  before day N next month; N past a month's end clamps to its last day.
- Salary is a recurring income rule. Planning income for a cycle is actual
  income plus expected rule occurrences in the cycle not yet materialised by a
  linked transaction, so nothing is counted twice.
- Left per day divides what is left by the days remaining, today included.
"""

from __future__ import annotations

import calendar
from collections.abc import Iterable, Mapping
from dataclasses import asdict, dataclass
from datetime import date, timedelta
from typing import Any

from noted.finance import summarize


@dataclass(frozen=True)
class Cycle:
    start: date
    end: date  # inclusive

    @property
    def days(self) -> int:
        return (self.end - self.start).days + 1


@dataclass(frozen=True)
class MonthlyRule:
    """A recurring monthly rule on day N (clamped to month end)."""

    id: str
    kind: str  # income | expense | contribution
    amount_minor: int
    day_of_month: int
    start: date
    end: date | None = None


def _anchor_date(year: int, month: int, day: int) -> date:
    return date(year, month, min(day, calendar.monthrange(year, month)[1]))


def _add_months(year: int, month: int, delta: int) -> tuple[int, int]:
    index = year * 12 + (month - 1) + delta
    return index // 12, index % 12 + 1


def cycle_containing(day: date, anchor_day: int) -> Cycle:
    if not 1 <= anchor_day <= 31:
        raise ValueError("payday anchor must be 1-31")
    start = _anchor_date(day.year, day.month, anchor_day)
    if day < start:
        year, month = _add_months(day.year, day.month, -1)
        start = _anchor_date(year, month, anchor_day)
    next_year, next_month = _add_months(start.year, start.month, 1)
    return Cycle(start, _anchor_date(next_year, next_month, anchor_day) - timedelta(days=1))


def monthly_occurrences(rule: MonthlyRule, start: date, end: date) -> list[date]:
    """Occurrence dates of ``rule`` within [start, end], inside the rule's own bounds."""
    occurrences = []
    year, month = start.year, start.month
    while date(year, month, 1) <= end:
        occurrence = _anchor_date(year, month, rule.day_of_month)
        if (start <= occurrence <= end and occurrence >= rule.start
                and (rule.end is None or occurrence <= rule.end)):
            occurrences.append(occurrence)
        year, month = _add_months(year, month, 1)
    return occurrences


def percentage_of(amount_minor: int, basis_points: int) -> int:
    # Nearest sen, exact half-sen rounded up (matches home._percentage_target).
    return (amount_minor * basis_points + 5_000) // 10_000


def whole_minor_per_day(amount_minor: int, days: int) -> int:
    if days <= 0:
        return 0
    return amount_minor // days if amount_minor >= 0 else -((-amount_minor) // days)


def _value(row: Mapping[str, Any] | Any, field: str) -> Any:
    if isinstance(row, Mapping):
        return row.get(field)
    return getattr(row, field, None)


def cycle_plan(rows: Iterable[Mapping[str, Any] | Any], *, today: date, anchor_day: int,
               rules: Iterable[MonthlyRule] = (), savings_mode: str = "fixed",
               savings_target_minor: int = 0, savings_basis_points: int = 0,
               fixed_commitments_minor: int = 0) -> dict[str, Any]:
    """The Home plan for the cycle containing ``today``.

    ``rows`` are confirmed, non-deleted transactions with ``type``,
    ``amount_minor``, ``local_date`` and optional ``recurring_rule_id`` /
    ``occurrence_date`` linking them to a rule occurrence.
    """
    cycle = cycle_containing(today, anchor_day)
    materialized_rows = [row for row in rows if _value(row, "deleted_at") is None]
    in_cycle = [
        row for row in materialized_rows
        if cycle.start.isoformat() <= _value(row, "local_date") <= today.isoformat()
    ]
    actual = summarize(in_cycle)
    linked = {
        (_value(row, "recurring_rule_id"), _value(row, "occurrence_date"))
        for row in materialized_rows if _value(row, "recurring_rule_id")
    }
    expected_income = 0
    expected_occurrences = []
    for rule in rules:
        if rule.kind != "income":
            continue
        for occurrence in monthly_occurrences(rule, cycle.start, cycle.end):
            if (rule.id, occurrence.isoformat()) not in linked:
                expected_income += rule.amount_minor
                expected_occurrences.append({"rule_id": rule.id, "date": occurrence.isoformat(),
                                             "amount_minor": rule.amount_minor})

    planning_income = actual.income + expected_income
    savings_target = (savings_target_minor if savings_mode == "fixed"
                      else percentage_of(planning_income, savings_basis_points))
    planned_spendable = planning_income - savings_target
    envelope = planned_spendable - fixed_commitments_minor
    left = envelope - actual.spending
    days_elapsed = (today - cycle.start).days + 1
    days_left = (cycle.end - today).days + 1
    return {
        "cycle": {
            "anchor_day": anchor_day,
            "start_date": cycle.start.isoformat(),
            "end_date": cycle.end.isoformat(),
            "as_of_date": today.isoformat(),
            "days_in_cycle": cycle.days,
            "days_elapsed": days_elapsed,
            "days_left_including_today": days_left,
        },
        "actual": {key: value for key, value in asdict(actual).items()},
        "expected_income_minor": expected_income,
        "expected_occurrences": expected_occurrences,
        "planning_income_minor": planning_income,
        "savings_target_minor": savings_target,
        "remaining_to_set_aside_minor": savings_target - actual.contributions,
        "planned_spendable_minor": planned_spendable,
        "discretionary_envelope_minor": envelope,
        "left_minor": left,
        "left_per_day_minor": whole_minor_per_day(left, days_left),
        "pace_marker_minor": whole_minor_per_day(envelope * days_elapsed, cycle.days),
        "spending_per_elapsed_day_minor": whole_minor_per_day(actual.spending, days_elapsed),
        "planned_daily_discretionary_minor": whole_minor_per_day(envelope, cycle.days),
    }
