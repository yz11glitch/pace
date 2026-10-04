"""The committed golden fixtures must match the oracles that produce them.

The native Swift suite replays ``fixtures/golden``; if an oracle change is not
re-exported, the two engines would silently diverge (blueprint §3.11).
Re-export with ``scripts/export_golden_fixtures.py`` and
``node scripts/export_ui_fixtures.mjs``.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "fixtures" / "golden"


def _exporter():
    spec = importlib.util.spec_from_file_location("export_golden_fixtures", ROOT / "scripts" / "export_golden_fixtures.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_python_oracle_fixtures_are_current(tmp_path: Path):
    for path in _exporter().export(tmp_path):
        assert path.read_bytes() == (GOLDEN / path.name).read_bytes(), f"{path.name} is stale; re-export"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is required for UI fixtures")
def test_ui_oracle_fixtures_are_current(tmp_path: Path):
    subprocess.run(["node", str(ROOT / "scripts" / "export_ui_fixtures.mjs"), str(tmp_path)],
                   check=True, capture_output=True)
    for name in ("keypad.jsonl", "money.jsonl", "note_fields.jsonl", "categories.jsonl"):
        assert (tmp_path / name).read_bytes() == (GOLDEN / name).read_bytes(), f"{name} is stale; re-export"


def test_parity_suite_meets_the_phase_1_minimums():
    counts = {path.name: sum(1 for _ in path.open(encoding="utf-8")) for path in GOLDEN.glob("*.jsonl")}
    assert counts["amounts.jsonl"] >= 30
    assert counts["dates.jsonl"] > 0 and counts["planning.jsonl"] > 0
    assert counts["finance.jsonl"] > 0 and counts["merchant_learning.jsonl"] > 0
