"""Undo reverts exactly one action and never overwrites later work.

Phase 1 oracle fixes (blueprint §9, decision O5):
- undoing an older action must not overwrite a later edit;
- undoing a correction reverts what merchant memory learned from that correction,
  unless a later correction reinforced the same mapping;
- undoing a non-transaction action is refused cleanly instead of failing.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.api import create_app
from noted.db import Database
from noted.execute import ActionExecutor, UndoConflictError, UndoNotSupportedError
from noted.merchants import resolve_merchant_alias
from noted.models import PaceProfileInput, TransactionCreate


NOW = datetime.fromisoformat("2026-09-17T12:00:00+08:00")


@pytest.fixture
def database(tmp_path: Path) -> Database:
    db = Database(tmp_path / "undo.db")
    db.bootstrap()
    return db


def expense(merchant: str | None = "Zeus Cafe", category: str = "Shopping", amount: int = 1450) -> TransactionCreate:
    return TransactionCreate(
        type="expense", amount_minor=amount, merchant=merchant, category=category,
        occurred_at=NOW, local_date="2026-09-17", raw_transcript="undo fixture",
    )


def alias_count(database: Database) -> int:
    with database.connect() as connection:
        return connection.execute("SELECT count(*) FROM merchant_aliases").fetchone()[0]


# --- later edits survive -----------------------------------------------------

def test_undoing_an_older_edit_to_a_different_field_keeps_the_later_edit(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense())
    amount_edit = executor.update_transaction(created.transaction.id, {"amount_minor": 2000})
    executor.update_transaction(created.transaction.id, {"description": "Team lunch"})

    restored = executor.undo(amount_edit.action_id)
    assert restored.transaction.amount_minor == 1450
    assert restored.transaction.description == "Team lunch"


def test_undoing_an_edit_whose_field_was_changed_again_is_a_conflict(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense())
    first = executor.update_transaction(created.transaction.id, {"amount_minor": 2000})
    executor.update_transaction(created.transaction.id, {"amount_minor": 2500})

    with pytest.raises(UndoConflictError):
        executor.undo(first.action_id)
    assert database.transaction(created.transaction.id).amount_minor == 2500
    assert database.action_row(first.action_id)["undone_at"] is None


def test_undoing_an_old_edit_conflicts_even_if_later_edits_restore_its_value(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense())
    first = executor.update_transaction(created.transaction.id, {"amount_minor": 2000})
    executor.update_transaction(created.transaction.id, {"amount_minor": 2500})
    executor.update_transaction(created.transaction.id, {"amount_minor": 2000})

    with pytest.raises(UndoConflictError):
        executor.undo(first.action_id)
    assert database.transaction(created.transaction.id).amount_minor == 2000


def test_older_edit_can_be_undone_after_later_edit_is_undone(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense())
    first = executor.update_transaction(created.transaction.id, {"amount_minor": 2000})
    later = executor.update_transaction(created.transaction.id, {"amount_minor": 2500})
    executor.undo(later.action_id)
    assert executor.undo(first.action_id).transaction.amount_minor == 1450


def test_undoing_a_create_after_a_later_edit_is_a_conflict(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense())
    executor.update_transaction(created.transaction.id, {"amount_minor": 2000})
    with pytest.raises(UndoConflictError):
        executor.undo(created.action_id)
    assert database.transaction(created.transaction.id) is not None


def test_undoing_a_delete_restores_only_the_deletion(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense())
    deleted = executor.soft_delete_transaction(created.transaction.id)
    restored = executor.undo(deleted.action_id)
    assert restored.transaction.deleted_at is None
    assert restored.transaction.amount_minor == 1450


def test_undoing_the_undo_target_twice_stays_idempotent(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense())
    edit = executor.update_transaction(created.transaction.id, {"amount_minor": 2000})
    first = executor.undo(edit.action_id)
    assert executor.undo(edit.action_id).action_id == first.action_id


def test_profile_undo_is_refused_cleanly(database: Database):
    executor = ActionExecutor(database)
    executor.set_pace_profile(PaceProfileInput(
        income_amount_minor=350_000, next_income_date="2026-09-28",
        fixed_commitments_minor=0, savings_target_minor=50_000,
    ))
    with database.connect() as connection:
        action_id = connection.execute(
            "SELECT id FROM action_log WHERE kind = 'set_pace_profile'").fetchone()[0]
    with pytest.raises(UndoNotSupportedError):
        executor.undo(action_id)


def test_api_maps_undo_conflicts_and_unsupported_undo_to_409(tmp_path: Path):
    class FakeASR:
        def load(self): pass
        def close(self): pass

    app = create_app(asr_service=FakeASR(), database_path=tmp_path / "api.db")
    with TestClient(app) as client:
        assert client.put("/api/profile", json={
            "income_amount_minor": 350_000, "income_frequency": "monthly",
            "next_income_date": "2026-09-28", "fixed_commitments_minor": 0,
            "savings_target_minor": 50_000,
        }).status_code == 200
        executor = app.state.executor
        created = executor.create_transaction(expense())
        first = executor.update_transaction(created.transaction.id, {"amount_minor": 2000})
        executor.update_transaction(created.transaction.id, {"amount_minor": 2500})
        assert client.post(f"/api/actions/{first.action_id}/undo").status_code == 409
        with app.state.database.connect() as connection:
            profile_action = connection.execute(
                "SELECT id FROM action_log WHERE kind = 'set_pace_profile'").fetchone()[0]
        assert client.post(f"/api/actions/{profile_action}/undo").status_code == 409


# --- O5: undo reverts learning ------------------------------------------------

def test_undoing_a_merchant_correction_reverts_the_learned_alias(database: Database):
    executor = ActionExecutor(database)
    before = alias_count(database)
    created = executor.create_transaction(expense())
    edit = executor.update_transaction(
        created.transaction.id, {"merchant": "ZUS Coffee"}, explicit_user_edit=True)
    assert resolve_merchant_alias("zeus cafe", database).display_name == "ZUS Coffee"

    executor.undo(edit.action_id)
    assert resolve_merchant_alias("zeus cafe", database) is None
    assert alias_count(database) == before
    # The seed alias the correction upgraded to "user" returns to "seed".
    with database.connect() as connection:
        assert connection.execute(
            "SELECT source FROM merchant_aliases WHERE alias_key = 'zus coffee'").fetchone()[0] == "seed"


def test_undoing_a_category_correction_reverts_the_learned_category(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense(merchant="Baker Lane"))
    edit = executor.update_transaction(
        created.transaction.id, {"category": "Food & Drink"}, explicit_user_edit=True)
    assert resolve_merchant_alias("baker lane", database).category == "Food & Drink"

    executor.undo(edit.action_id)
    assert resolve_merchant_alias("baker lane", database) is None
    with database.connect() as connection:
        assert connection.execute(
            "SELECT count(*) FROM merchants WHERE canonical_key = 'baker lane'").fetchone()[0] == 0


def test_undoing_a_category_correction_on_a_seeded_merchant_restores_its_category(database: Database):
    executor = ActionExecutor(database)
    created = executor.create_transaction(expense(merchant="Grab", category="Transport"))
    edit = executor.update_transaction(
        created.transaction.id, {"category": "Food & Drink"}, explicit_user_edit=True)
    assert resolve_merchant_alias("grab", database).category == "Food & Drink"
    executor.undo(edit.action_id)
    match = resolve_merchant_alias("grab", database)
    assert match.category == "Transport"
    with database.connect() as connection:
        assert connection.execute(
            "SELECT is_user_taught FROM merchants WHERE id = 'merchant-grab'").fetchone()[0] == 0


def test_a_later_reinforcing_correction_keeps_the_learned_alias(database: Database):
    executor = ActionExecutor(database)
    first = executor.create_transaction(expense())
    first_edit = executor.update_transaction(
        first.transaction.id, {"merchant": "ZUS Coffee"}, explicit_user_edit=True)
    second = executor.create_transaction(expense())
    executor.update_transaction(
        second.transaction.id, {"merchant": "ZUS Coffee"}, explicit_user_edit=True)

    executor.undo(first_edit.action_id)
    assert database.transaction(first.transaction.id).merchant == "Zeus Cafe"
    assert resolve_merchant_alias("zeus cafe", database).display_name == "ZUS Coffee"


def test_a_later_conflicting_correction_is_not_overwritten_by_undo(database: Database):
    executor = ActionExecutor(database)
    first = executor.create_transaction(expense())
    first_edit = executor.update_transaction(
        first.transaction.id, {"merchant": "ZUS Coffee"}, explicit_user_edit=True)
    second = executor.create_transaction(expense())
    executor.update_transaction(
        second.transaction.id, {"merchant": "Zeus Bakery"}, explicit_user_edit=True)
    assert resolve_merchant_alias("zeus cafe", database).display_name == "Zeus Bakery"

    executor.undo(first_edit.action_id)
    assert resolve_merchant_alias("zeus cafe", database).display_name == "Zeus Bakery"


def test_undoing_the_reinforcing_correction_first_then_the_original_reverts_fully(database: Database):
    executor = ActionExecutor(database)
    before = alias_count(database)
    first = executor.create_transaction(expense())
    first_edit = executor.update_transaction(
        first.transaction.id, {"merchant": "ZUS Coffee"}, explicit_user_edit=True)
    second = executor.create_transaction(expense())
    second_edit = executor.update_transaction(
        second.transaction.id, {"merchant": "ZUS Coffee"}, explicit_user_edit=True)

    executor.undo(second_edit.action_id)
    assert resolve_merchant_alias("zeus cafe", database) is not None  # first still teaches it
    executor.undo(first_edit.action_id)
    assert resolve_merchant_alias("zeus cafe", database) is None
    assert alias_count(database) == before
