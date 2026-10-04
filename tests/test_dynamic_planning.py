from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from noted.api import create_app
from noted.db import Database
from noted.execute import ActionExecutor
from noted.models import TransactionCreate


class FakeASR:
    def load(self): pass
    def close(self): pass


def app_for(path: Path, now: str = "2026-09-17T12:00:00+08:00"):
    return create_app(asr_service=FakeASR(), database_path=path,
                      now_provider=lambda: datetime.fromisoformat(now))


def profile(salary=350_000, savings=50_000, mode="fixed", basis_points=0):
    return dict(income_amount_minor=salary, income_frequency="monthly",
                next_income_date="2026-09-28", fixed_commitments_minor=0,
                savings_target_minor=savings, savings_mode=mode,
                savings_percentage_basis_points=basis_points)


def transaction(path, flow, amount, day="2026-09-10"):
    return ActionExecutor(Database(path)).create_transaction(TransactionCreate(
        type=flow, amount_minor=amount,
        category=None if flow == "contribution" else "Income" if flow == "income" else "Other",
        occurred_at=datetime.fromisoformat(f"{day}T12:00:00+08:00"),
        local_date=day, raw_transcript="planning fixture",
    )).transaction


def home(client, timezone="Asia/Kuala_Lumpur"):
    response = client.get("/api/home", headers={"X-Timezone": timezone})
    assert response.status_code == 200
    return response.json()


def test_fixed_salary_and_extra_earned_recalculate_on_edit_delete(tmp_path):
    path = tmp_path / "planning.db"
    with TestClient(app_for(path)) as client:
        assert client.put("/api/profile", json=profile()).status_code == 200
        plan = home(client)["plan"]
        assert (plan["base_income_minor"], plan["additional_income_minor"],
                plan["planning_income_minor"], plan["savings_target_minor"],
                plan["discretionary_envelope_minor"]) == (350_000, 0, 350_000, 50_000, 300_000)

        earned = transaction(path, "income", 80_000)
        plan = home(client)["plan"]
        assert (plan["additional_income_minor"], plan["planning_income_minor"],
                plan["savings_target_minor"], plan["planned_daily_discretionary_minor"]) == (
                    80_000, 430_000, 50_000, 380_000 // 30)

        ActionExecutor(Database(path)).update_transaction(earned.id, {"amount_minor": 50_000})
        assert home(client)["plan"]["planning_income_minor"] == 400_000
        ActionExecutor(Database(path)).soft_delete_transaction(earned.id)
        assert home(client)["plan"]["planning_income_minor"] == 350_000


def test_percentage_income_contributions_refunds_and_month_boundary(tmp_path):
    path = tmp_path / "planning.db"
    with TestClient(app_for(path)) as client:
        assert client.put("/api/profile", json=profile(savings=0, mode="percentage", basis_points=2000)).status_code == 200
        earned = transaction(path, "income", 80_000)
        plan = home(client)["plan"]
        assert (plan["planning_income_minor"], plan["savings_target_minor"],
                plan["discretionary_envelope_minor"]) == (430_000, 86_000, 344_000)

        second = transaction(path, "income", 50_000)
        plan = home(client)["plan"]
        assert (plan["planning_income_minor"], plan["savings_target_minor"],
                plan["discretionary_envelope_minor"]) == (480_000, 96_000, 384_000)

        contribution = transaction(path, "contribution", 50_000)
        transaction(path, "refund", 12_000)
        plan = home(client)["plan"]
        assert (plan["planning_income_minor"], plan["savings_target_minor"],
                plan["remaining_to_set_aside_minor"], plan["discretionary_envelope_minor"]) == (
                    480_000, 96_000, 46_000, 384_000)
        assert home(client)["actual"]["contributions_minor"] == 50_000

        ActionExecutor(Database(path)).update_transaction(earned.id, {"amount_minor": 100_000})
        assert home(client)["plan"]["savings_target_minor"] == 100_000
        ActionExecutor(Database(path)).soft_delete_transaction(second.id)
        assert home(client)["plan"]["planning_income_minor"] == 450_000
        assert home(client)["plan"]["savings_target_minor"] == 90_000
        ActionExecutor(Database(path)).soft_delete_transaction(contribution.id)
        assert home(client)["plan"]["remaining_to_set_aside_minor"] == 90_000

    with TestClient(app_for(path, "2026-10-01T00:01:00+08:00")) as client:
        plan = home(client)["plan"]
        assert (plan["planning_income_minor"], plan["savings_target_minor"]) == (350_000, 70_000)


@pytest.mark.parametrize(("salary", "earned", "basis_points", "expected"), [
    (0, 50_000, 2000, 10_000),
    (0, 0, 2000, 0),
    (1, 0, 5000, 1),
    (3, 0, 5000, 2),
])
def test_zero_salary_and_money_safe_percentage_rounding(tmp_path, salary, earned, basis_points, expected):
    path = tmp_path / "planning.db"
    with TestClient(app_for(path)) as client:
        assert client.put("/api/profile", json=profile(salary, 0, "percentage", basis_points)).status_code == 200
        if earned:
            transaction(path, "income", earned)
        plan = home(client)["plan"]
        assert plan["planning_income_minor"] == salary + earned
        assert plan["savings_target_minor"] == expected


def test_timezone_selects_local_calendar_month(tmp_path):
    path = tmp_path / "planning.db"
    with TestClient(app_for(path, "2026-09-30T16:30:00+00:00")) as client:
        assert client.put("/api/profile", json=profile()).status_code == 200
        transaction(path, "income", 80_000, "2026-09-30")
        transaction(path, "income", 50_000, "2026-10-01")
        result = home(client)
        assert result["period"]["as_of_date"] == "2026-10-01"
        assert result["plan"]["planning_income_minor"] == 400_000


def test_profile_rejects_invalid_percentage_and_keeps_fixed_baseline_rule(tmp_path):
    with TestClient(app_for(tmp_path / "planning.db")) as client:
        for changes in (
            {"savings_mode": "percentage", "savings_percentage_basis_points": -1},
            {"savings_mode": "percentage", "savings_percentage_basis_points": 10_001},
            {"savings_mode": "unknown"},
            {"savings_target_minor": 400_000},
        ):
            assert client.put("/api/profile", json={**profile(), **changes}).status_code == 422
        assert client.get("/api/profile").json()["profile"] is None


def test_existing_profile_migrates_as_fixed_and_keeps_transactions(tmp_path, monkeypatch):
    import noted.db as db_module

    old_migrations = tmp_path / "old_migrations"
    old_migrations.mkdir()
    for source in db_module.MIGRATIONS.glob("*.sql"):
        if source.stem < "007":
            (old_migrations / source.name).write_bytes(source.read_bytes())
    legacy_path = tmp_path / "populated_legacy.db"
    with monkeypatch.context() as patch:
        patch.setattr(db_module, "MIGRATIONS", old_migrations)
        Database(legacy_path).bootstrap()
        with Database(legacy_path).connect() as connection:
            connection.execute("""INSERT INTO pace_profile
                (id,income_amount_minor,income_frequency,next_income_date,fixed_commitments_minor,
                 savings_target_minor,currency,created_at,updated_at)
                VALUES (1,350000,'monthly','2026-09-28',100000,50000,'MYR',
                        '2026-01-01T00:00:00+00:00','2026-01-02T00:00:00+00:00')""")
        recorded = transaction(legacy_path, "income", 80_000)
    Database(legacy_path).bootstrap()
    stored = Database(legacy_path).pace_profile()
    assert stored.savings_mode == "fixed"
    assert stored.savings_percentage_basis_points == 0
    assert stored.income_amount_minor == 350_000
    assert stored.savings_target_minor == 50_000
    assert stored.created_at.isoformat() == "2026-01-01T00:00:00+00:00"
    assert Database(legacy_path).transaction(recorded.id).amount_minor == 80_000
    Database(legacy_path).bootstrap()
    assert Database(legacy_path).pace_profile() == stored
