from __future__ import annotations

import sqlite3
from datetime import datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.api import create_app
from noted.backup import create_backup, restore_backup
from noted.db import Database
from noted.execute import ActionExecutor
from noted.models import PaceProfileInput, TransactionCreate


NOW = datetime.fromisoformat("2026-09-17T12:00:00+08:00")
PROFILE = {
    "income_amount_minor": 350_000,
    "income_frequency": "monthly",
    "next_income_date": "2026-09-28",
    "fixed_commitments_minor": 100_000,
    "savings_target_minor": 50_000,
}


class FakeASR:
    model_id = "fake"

    def load(self): pass
    def transcribe(self, _wav_bytes: bytes) -> str: return "Spent RM10 on lunch"
    def close(self): pass


def app_for(path: Path, now: datetime = NOW):
    return create_app(
        asr_service=FakeASR(), database_path=path, now_provider=lambda: now,
    )


def add(path: Path, flow: str, amount: int, local_date: str, *, deleted: bool = False):
    database = Database(path)
    category = None if flow == "contribution" else ("Income" if flow == "income" else "Other")
    result = ActionExecutor(database).create_transaction(TransactionCreate(
        type=flow, amount_minor=amount, category=category,
        occurred_at=datetime.fromisoformat(f"{local_date}T08:00:00+08:00"),
        local_date=local_date, raw_transcript=f"fixture {flow}",
    ))
    if deleted:
        ActionExecutor(database).soft_delete_transaction(result.transaction.id)
    return result


def test_profile_create_update_retrieve_audit_and_reconnect(tmp_path: Path):
    path = tmp_path / "noted.db"
    with TestClient(app_for(path)) as client:
        assert client.get("/api/profile").json() == {
            "setup_complete": False, "profile": None,
        }
        created = client.put("/api/profile", json=PROFILE)
        assert created.status_code == 200
        assert created.json()["profile"]["income_amount_minor"] == 350_000
        updated_input = {**PROFILE, "fixed_commitments_minor": 120_000}
        updated = client.put("/api/profile", json=updated_input)
        assert updated.status_code == 200
        assert updated.json()["profile"]["fixed_commitments_minor"] == 120_000

    with TestClient(app_for(path)) as client:
        result = client.get("/api/profile").json()
        assert result["setup_complete"] is True
        assert result["profile"]["fixed_commitments_minor"] == 120_000
        assert result["profile"]["currency"] == "MYR"
    with sqlite3.connect(path) as connection:
        stored = connection.execute(
            "SELECT income_amount_minor, fixed_commitments_minor FROM pace_profile"
        ).fetchone()
        assert stored == (350_000, 120_000)
        audits = connection.execute(
            "SELECT kind, target_table FROM action_log WHERE target_table = 'pace_profile'"
        ).fetchall()
        assert audits == [("set_pace_profile", "pace_profile")] * 2


@pytest.mark.parametrize("changes", [
    {"income_amount_minor": 0},
    {"income_amount_minor": -1},
    {"fixed_commitments_minor": -1},
    {"savings_target_minor": -1},
    {"income_frequency": "weekly"},
    {"next_income_date": "not-a-date"},
    {"fixed_commitments_minor": 310_000, "savings_target_minor": 50_000},
    {"income_amount_minor": 10_000_000_001},
])
def test_profile_rejects_invalid_or_impossible_values(tmp_path: Path, changes: dict):
    with TestClient(app_for(tmp_path / "noted.db")) as client:
        response = client.put("/api/profile", json={**PROFILE, **changes})
        assert response.status_code == 422
        assert client.get("/api/profile").json()["profile"] is None


def test_migration_preserves_existing_transactions(tmp_path: Path):
    path = tmp_path / "noted.db"
    database = Database(path)
    database.bootstrap()
    original = add(path, "expense", 1234, "2026-09-10").transaction
    with database.connect() as connection:
        connection.execute("DELETE FROM schema_migrations WHERE version = '005_pace_profile'")
        connection.execute("DROP TABLE pace_profile")
    database.bootstrap()
    assert database.transaction(original.id).amount_minor == 1234
    assert database.pace_profile() is None


def test_incomplete_profile_and_empty_month_are_explicit(tmp_path: Path):
    with TestClient(app_for(tmp_path / "noted.db")) as client:
        home = client.get("/api/home", headers={"X-Timezone": "Asia/Kuala_Lumpur"}).json()
    assert home["availability"]["transactions"] is True
    assert home["availability"]["profile"] is False
    assert len(home["availability"]["missing_profile_fields"]) == 5
    assert home["actual"] == {
        "income_minor": 0, "spending_minor": 0, "contributions_minor": 0,
        "retained_minor": 0, "unallocated_surplus_minor": 0,
        "spendable_minor": 0, "savings_rate": None, "contribution_rate": None,
    }
    assert home["plan"] is None
    assert home["projection"] is None


def test_home_reuses_b3_semantics_and_profile_plan(tmp_path: Path):
    path = tmp_path / "noted.db"
    with TestClient(app_for(path)) as client:
        assert client.put("/api/profile", json=PROFILE).status_code == 200
    add(path, "income", 350_000, "2026-09-01")
    add(path, "expense", 200_000, "2026-09-10")
    add(path, "refund", 10_000, "2026-09-11")
    add(path, "contribution", 50_000, "2026-09-12")
    add(path, "expense", 99_999, "2026-08-31")
    add(path, "expense", 88_888, "2026-09-18")  # future as of the injected clock
    add(path, "expense", 77_777, "2026-09-13", deleted=True)

    with TestClient(app_for(path)) as client:
        home = client.get("/api/home", headers={"X-Timezone": "Asia/Kuala_Lumpur"}).json()
    assert home["actual"] == {
        "income_minor": 350_000,
        "spending_minor": 190_000,
        "contributions_minor": 50_000,
        "retained_minor": 160_000,
        "unallocated_surplus_minor": 110_000,
        "spendable_minor": 300_000,
        "savings_rate": pytest.approx(160_000 / 350_000),
        "contribution_rate": pytest.approx(50_000 / 350_000),
    }
    assert home["actual"]["retained_minor"] == (
        home["actual"]["contributions_minor"] + home["actual"]["unallocated_surplus_minor"]
    )
    assert home["pace"] == {
        "spending_per_elapsed_day_minor": 190_000 // 17,
        "basis_spending_minor": 190_000,
        "basis_days_elapsed": 17,
    }
    assert home["plan"] == {
        "base_income_minor": 350_000,
        "additional_income_minor": 350_000,
        "planning_income_minor": 700_000,
        "savings_target_minor": 50_000,
        "remaining_to_set_aside_minor": 0,
        "remaining_discretionary_minor": 360_000,
        "planned_spendable_minor": 650_000,
        "discretionary_envelope_minor": 550_000,
        "planned_daily_discretionary_minor": 550_000 // 30,
    }


@pytest.mark.parametrize(
    ("now", "expected"),
    [
        (datetime.fromisoformat("2026-09-01T00:30:00+08:00"), ("2026-09-01", 1, 29)),
        (datetime.fromisoformat("2026-09-30T23:59:00+08:00"), ("2026-09-30", 30, 0)),
        (datetime.fromisoformat("2026-10-01T00:00:00+08:00"), ("2026-10-01", 1, 30)),
        # Same instant is still September in Kuala Lumpur, proving UTC does not choose the month.
        (datetime.fromisoformat("2026-09-30T16:00:00+00:00"), ("2026-10-01", 1, 30)),
    ],
)
def test_home_local_month_boundaries(tmp_path: Path, now: datetime, expected: tuple):
    with TestClient(app_for(tmp_path / "noted.db", now)) as client:
        period = client.get(
            "/api/home", headers={"X-Timezone": "Asia/Kuala_Lumpur"},
        ).json()["period"]
    assert (period["as_of_date"], period["days_elapsed"], period["days_remaining"]) == expected


def test_zero_income_and_overspending_keep_rates_unavailable(tmp_path: Path):
    path = tmp_path / "noted.db"
    with TestClient(app_for(path)):
        pass
    add(path, "expense", 25_000, "2026-09-02")
    add(path, "contribution", 5_000, "2026-09-03")
    with TestClient(app_for(path)) as client:
        actual = client.get("/api/home").json()["actual"]
    assert actual["income_minor"] == 0
    assert actual["spending_minor"] == 25_000
    assert actual["retained_minor"] == -25_000
    assert actual["unallocated_surplus_minor"] == -30_000
    assert actual["spendable_minor"] == -5_000
    assert actual["savings_rate"] is None
    assert actual["contribution_rate"] is None


def test_invalid_timezone_is_rejected(tmp_path: Path):
    with TestClient(app_for(tmp_path / "noted.db")) as client:
        response = client.get("/api/home", headers={"X-Timezone": "Mars/Olympus"})
    assert response.status_code == 400


def test_backup_restore_preserves_profile(tmp_path: Path):
    live = tmp_path / "live.db"
    backups = tmp_path / "backups"
    database = Database(live)
    database.bootstrap()
    ActionExecutor(database).set_pace_profile(PaceProfileInput.model_validate(PROFILE))
    backup = create_backup(live, backups)
    ActionExecutor(database).set_pace_profile(PaceProfileInput.model_validate({
        **PROFILE, "income_amount_minor": 400_000,
    }))
    restore_backup(backup, live, backups)
    assert Database(live).pace_profile().income_amount_minor == 350_000
