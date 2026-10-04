"""Export golden fixtures from the Python oracle for the native Swift parity suite.

Usage:  .venv/bin/python scripts/export_golden_fixtures.py [output_dir]

Every file is deterministic (fixed seeds, sorted keys), so a re-export after an
oracle change shows up as a reviewable diff. ``tests/test_golden_fixtures.py``
fails when the committed fixtures drift from the oracle. The Swift engine must
reproduce every record exactly (blueprint §3.11, Phase 1 acceptance).

UI fixtures (keypad, money formatting) come from ``public/ui-core.js`` via
``scripts/export_ui_fixtures.mjs``.
"""

from __future__ import annotations

import json
import random
import sys
import tempfile
from dataclasses import asdict
from datetime import date, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from noted.dates import resolve_date_expr, resolve_period_expr  # noqa: E402
from noted.db import Database  # noqa: E402
from noted.execute import ActionExecutor, UndoConflictError, UndoNotSupportedError  # noqa: E402
from noted.finance import category_totals, merchant_spending_totals, summarize  # noqa: E402
from noted.merchants import merchant_key, resolve_merchant_alias  # noqa: E402
from noted.models import TransactionCreate  # noqa: E402
from noted.normalize import canonical_text, recover_amount  # noqa: E402
from noted.planning import MonthlyRule, cycle_containing, cycle_plan, monthly_occurrences  # noqa: E402

DEFAULT_OUTPUT = ROOT / "fixtures" / "golden"
CATEGORIES = ["Food & Drink", "Groceries", "Transport", "Shopping", "Bills & Utilities", "Health",
              "Entertainment", "Education", "Services", "Travel", "Gifts & Donations", "Income", "Other"]
FLOWS = ["expense", "income", "refund", "contribution"]


def _jsonl(path: Path, records: list[dict]) -> None:
    path.write_text("".join(json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n" for record in records),
                    encoding="utf-8")


def _read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


# --- amounts -------------------------------------------------------------------

AMOUNT_EDGE_CASES = [
    # bench/asr/tests/test_normalize.py required rules
    "one hundred and twenty", "sixteen fifty", "twelve ninety", "seventy-eight forty",
    "sixteen point five zero", "twenty-three ringgit", "20 ringgit", "23 ringgit", "120 ringgit",
    "3500 ringgit", "120 ringgit 50 sen", "sixteen ringgit fifty sen", "RM20", "RM240", "RM3500",
    "RM2.40", "RM12.90", "RM16.50", "RM 16.50", "rm16.50", "three thousand five hundred", "3,500",
    "16 50", "16,50", "sixteen fifty no wait eighteen fifty", "Spent RM1650 at a new stall",
    # minor units (Phase 1 oracle fix)
    "fifty sen", "seventy five sen", "seventy-five sen", "five sen", "50 sen", "5 sen",
    "paid 90 sen for parking", "¢50", "50¢", "50 cents", "fifty cents", "one cent",
    "16 ringgit ¢50", "16 ringgit 50¢", "16 ringgit fifty sen", "16 ringgit and fifty sen",
    "16 ringgit 50 cents", "RM16 50 sen", "RM16 ¢50", "rm 16 and 5 sen", "150 sen",
    "one hundred sen", "RM16 150 sen", "twenty ringgit and fifty sen", "20 ringgit and 50 sen",
    "sixteen fifty sen", "sixteen ringgit one hundred sen",
    # Apple/ASR renderings and other surface forms
    "Yesterday I paid $67.90 for groceries.", "$18", "1650", "Spent 1650 at a new stall", "16.5",
    "RM1,250.50", "1,250", "12,345,678", "RM 3,500", "0.50", "RM0.50", "RM0", "0", "00", "007",
    "oh and I spent 30", "20 or 30", "twenty or thirty ringgit", "20 or so", "RM20 versus RM30",
    "Ｒｍ１８", "ＲＭ１８．５０", "RM18.555", "18.", ".50", "two thousand and twelve",
    "a hundred", "hundred", "thousand", "zero", "one thousand two hundred thirty four",
    "ninety nine point nine nine", "twelve point five", "twelve point", "point five",
    "nineteen ninety", "twenty twenty six", "eleven eleven", "forty-five",
    "I spent RM 8 on teh tarik and 12 on roti", "no amount here", "", "   ",
    "Shell patrol was down to 75 ringgit", "Dinner was 1480", "Lunch was 15.",
    "Grab right what's the 18 ringgit?", "Got a refund of 28.50 today.",
]

AMOUNT_PRIOR_CASES = [
    ("Spent 1650 at McDonalds", {"merchants": [{
        "name": "McDonald's", "aliases": ["mcdonalds"], "amount_count": 20,
        "amount_min_minor": 600, "amount_max_minor": 4500, "amount_median_minor": 1800}]}),
    ("Spent 1650 at a new stall", {"merchants": []}),
    ("Spent RM1650 at a new stall", {"merchants": []}),
    ("Spent 1650 somewhere new", {"merchants": [], "global": {"amount_count": 100, "amount_p99_minor": 100_000}}),
    ("Spent 1650 on coffee", {"merchants": [], "global": {"amount_count": 0, "amount_p99_minor": None},
                              "categories": [{"name": "food_drink", "keywords": ["coffee"], "amount_max_minor": 20_000}]}),
    ("Spent 4500 at McDonalds", {"merchants": [{
        "name": "McDonald's", "aliases": ["mcdonalds"], "amount_count": 20,
        "amount_min_minor": 600, "amount_max_minor": 500000, "amount_median_minor": 1800}]}),
    ("Spent 1650 at McDonalds", {"merchants": [{
        "name": "McDonald's", "aliases": ["mcdonalds"], "amount_count": 4,
        "amount_min_minor": 600, "amount_max_minor": 4500, "amount_median_minor": 1800}]}),
]


def amount_records() -> list[dict]:
    texts: list[str] = list(AMOUNT_EDGE_CASES)
    for row in _read_jsonl(ROOT / "bench" / "understanding" / "corpus.jsonl"):
        texts.append(row["text"])
        amount_expr = (row.get("expected", {}).get("action") or {}).get("amount_expr")
        if amount_expr:
            texts.append(amount_expr)
    for row in _read_jsonl(ROOT / "tests" / "data" / "capture_utterances.jsonl"):
        texts.append(row["text"])
        if row.get("proposal", {}).get("amount_expr"):
            texts.append(row["proposal"]["amount_expr"])
    for name in ("capture_blind", "capture_final_blind", "capture_heldout", "capture_regression"):
        texts.extend(row["text"] for row in _read_jsonl(ROOT / "tests" / "fixtures" / f"{name}.jsonl"))
    texts.extend(row["spoken"] for row in _read_jsonl(ROOT / "bench" / "asr" / "corpus.jsonl"))

    records, seen = [], set()
    for text in (text for text in texts if isinstance(text, str)):
        for whole_bare in (False, True):
            key = (text, None, whole_bare)
            if key in seen:
                continue
            seen.add(key)
            records.append({"text": text, "priors": None, "whole_bare": whole_bare,
                            "expect": recover_amount(text, None, whole_bare=whole_bare).to_dict()})
    for text, priors in AMOUNT_PRIOR_CASES:
        records.append({"text": text, "priors": priors, "whole_bare": False,
                        "expect": recover_amount(text, priors).to_dict()})
    for index, record in enumerate(records):
        record["id"] = f"amount-{index:04d}"
    return records


# --- text keys ------------------------------------------------------------------

TEXT_KEY_CASES = [
    "ZUS Coffee", "zus", "  ZEUS   COFFEE  ", "McDonald's", "mcdonald’s", "ZUS-Coffee", "ZUS Café",
    "Café Déjà Vu", "Tealive Sdn Bhd", "Tealive SdnBhd", "Kedai Runcit S/B", "Kedai S / B", "A&W",
    "Marks & Spencer", "7-Eleven", "7‑Eleven", "Ｇｒａｂ", "ß-Bar", "İstanbul Kebab", "Øresund",
    "Naïve Café", "Nando's", "", "   ", "!!!", "The  Chicken   Rice  Shop", "KFC (Mid Valley)",
    "Pasaraya Econsave", "99 Speedmart", "Mr. D.I.Y.", "Kopi-O", "Sdn Bhd", "sdnbhd", "S/B Store",
    "Tab\there", "line\nbreak", "Emoji ☕ Cafe", "Straße", "ǅemal", "ﬁnance ﬂow",
]


def text_key_records() -> list[dict]:
    return [{"id": f"key-{index:04d}", "input": value, "merchant_key": merchant_key(value),
             "canonical_text": canonical_text(value)} for index, value in enumerate(TEXT_KEY_CASES)]


# --- dates ----------------------------------------------------------------------

DATE_EXPRS = [
    "just now", "earlier", "today", "Today.", "TODAY!", "yesterday", "Yesterday?", "two days ago",
    "last monday", "last tuesday", "last wednesday", "last thursday", "last friday", "last saturday",
    "last sunday", "Last Friday", "15 september", "15 Sep", "15 sep 2025", "1 jan", "31 dec 2027",
    "29 feb", "29 feb 2028", "31 feb", "31 april", "september", "15/9", "15/09/2026", "15-09-2026",
    "15.09.2026", "3/4", "3/4/26", "31/04/2026", "13/13", "9/15", "0/5", "sometime", "tomorrow",
    "three days ago", "last week", "",
]
PERIOD_EXPRS = [
    "today", "yesterday", "this week", "last week", "this month", "last month", "this year",
    "last 7 days", "last 1 days", "last 0 days", "last 30 days", "september", "september 2025",
    "february 2028", "december", "january 2027", "eventually", "This Month.", "",
]
CAPTURES = [
    "2026-09-15T00:05:00+08:00", "2026-09-14T16:05:00+00:00", "2026-09-20T12:00:00+08:00",
    "2026-01-01T00:30:00+08:00", "2026-03-01T23:59:59+08:00", "2028-02-29T12:00:00+08:00",
    "2026-12-31T23:30:00-05:00",
    # DST edges: US spring-forward gap and fall-back overlap, Lord Howe's 30-minute shift.
    "2026-03-09T06:30:00+00:00", "2026-11-02T05:30:00+00:00", "2026-11-01T06:30:00+00:00",
    "2026-10-04T15:45:00+00:00",
]
ZONES = ["Asia/Kuala_Lumpur", "America/New_York", "UTC", "Australia/Lord_Howe", "Asia/Kolkata"]


def date_records() -> list[dict]:
    records = []
    for captured in CAPTURES:
        captured_at = datetime.fromisoformat(captured)
        for zone in ZONES:
            for expr in DATE_EXPRS:
                resolved = resolve_date_expr(expr, captured_at, zone)
                records.append({"kind": "date", "expr": expr, "captured_at": captured, "tz": zone,
                                "expect": None if resolved is None else {
                                    "occurred_at_utc": resolved[0].isoformat(), "local_date": resolved[1]}})
            for expr in PERIOD_EXPRS:
                resolved = resolve_period_expr(expr, captured_at, zone)
                records.append({"kind": "period", "expr": expr, "captured_at": captured, "tz": zone,
                                "expect": None if resolved is None else {
                                    "start": resolved[0].isoformat(), "end": resolved[1].isoformat()}})
    for index, record in enumerate(records):
        record["id"] = f"date-{index:05d}"
    return records


# --- finance --------------------------------------------------------------------

def _random_row(rng: random.Random, day: date | None = None) -> dict:
    flow = rng.choice(FLOWS)
    category = None if flow == "contribution" else "Income" if flow == "income" and rng.random() < .8 \
        else rng.choice(CATEGORIES)
    return {
        "type": flow,
        "amount_minor": rng.choice([1, 5, 50, 99, 100, 1_650, 2_000, 12_345, 350_000, 10_000_000_000,
                                    rng.randint(1, 500_000)]),
        "category": category,
        "merchant": rng.choice([None, None, "Grab", "ZUS Coffee", "Shopee", "Mamak"]),
        "deleted_at": "2026-09-20T00:00:00+00:00" if rng.random() < .1 else None,
        "local_date": (day or date(2026, 9, 1)).isoformat(),
    }


FINANCE_WORKED = [
    [{"type": "income", "amount_minor": 350_000, "category": "Income", "merchant": "Employer"},
     {"type": "expense", "amount_minor": 200_000, "category": "Other", "merchant": "Various"},
     {"type": "contribution", "amount_minor": 50_000, "category": None, "merchant": "Goal allocation"}],
    [{"type": "income", "amount_minor": 100_000, "category": "Income", "merchant": None},
     {"type": "expense", "amount_minor": 30_000, "category": "Shopping", "merchant": "Shop"},
     {"type": "refund", "amount_minor": 5_000, "category": "Shopping", "merchant": "Shop"}],
    [{"type": "expense", "amount_minor": 100, "category": "Other", "merchant": None}],
    [],
    [{"type": "refund", "amount_minor": 9_000, "category": "Travel", "merchant": "AirAsia"},
     {"type": "expense", "amount_minor": 1_000, "category": "Travel", "merchant": "AirAsia"}],
]


def _finance_expect(rows: list[dict]) -> dict:
    summary = asdict(summarize(rows))
    return {"summary": summary, "category_totals": category_totals(rows),
            "merchant_spending_totals": merchant_spending_totals(rows)}


def finance_records() -> list[dict]:
    rng = random.Random(20260926)
    ledgers = [[{**row, "deleted_at": None, "local_date": "2026-09-17"} for row in rows] for rows in FINANCE_WORKED]
    ledgers += [[_random_row(rng) for _ in range(rng.randint(0, 30))] for _ in range(60)]
    return [{"id": f"finance-{index:03d}", "rows": rows, "expect": _finance_expect(rows)}
            for index, rows in enumerate(ledgers)]


# --- planning -------------------------------------------------------------------

def planning_records() -> list[dict]:
    rng = random.Random(3_202_609)
    records = []
    days = [date(2026, 1, 1) + timedelta(days=offset) for offset in range(0, 3 * 366, 7)]
    days += [date(2026, 2, 27), date(2026, 2, 28), date(2028, 2, 28), date(2028, 2, 29), date(2026, 3, 1),
             date(2026, 4, 30), date(2026, 5, 31), date(2026, 12, 31), date(2027, 1, 1)]
    for day in days:
        for anchor in (1, 15, 28, 29, 30, 31, rng.randint(2, 27)):
            cycle = cycle_containing(day, anchor)
            records.append({"kind": "cycle", "today": day.isoformat(), "anchor_day": anchor,
                            "expect": {"start": cycle.start.isoformat(), "end": cycle.end.isoformat(),
                                       "days": cycle.days}})
    for _ in range(80):
        today = date(2026, 1, 1) + timedelta(days=rng.randint(0, 3 * 365))
        anchor = rng.choice([1, 1, 25, 28, 31, rng.randint(1, 31)])
        rules = []
        for index in range(rng.choice([0, 1, 1, 2])):
            start = today - timedelta(days=rng.randint(-40, 400))
            rules.append(MonthlyRule(
                id=f"rule-{index}", kind=rng.choice(["income", "income", "expense"]),
                amount_minor=rng.choice([320_000, 350_000, rng.randint(1, 900_000)]),
                day_of_month=rng.randint(1, 31), start=start,
                end=None if rng.random() < .7 else start + timedelta(days=rng.randint(0, 400))))
        cycle = cycle_containing(today, anchor)
        rows = []
        for _ in range(rng.randint(0, 25)):
            day = cycle.start + timedelta(days=rng.randint(-10, cycle.days + 10))
            rows.append(_random_row(rng, day))
        for rule in rules:
            occurrences = monthly_occurrences(rule, cycle.start, cycle.end)
            if rule.kind == "income" and occurrences and rng.random() < .6:
                occurrence = occurrences[0]
                landed = occurrence + timedelta(days=rng.randint(-3, 3))  # early or late salary
                rows.append({"type": "income", "amount_minor": rule.amount_minor + rng.choice([0, 0, -500]),
                             "category": "Income", "merchant": None,
                             "deleted_at": None if rng.random() < .85 else "2026-09-20T00:00:00+00:00",
                             "local_date": landed.isoformat(), "recurring_rule_id": rule.id,
                             "occurrence_date": occurrence.isoformat()})
        savings_mode = rng.choice(["fixed", "percentage"])
        params = {
            "anchor_day": anchor,
            "savings_mode": savings_mode,
            "savings_target_minor": rng.choice([0, 50_000, 160_000]) if savings_mode == "fixed" else 0,
            "savings_basis_points": rng.choice([0, 1, 2_000, 2_025, 5_000, 10_000]) if savings_mode == "percentage" else 0,
            "fixed_commitments_minor": rng.choice([0, 35_000, 120_000]),
        }
        plan = cycle_plan(rows, today=today, rules=rules, **params)
        records.append({"kind": "plan", "today": today.isoformat(), "rows": rows,
                        "rules": [{**asdict(rule), "start": rule.start.isoformat(),
                                   "end": rule.end.isoformat() if rule.end else None} for rule in rules],
                        "params": params, "expect": plan})
    for index, record in enumerate(records):
        record["id"] = f"planning-{index:04d}"
    return records


# --- merchant learning -----------------------------------------------------------

LEARNING_SCENARIOS = {
    "combined-correction": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"merchant": "ZUS Coffee", "category": "Food & Drink"}},
        {"op": "resolve", "name": "zeus cafe"}, {"op": "resolve", "name": "zus coffee"},
        {"op": "resolve", "name": "mcd"},
    ],
    "merchant-only-reuses-canonical": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"merchant": "  zus   coffee  "}},
        {"op": "resolve", "name": "zeus cafe"},
    ],
    "category-only-teaches-new-merchant": [
        {"op": "create", "ref": "t1", "merchant": "Baker Lane", "category": "Shopping"},
        {"op": "resolve", "name": "baker lane"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"category": "Food & Drink"}},
        {"op": "resolve", "name": "baker lane"},
    ],
    "non-merchant-edits-do-not-teach": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"amount_minor": 1600}},
        {"op": "edit", "ref": "t1", "as": "e2", "patch": {"description": "A note"}},
        {"op": "resolve", "name": "zeus cafe"},
    ],
    "clear-and-delete-do-not-teach": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "create", "ref": "t2", "merchant": "Unknown Place", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"merchant": None}},
        {"op": "delete", "ref": "t2", "as": "d1"},
        {"op": "resolve", "name": "zeus cafe"}, {"op": "resolve", "name": "unknown place"},
    ],
    "category-edit-without-merchant": [
        {"op": "create", "ref": "t1", "merchant": None, "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"category": "Food & Drink"}},
    ],
    "repeated-correction-reassigns-alias": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"merchant": "ZUS Coffee", "category": "Food & Drink"}},
        {"op": "create", "ref": "t2", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t2", "as": "e2", "patch": {"merchant": "Zeus Café KL", "category": "Groceries"}},
        {"op": "resolve", "name": "zeus cafe"}, {"op": "resolve", "name": "Zeus Café KL"},
        {"op": "resolve", "name": "ZUS Coffee"},
    ],
    "undo-reverts-alias": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"merchant": "ZUS Coffee"}},
        {"op": "undo", "action": "e1"},
        {"op": "resolve", "name": "zeus cafe"},
    ],
    "undo-reverts-new-merchant": [
        {"op": "create", "ref": "t1", "merchant": "Baker Lane", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"category": "Food & Drink"}},
        {"op": "undo", "action": "e1"},
        {"op": "resolve", "name": "baker lane"},
    ],
    "undo-restores-seed-category": [
        {"op": "create", "ref": "t1", "merchant": "Grab", "category": "Transport"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"category": "Food & Drink"}},
        {"op": "resolve", "name": "grab"},
        {"op": "undo", "action": "e1"},
        {"op": "resolve", "name": "grab"}, {"op": "resolve", "name": "GRAB"},
    ],
    "reinforced-alias-survives-undo": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"merchant": "ZUS Coffee"}},
        {"op": "create", "ref": "t2", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t2", "as": "e2", "patch": {"merchant": "ZUS Coffee"}},
        {"op": "undo", "action": "e1"},
        {"op": "resolve", "name": "zeus cafe"},
    ],
    "later-conflicting-correction-wins": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"merchant": "ZUS Coffee"}},
        {"op": "create", "ref": "t2", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t2", "as": "e2", "patch": {"merchant": "Zeus Bakery"}},
        {"op": "undo", "action": "e1"},
        {"op": "resolve", "name": "zeus cafe"},
    ],
    "undo-reinforcer-then-original": [
        {"op": "create", "ref": "t1", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"merchant": "ZUS Coffee"}},
        {"op": "create", "ref": "t2", "merchant": "Zeus Cafe", "category": "Shopping"},
        {"op": "edit", "ref": "t2", "as": "e2", "patch": {"merchant": "ZUS Coffee"}},
        {"op": "undo", "action": "e2"}, {"op": "resolve", "name": "zeus cafe"},
        {"op": "undo", "action": "e1"}, {"op": "resolve", "name": "zeus cafe"},
    ],
    "undo-conflicts-and-later-edits-survive": [
        {"op": "create", "ref": "t1", "as": "c1", "merchant": "Mamak", "category": "Food & Drink"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"amount_minor": 2000}},
        {"op": "edit", "ref": "t1", "as": "e2", "patch": {"description": "Team lunch"}},
        {"op": "edit", "ref": "t1", "as": "e3", "patch": {"amount_minor": 2500}},
        {"op": "undo", "action": "e1"}, {"op": "undo", "action": "c1"},
        {"op": "undo", "action": "e3"}, {"op": "undo", "action": "e1"},
        {"op": "undo", "action": "e2"}, {"op": "undo", "action": "e2"},
    ],
    "delete-undo-and-type-change": [
        {"op": "create", "ref": "t1", "as": "c1", "merchant": "Shopee", "category": "Shopping"},
        {"op": "edit", "ref": "t1", "as": "e1", "patch": {"type": "contribution", "category": None}},
        {"op": "delete", "ref": "t1", "as": "d1"},
        {"op": "undo", "action": "d1"}, {"op": "undo", "action": "e1"},
        {"op": "edit", "ref": "t1", "as": "e2", "patch": {"type": "refund"}},
    ],
}


def _memory_state(database: Database) -> dict:
    with database.connect() as connection:
        merchants = {row["id"]: dict(row) for row in connection.execute("SELECT * FROM merchants")}
        aliases = [dict(row) for row in connection.execute("SELECT alias_key, merchant_id, source FROM merchant_aliases")]
        transactions = [dict(row) for row in connection.execute("SELECT * FROM transactions")]
    key_of = {merchant_id: row["canonical_key"] for merchant_id, row in merchants.items()}
    return {
        "merchants": sorted(({
            "canonical_key": row["canonical_key"], "display_name": row["display_name"],
            "category": row["category"], "subcategory": row["subcategory"],
            "is_user_taught": bool(row["is_user_taught"]),
        } for row in merchants.values()), key=lambda row: row["canonical_key"]),
        "aliases": sorted(({"alias_key": row["alias_key"], "merchant": key_of[row["merchant_id"]],
                            "source": row["source"]} for row in aliases), key=lambda row: row["alias_key"]),
        "_transactions": {row["id"]: row for row in transactions},
        "_key_of": key_of,
    }


def _transaction_view(row: dict, key_of: dict) -> dict:
    return {"type": row["type"], "amount_minor": row["amount_minor"], "merchant": row["merchant"],
            "merchant_key": key_of.get(row["merchant_id"]), "category": row["category"],
            "description": row["description"], "deleted": row["deleted_at"] is not None}


def learning_records() -> list[dict]:
    records = []
    now = datetime.fromisoformat("2026-09-17T14:30:00+08:00")
    for name, steps in LEARNING_SCENARIOS.items():
        with tempfile.TemporaryDirectory() as directory:
            database = Database(Path(directory) / "learning.db")
            database.bootstrap()
            executor = ActionExecutor(database)
            refs: dict[str, str] = {}
            actions: dict[str, str] = {}
            outcomes = []
            for step in steps:
                outcome: dict = {"op": step["op"]}
                if step["op"] == "create":
                    created = executor.create_transaction(TransactionCreate(
                        type="expense", amount_minor=1450, merchant=step["merchant"],
                        category=step["category"], occurred_at=now, local_date="2026-09-17",
                        raw_transcript="learning fixture"))
                    refs[step["ref"]] = created.transaction.id
                    if "as" in step:
                        actions[step["as"]] = created.action_id
                elif step["op"] == "edit":
                    executed = executor.update_transaction(refs[step["ref"]], dict(step["patch"]),
                                                           explicit_user_edit=True)
                    actions[step["as"]] = executed.action_id
                elif step["op"] == "delete":
                    actions[step["as"]] = executor.soft_delete_transaction(refs[step["ref"]]).action_id
                elif step["op"] == "undo":
                    try:
                        executor.undo(actions[step["action"]])
                        outcome["result"] = "undone"
                    except UndoConflictError:
                        outcome["result"] = "conflict"
                    except UndoNotSupportedError:
                        outcome["result"] = "unsupported"
                elif step["op"] == "resolve":
                    match = resolve_merchant_alias(step["name"], database)
                    outcome["result"] = None if match is None else {
                        "display_name": match.display_name, "category": match.category}
                state = _memory_state(database)
                outcome["transactions"] = {
                    ref: _transaction_view(state["_transactions"][transaction_id], state["_key_of"])
                    for ref, transaction_id in sorted(refs.items())}
                outcomes.append(outcome)
            final = _memory_state(database)
            records.append({"id": f"learning-{name}", "steps": steps, "outcomes": outcomes,
                            "final": {"merchants": final["merchants"], "aliases": final["aliases"]}})
    return records


def export(output: Path) -> list[Path]:
    output.mkdir(parents=True, exist_ok=True)
    files = {
        "amounts.jsonl": amount_records(),
        "text_keys.jsonl": text_key_records(),
        "dates.jsonl": date_records(),
        "finance.jsonl": finance_records(),
        "planning.jsonl": planning_records(),
        "merchant_learning.jsonl": learning_records(),
    }
    written = []
    for name, records in files.items():
        _jsonl(output / name, records)
        written.append(output / name)
    return written


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUTPUT
    for path in export(target):
        print(f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}: "
              f"{sum(1 for _ in path.open(encoding='utf-8'))} records")
