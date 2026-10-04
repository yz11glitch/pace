from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest

from noted.db import Database
from noted.parser import parse_transaction


CAPTURED_AT = datetime.fromisoformat("2026-09-14T20:30:00+08:00")


@pytest.fixture
def database(tmp_path: Path) -> Database:
    db = Database(tmp_path / "noted.db")
    db.bootstrap()
    return db


@pytest.mark.parametrize(
    ("text", "transaction_type", "minor", "merchant", "category", "subcategory", "local_date"),
    [
        ("Spent twenty ringgit at McDonald's.", "expense", 2000, "McDonald's", "Food & Drink", None, "2026-09-14"),
        ("Spent sixteen fifty at ZUS Coffee.", "expense", 1650, "ZUS Coffee", "Food & Drink", "Coffee", "2026-09-14"),
        ("Grab ride was eighteen ringgit.", "expense", 1800, "Grab", "Transport", None, "2026-09-14"),
        ("Yesterday I paid sixty-seven ninety for groceries.", "expense", 6790, None, "Groceries", None, "2026-09-13"),
        ("Got paid one thousand eight hundred ringgit today.", "income", 180000, None, "Income", None, "2026-09-14"),
        ("Shell petrol was seventy-five ringgit.", "expense", 7500, "Shell", "Transport", "Fuel", "2026-09-14"),
        ("Got a refund of twenty-eight fifty today.", "refund", 2850, None, "Other", None, "2026-09-14"),
        ("Got a RM40 refund from Shopee", "refund", 4000, "Shopee", "Shopping", None, "2026-09-14"),
    ],
)
def test_required_phrases(database, text, transaction_type, minor, merchant, category, subcategory, local_date):
    result = parse_transaction(text, captured_at=CAPTURED_AT, timezone_name="Asia/Kuala_Lumpur", database=database)
    assert result.failure is None
    transaction = result.transaction
    assert transaction.type == transaction_type
    assert transaction.amount_minor == minor
    assert transaction.merchant == merchant
    assert transaction.category == category
    assert transaction.subcategory == subcategory
    assert transaction.local_date == local_date


def test_zus_seeded_asr_alias_is_safe(database):
    result = parse_transaction("Spent sixteen fifty at Zoo's Coffee.", captured_at=CAPTURED_AT, timezone_name="Asia/Kuala_Lumpur", database=database)
    assert result.transaction.merchant == "ZUS Coffee"
    assert result.merchant_match.method == "exact_alias"


@pytest.mark.parametrize("text", ["Spent 1650 at a new stall.", "hello there", "Spent 20 ringgit and 5 ringgit."])
def test_uncertain_or_malformed_input_is_not_a_transaction(database, text):
    result = parse_transaction(text, captured_at=CAPTURED_AT, timezone_name="Asia/Kuala_Lumpur", database=database)
    assert result.transaction is None
    assert result.failure is not None
