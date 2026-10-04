"""Numeric dates follow Pace's financial locale (Malaysia): day first, always."""

from __future__ import annotations

from datetime import datetime

import pytest

from noted.dates import resolve_date_expr


CAPTURED = datetime.fromisoformat("2026-09-26T09:30:00+08:00")


@pytest.mark.parametrize(("expr", "local_date"), [
    ("15/9", "2026-09-15"),
    ("15/09", "2026-09-15"),
    ("15/09/2026", "2026-09-15"),
    ("15-09-2026", "2026-09-15"),
    ("15.09.2026", "2026-09-15"),
    ("15/9/26", "2026-09-15"),
    ("3/4", "2026-04-03"),          # 3 April, never March 4
    ("03/04/2026", "2026-04-03"),
    ("1/12/2025", "2025-12-01"),
    ("29/02/2028", "2028-02-29"),
])
def test_numeric_dates_are_day_first(expr, local_date):
    assert resolve_date_expr(expr, CAPTURED, "Asia/Kuala_Lumpur")[1] == local_date


@pytest.mark.parametrize("expr", ["13/13", "31/04/2026", "29/02/2026", "0/5", "9/15", "15/9/202", "1/2/3/4"])
def test_impossible_numeric_dates_fail_closed(expr):
    assert resolve_date_expr(expr, CAPTURED, "Asia/Kuala_Lumpur") is None


def test_numeric_date_keeps_capture_time_of_day_in_the_capture_zone():
    occurred, local_date = resolve_date_expr("3/4", CAPTURED, "Asia/Kuala_Lumpur")
    assert local_date == "2026-04-03"
    assert occurred.isoformat() == "2026-04-03T01:30:00+00:00"


@pytest.mark.parametrize("expr", ["today", "just now", "earlier"])
def test_same_day_expressions_keep_the_captured_instant_in_a_repeated_hour(expr):
    # 06:30Z on 2026-11-01 is the second 01:30 in New York (fall back).
    captured = datetime.fromisoformat("2026-11-01T06:30:00+00:00")
    occurred, local_date = resolve_date_expr(expr, captured, "America/New_York")
    assert occurred.isoformat() == "2026-11-01T06:30:00+00:00"
    assert local_date == "2026-11-01"
