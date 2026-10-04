from __future__ import annotations

import ast
import json
import sqlite3
from datetime import datetime
from pathlib import Path

import pytest
from pydantic import ValidationError

from noted.compact import CompactProposal, expand_compact
from noted.db import Database
from noted.execute import ActionExecutor
from noted.finance import category_totals, merchant_spending_totals, summarize
from noted.models import TransactionCreate


NOW = datetime.fromisoformat("2026-09-17T12:00:00+08:00")


def transaction(flow_class: str, amount_minor: int, *, category: str | None, merchant: str | None = None) -> TransactionCreate:
    return TransactionCreate(
        type=flow_class,
        amount_minor=amount_minor,
        merchant=merchant,
        category=category,
        occurred_at=NOW,
        local_date="2026-09-17",
        raw_transcript=f"fixture {flow_class}",
    )


def test_four_flow_classes_and_category_invariant_are_validated():
    for flow_class in ("expense", "income", "refund"):
        assert transaction(flow_class, 100, category="Other").type == flow_class
        with pytest.raises(ValidationError):
            transaction(flow_class, 100, category=None)

    assert transaction("contribution", 100, category=None).category is None
    with pytest.raises(ValidationError):
        transaction("contribution", 100, category="Other")


def test_worked_example_prevents_contribution_double_counting():
    rows = [
        transaction("income", 350_000, category="Income", merchant="Employer"),
        transaction("expense", 200_000, category="Other", merchant="Various"),
        transaction("contribution", 50_000, category=None, merchant="Goal allocation"),
    ]
    result = summarize(rows)

    assert result.income == 350_000
    assert result.spending == 200_000
    assert result.contributions == 50_000
    assert result.retained == 150_000
    assert result.unallocated_surplus == 100_000
    assert result.spendable == 300_000
    assert result.retained == result.contributions + result.unallocated_surplus
    assert result.savings_rate == pytest.approx(3 / 7)
    assert result.contribution_rate == pytest.approx(1 / 7)
    assert category_totals(rows) == {"Other": 200_000}
    assert merchant_spending_totals(rows) == {"Various": 200_000}


def test_refund_reduces_spending_but_never_increments_income():
    rows = [
        transaction("income", 100_000, category="Income"),
        transaction("expense", 30_000, category="Shopping", merchant="Shop"),
        transaction("refund", 5_000, category="Shopping", merchant="Shop"),
    ]
    result = summarize(rows)
    assert result.income == 100_000
    assert result.spending == 25_000
    assert category_totals(rows) == {"Shopping": 25_000}
    assert merchant_spending_totals(rows) == {"Shop": 25_000}


def test_income_rates_are_unavailable_when_income_is_zero():
    result = summarize([transaction("expense", 100, category="Other")])
    assert result.savings_rate is None
    assert result.contribution_rate is None


def test_migration_preserves_existing_rows_and_enforces_schema(tmp_path: Path):
    path = tmp_path / "populated.db"
    migrations = Path(__file__).parents[1] / "noted" / "migrations"
    connection = sqlite3.connect(path)
    connection.executescript((migrations / "001_initial.sql").read_text())
    connection.executescript((migrations / "002_conversation.sql").read_text())
    connection.execute(
        """INSERT INTO transactions (
            id, type, amount_minor, currency, merchant_id, merchant, description,
            category, subcategory, occurred_at, local_date, raw_transcript, created_at,
            updated_at, deleted_at, status
        ) VALUES ('existing-id', 'expense', 1234, 'MYR', NULL, 'Legacy merchant', NULL,
                  'Other', NULL, ?, '2026-09-17', 'legacy row', ?, NULL, NULL, 'confirmed')""",
        (NOW.isoformat(), NOW.isoformat()),
    )
    connection.execute("CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)")
    connection.executemany(
        "INSERT INTO schema_migrations VALUES (?, ?)",
        [("001_initial", NOW.isoformat()), ("002_conversation", NOW.isoformat())],
    )
    connection.commit()
    connection.close()

    database = Database(path)
    database.bootstrap()
    database.bootstrap()
    existing = database.transaction("existing-id")
    assert existing is not None
    assert existing.amount_minor == 1234
    assert existing.category == "Other"

    created = ActionExecutor(database).create_transaction(transaction("contribution", 50_000, category=None))
    assert database.transaction(created.transaction.id).category is None
    with database.connect() as migrated:
        assert migrated.execute("PRAGMA foreign_key_check").fetchall() == []
        with pytest.raises(sqlite3.IntegrityError):
            migrated.execute(
                """INSERT INTO transactions (
                    id, type, amount_minor, category, occurred_at, local_date, raw_transcript, created_at
                ) VALUES ('bad-contribution', 'contribution', 1, 'Other', ?, '2026-09-17', 'bad', ?)""",
                (NOW.isoformat(), NOW.isoformat()),
            )
        with pytest.raises(sqlite3.IntegrityError):
            migrated.execute(
                """INSERT INTO transactions (
                    id, type, amount_minor, category, occurred_at, local_date, raw_transcript, created_at
                ) VALUES ('bad-expense', 'expense', 1, NULL, ?, '2026-09-17', 'bad', ?)""",
                (NOW.isoformat(), NOW.isoformat()),
            )


@pytest.mark.parametrize("direction", ["expense", "income", "refund", "contribution"])
def test_compact_v2_accepts_all_flow_directions(direction: str):
    raw = json.dumps({
        "intent": "create_transaction",
        "amount_expr": "five hundred ringgit",
        "direction": direction,
    })
    assert CompactProposal.model_validate_json(raw).root.direction == direction
    assert expand_compact(raw, "five hundred ringgit").actions[0].direction == direction


def test_compact_schema_direction_enum_contains_exactly_four_flow_classes():
    schema = CompactProposal.model_json_schema()
    transaction_type = schema["$defs"]["CompactCreate"]["properties"]["direction"]
    assert transaction_type["enum"] == ["expense", "income", "refund", "contribution"]


def test_authoritative_finance_code_avoids_ambiguous_standalone_identifiers():
    source = (Path(__file__).parents[1] / "noted" / "finance.py").read_text()
    identifiers = {node.id for node in ast.walk(ast.parse(source)) if isinstance(node, ast.Name)}
    assert identifiers.isdisjoint({"saved", "savings", "saved_amount"})
