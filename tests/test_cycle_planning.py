from __future__ import annotations

from datetime import date, datetime
from pathlib import Path

import pytest

from noted.db import Database
from noted.execute import ActionExecutor
from noted.home import home_summary
from noted.models import PaceProfileInput, TransactionCreate
from noted.planning import MonthlyRule, cycle_containing, cycle_plan, monthly_occurrences


@pytest.mark.parametrize(("today", "anchor", "start", "end"), [
    ("2026-09-26", 1, "2026-09-01", "2026-09-30"),
    ("2026-09-26", 25, "2026-09-25", "2026-10-24"),
    ("2026-09-24", 25, "2026-08-25", "2026-09-24"),
    ("2026-09-25", 25, "2026-09-25", "2026-10-24"),
    # Days 29-31 clamp to the month's last day.
    ("2026-02-28", 31, "2026-02-28", "2026-03-30"),
    ("2026-02-27", 31, "2026-01-31", "2026-02-27"),
    ("2028-02-29", 30, "2028-02-29", "2028-03-29"),
    ("2026-04-30", 31, "2026-04-30", "2026-05-30"),
    ("2026-05-31", 31, "2026-05-31", "2026-06-29"),
    ("2026-01-10", 15, "2025-12-15", "2026-01-14"),
    ("2026-12-31", 1, "2026-12-01", "2026-12-31"),
])
def test_payday_cycle_boundaries(today, anchor, start, end):
    cycle = cycle_containing(date.fromisoformat(today), anchor)
    assert (cycle.start.isoformat(), cycle.end.isoformat()) == (start, end)


def test_every_day_belongs_to_exactly_one_cycle():
    for anchor in (1, 15, 28, 29, 30, 31):
        day = date(2027, 1, 1)
        previous_end = None
        while day <= date(2028, 12, 31):
            cycle = cycle_containing(day, anchor)
            assert cycle.start <= day <= cycle.end
            if previous_end is not None and cycle.start != cycle_containing(previous_end, anchor).start:
                assert (cycle.start - previous_end).days == 1
            previous_end = day
            day = date.fromordinal(day.toordinal() + 1)


def test_invalid_anchor_is_rejected():
    for anchor in (0, 32):
        with pytest.raises(ValueError):
            cycle_containing(date(2026, 9, 1), anchor)


def test_monthly_occurrences_clamp_and_respect_rule_bounds():
    rule = MonthlyRule("r", "income", 100, 31, start=date(2026, 1, 1), end=date(2026, 4, 30))
    assert [d.isoformat() for d in monthly_occurrences(rule, date(2026, 1, 1), date(2026, 12, 31))] == [
        "2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"]
    late = MonthlyRule("r", "income", 100, 1, start=date(2026, 10, 1))
    assert monthly_occurrences(late, date(2026, 9, 1), date(2026, 9, 30)) == []


def row(flow, amount, day, **extra):
    return {"type": flow, "amount_minor": amount, "local_date": day,
            "category": None if flow == "contribution" else "Other", **extra}


SALARY = MonthlyRule("salary", "income", 350_000, 25, start=date(2026, 1, 1))


def test_expected_salary_counts_until_it_is_materialised_never_twice():
    today = date(2026, 9, 26)
    plan = cycle_plan([], today=today, anchor_day=25, rules=[SALARY], savings_target_minor=50_000)
    assert plan["expected_income_minor"] == 350_000
    assert plan["planning_income_minor"] == 350_000

    linked = [row("income", 350_000, "2026-09-25", recurring_rule_id="salary", occurrence_date="2026-09-25")]
    plan = cycle_plan(linked, today=today, anchor_day=25, rules=[SALARY], savings_target_minor=50_000)
    assert plan["expected_income_minor"] == 0
    assert plan["planning_income_minor"] == 350_000

    # An unlinked extra income adds to, not replaces, the expected salary.
    extra = [row("income", 80_000, "2026-09-26")]
    plan = cycle_plan(extra, today=today, anchor_day=25, rules=[SALARY], savings_target_minor=50_000)
    assert plan["planning_income_minor"] == 430_000


def test_deleted_linked_salary_is_expected_again():
    linked = [row("income", 350_000, "2026-09-25", recurring_rule_id="salary",
                  occurrence_date="2026-09-25", deleted_at="2026-09-26T00:00:00+00:00")]
    plan = cycle_plan(linked, today=date(2026, 9, 26), anchor_day=25, rules=[SALARY])
    assert plan["planning_income_minor"] == 350_000


def test_left_per_day_divides_by_days_remaining_including_today():
    rows = [row("expense", 100_000, "2026-09-02"), row("refund", 10_000, "2026-09-03"),
            row("contribution", 50_000, "2026-09-04"), row("expense", 5_000, "2026-09-27")]
    plan = cycle_plan(rows, today=date(2026, 9, 26), anchor_day=1,
                      rules=[MonthlyRule("s", "income", 400_000, 1, start=date(2026, 1, 1))],
                      savings_mode="percentage", savings_basis_points=2_000,
                      fixed_commitments_minor=35_000)
    assert plan["actual"]["spending"] == 90_000  # the future-dated expense is excluded
    assert plan["savings_target_minor"] == 80_000
    assert plan["discretionary_envelope_minor"] == 285_000
    assert plan["left_minor"] == 195_000
    assert plan["cycle"]["days_left_including_today"] == 5
    assert plan["left_per_day_minor"] == 39_000
    assert plan["remaining_to_set_aside_minor"] == 30_000
    assert plan["pace_marker_minor"] == 285_000 * 26 // 30


def test_negative_values_truncate_toward_zero():
    plan = cycle_plan([row("expense", 100_001, "2026-09-01")], today=date(2026, 9, 28), anchor_day=1)
    assert plan["left_minor"] == -100_001
    assert plan["left_per_day_minor"] == -33_333


def test_calendar_month_with_unlogged_salary_matches_the_pwa_home_summary(tmp_path: Path):
    """Where the two models agree (N = 1, salary not logged), the numbers must be equal."""
    database = Database(tmp_path / "home.db")
    database.bootstrap()
    executor = ActionExecutor(database)
    executor.set_pace_profile(PaceProfileInput(
        income_amount_minor=350_000, next_income_date="2026-09-28",
        fixed_commitments_minor=35_000, savings_target_minor=0,
        savings_mode="percentage", savings_percentage_basis_points=2_025,
    ))
    rows = []
    for flow, amount, day in [("income", 80_000, "2026-09-10"), ("expense", 12_345, "2026-09-11"),
                              ("refund", 1_000, "2026-09-12"), ("contribution", 20_000, "2026-09-13")]:
        executor.create_transaction(TransactionCreate(
            type=flow, amount_minor=amount,
            category=None if flow == "contribution" else "Income" if flow == "income" else "Other",
            occurred_at=datetime.fromisoformat(f"{day}T12:00:00+08:00"), local_date=day,
            raw_transcript="cross-check",
        ))
        rows.append(row(flow, amount, day))
    now = datetime.fromisoformat("2026-09-17T12:00:00+08:00")
    legacy = home_summary(database, now=now, timezone_name="Asia/Kuala_Lumpur")["plan"]
    plan = cycle_plan(rows, today=date(2026, 9, 17), anchor_day=1,
                      rules=[MonthlyRule("s", "income", 350_000, 28, start=date(2026, 1, 1))],
                      savings_mode="percentage", savings_basis_points=2_025,
                      fixed_commitments_minor=35_000)
    for key in ("planning_income_minor", "savings_target_minor", "remaining_to_set_aside_minor",
                "planned_spendable_minor", "discretionary_envelope_minor",
                "planned_daily_discretionary_minor"):
        assert plan[key] == legacy[key], key
    assert plan["left_minor"] == legacy["remaining_discretionary_minor"]
