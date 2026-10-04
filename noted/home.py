from __future__ import annotations

import calendar
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from noted.db import Database
from noted.finance import summarize


def _percentage_target(amount_minor: int, basis_points: int) -> int:
    # Round to the nearest sen, with exact half-sen values rounded up.
    return (amount_minor * basis_points + 5_000) // 10_000


def _whole_minor_per_day(amount_minor: int, days: int) -> int:
    if days <= 0:
        return 0
    # Truncate toward zero and keep authoritative money in whole sen.
    return amount_minor // days if amount_minor >= 0 else -((-amount_minor) // days)


def home_summary(database: Database, *, now: datetime, timezone_name: str) -> dict:
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("clock must include a timezone")
    try:
        local_now = now.astimezone(ZoneInfo(timezone_name))
    except ZoneInfoNotFoundError as exc:
        raise ValueError("invalid IANA timezone") from exc

    today = local_now.date()
    days_in_month = calendar.monthrange(today.year, today.month)[1]
    period_start = today.replace(day=1)
    period_end = today.replace(day=days_in_month)
    rows = database.transactions_between(period_start.isoformat(), today.isoformat())
    actual = summarize(rows)
    profile = database.pace_profile()

    profile_payload = profile.model_dump(mode="json") if profile else None
    plan = None
    if profile is not None:
        planning_income = profile.income_amount_minor + actual.income
        savings_target = (
            profile.savings_target_minor if profile.savings_mode == "fixed"
            else _percentage_target(planning_income, profile.savings_percentage_basis_points)
        )
        planned_spendable = planning_income - savings_target
        discretionary_envelope = planned_spendable - profile.fixed_commitments_minor
        plan = {
            "base_income_minor": profile.income_amount_minor,
            "additional_income_minor": actual.income,
            "planning_income_minor": planning_income,
            "savings_target_minor": savings_target,
            "remaining_to_set_aside_minor": savings_target - actual.contributions,
            "remaining_discretionary_minor": discretionary_envelope - actual.spending,
            "planned_spendable_minor": planned_spendable,
            "discretionary_envelope_minor": discretionary_envelope,
            "planned_daily_discretionary_minor": _whole_minor_per_day(
                discretionary_envelope, days_in_month
            ),
        }

    return {
        "availability": {
            "transactions": True,
            "profile": profile is not None,
            "plan": profile is not None,
            "missing_profile_fields": [] if profile else [
                "income_amount_minor", "income_frequency", "next_income_date",
                "fixed_commitments_minor", "savings_target_minor",
            ],
        },
        "period": {
            "kind": "calendar_month",
            "timezone": timezone_name,
            "start_date": period_start.isoformat(),
            "end_date": period_end.isoformat(),
            "as_of_date": today.isoformat(),
            "days_in_period": days_in_month,
            "days_elapsed": today.day,
            "days_remaining": days_in_month - today.day,
        },
        "actual": {
            "income_minor": actual.income,
            "spending_minor": actual.spending,
            "contributions_minor": actual.contributions,
            "retained_minor": actual.retained,
            "unallocated_surplus_minor": actual.unallocated_surplus,
            "spendable_minor": actual.spendable,
            "savings_rate": actual.savings_rate,
            "contribution_rate": actual.contribution_rate,
        },
        "pace": {
            "spending_per_elapsed_day_minor": _whole_minor_per_day(actual.spending, today.day),
            "basis_spending_minor": actual.spending,
            "basis_days_elapsed": today.day,
        },
        "profile": profile_payload,
        "plan": plan,
        "projection": None,
    }
