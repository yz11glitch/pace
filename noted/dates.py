from __future__ import annotations

import calendar
import re
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from noted.normalize import canonical_text


MONTHS = {name.casefold(): number for number, name in enumerate(calendar.month_name) if name}
MONTHS.update({name.casefold(): number for number, name in enumerate(calendar.month_abbr) if name})
WEEKDAYS = {name.casefold(): number for number, name in enumerate(calendar.day_name)}


def _local(captured_at: datetime, tz: str) -> datetime:
    if captured_at.tzinfo is None or captured_at.utcoffset() is None:
        raise ValueError("captured_at must include a timezone")
    try:
        return captured_at.astimezone(ZoneInfo(tz))
    except ZoneInfoNotFoundError as exc:
        raise ValueError(f"unknown timezone: {tz}") from exc


def _month_bounds(year: int, month: int) -> tuple[date, date]:
    return date(year, month, 1), date(year, month, calendar.monthrange(year, month)[1])


def resolve_date_expr(expr: str, captured_at: datetime, tz: str) -> tuple[datetime, str] | None:
    local = _local(captured_at, tz)
    value = canonical_text(expr).strip(" .,!?")
    offsets = {"just now": 0, "earlier": 0, "today": 0, "yesterday": 1, "two days ago": 2}
    if value in offsets:
        # Same-day expressions keep the captured instant; wall-clock arithmetic
        # would drop the fold of a repeated DST hour and move it an hour earlier.
        occurred = local - timedelta(days=offsets[value]) if offsets[value] else local
    else:
        weekday = re.fullmatch(r"last\s+(" + "|".join(WEEKDAYS) + r")", value)
        if weekday:
            days_back = (local.weekday() - WEEKDAYS[weekday.group(1)]) % 7 or 7
            occurred = local - timedelta(days=days_back)
        elif numeric := re.fullmatch(r"(\d{1,2})([/.-])(\d{1,2})(?:\2(\d{2}|\d{4}))?", expr.strip(" ,!?")):
            # Pace's financial locale is Malaysia: numeric dates are day first,
            # whatever the device region.
            year = int(numeric.group(4)) if numeric.group(4) else local.year
            if numeric.group(4) and len(numeric.group(4)) == 2:
                year += 2000
            try:
                target = date(year, int(numeric.group(3)), int(numeric.group(1)))
            except ValueError:
                return None
            occurred = datetime.combine(target, local.timetz())
        else:
            explicit = re.fullmatch(r"(?:(\d{1,2})\s+)?(" + "|".join(MONTHS) + r")(?:\s+(\d{4}))?", value)
            if not explicit or explicit.group(1) is None:
                return None
            day = int(explicit.group(1))
            year = int(explicit.group(3) or local.year)
            try:
                target = date(year, MONTHS[explicit.group(2)], day)
            except ValueError:
                return None
            occurred = datetime.combine(target, local.timetz())
    return occurred.astimezone(timezone.utc), occurred.date().isoformat()


def resolve_period_expr(expr: str, captured_at: datetime, tz: str) -> tuple[date, date] | None:
    today = _local(captured_at, tz).date()
    value = canonical_text(expr).strip(" .,!?")
    if value == "today":
        return today, today
    if value == "yesterday":
        day = today - timedelta(days=1)
        return day, day
    if value == "this week":
        return today - timedelta(days=today.weekday()), today
    if value == "last week":
        end = today - timedelta(days=today.weekday() + 1)
        return end - timedelta(days=6), end
    if value == "this month":
        return date(today.year, today.month, 1), today
    if value == "last month":
        previous_end = date(today.year, today.month, 1) - timedelta(days=1)
        return _month_bounds(previous_end.year, previous_end.month)
    if value == "this year":
        return date(today.year, 1, 1), today
    last_days = re.fullmatch(r"last\s+(\d+)\s+days", value)
    if last_days:
        count = int(last_days.group(1))
        return (today - timedelta(days=count - 1), today) if count > 0 else None
    month = re.fullmatch(r"(" + "|".join(MONTHS) + r")(?:\s+(\d{4}))?", value)
    if month:
        year = int(month.group(2) or today.year)
        start, end = _month_bounds(year, MONTHS[month.group(1)])
        return start, min(end, today) if start <= today <= end else end
    return None
