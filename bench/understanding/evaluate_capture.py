"""Score frozen capture cases through the real one-call engine, without a disk DB."""

from __future__ import annotations

import json
import sqlite3
import statistics
import uuid
from datetime import datetime, timezone
from pathlib import Path

from noted.conversation import process_capture
from noted.db import Database
from noted.execute import ActionExecutor
from noted.llm import LlamaServerUnderstanding


ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT / "tests" / "fixtures" / "capture_heldout.jsonl"
CAPTURED_AT = datetime(2026, 9, 22, 4, 0, tzinfo=timezone.utc)


class MemoryDatabase(Database):
    def __init__(self):
        self.path = Path(".")
        self.uri = f"file:capture_eval_{uuid.uuid4().hex}?mode=memory&cache=shared"
        self.anchor = sqlite3.connect(self.uri, uri=True)

    def connect(self):
        connection = sqlite3.connect(self.uri, uri=True, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def close(self):
        self.anchor.close()


class CountingUnderstanding:
    def __init__(self, service):
        self.service = service
        self.model_id = service.model_id
        self.contract = service.contract
        self.calls = 0
        self.raw = None

    def understand(self, transcript, frame):
        self.calls += 1
        proposal = self.service.understand(transcript, frame)
        self.raw = proposal.raw_json
        return proposal


def score(case: dict, result) -> list[str]:
    errors = []
    if result.state != case["state"]:
        errors.append(f"state={result.state}, expected={case['state']}")
    if case["state"] != "committed" or result.transaction is None:
        return errors
    transaction = result.transaction
    for expected_key, actual in (("direction", transaction.type),
                                 ("amount_minor", transaction.amount_minor),
                                 ("category", transaction.category),
                                 ("local_date", transaction.local_date)):
        if expected_key in case and actual != case[expected_key]:
            errors.append(f"{expected_key}={actual!r}, expected={case[expected_key]!r}")
    for expected_key, actual in (("merchant", transaction.merchant),
                                 ("item", transaction.description)):
        if expected_key in case and (actual is None or case[expected_key].casefold() not in actual.casefold()):
            errors.append(f"{expected_key}={actual!r}, expected to contain {case[expected_key]!r}")
    if "merchant" not in case and transaction.merchant is not None:
        errors.append(f"unsupported merchant={transaction.merchant!r}")
    if "item" not in case and transaction.description is not None:
        errors.append(f"unsupported item={transaction.description!r}")
    if "date_offset_days" in case:
        from datetime import timedelta
        expected = (CAPTURED_AT.date() - timedelta(days=case["date_offset_days"])).isoformat()
        if transaction.local_date != expected:
            errors.append(f"local_date={transaction.local_date!r}, expected={expected!r}")
    return errors


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", type=Path, default=CASES)
    args = parser.parse_args()
    model = LlamaServerUnderstanding(timeout_seconds=30)
    model.load()
    latencies = []
    passed = 0
    cases = [json.loads(line) for line in args.cases.read_text(encoding="utf-8").splitlines() if line.strip()]
    for case in cases:
        database = MemoryDatabase()
        database.bootstrap()
        service = CountingUnderstanding(model)
        try:
            result = process_capture(
                transcript=case["text"], session_id=str(uuid.uuid4()),
                captured_at=CAPTURED_AT, tz="Asia/Kuala_Lumpur", database=database,
                executor=ActionExecutor(database), understanding=service,
            )
            errors = score(case, result)
            if service.calls != 1:
                errors.append(f"qwen_calls={service.calls}, expected=1")
            passed += not errors
            latencies.append(result.timings_ms.understand)
            print(json.dumps({
                "text": case["text"], "pass": not errors, "errors": errors,
                "state": result.state, "direction": result.transaction.type if result.transaction else None,
                "amount_minor": result.transaction.amount_minor if result.transaction else None,
                "merchant": result.transaction.merchant if result.transaction else None,
                "item": result.transaction.description if result.transaction else None,
                "category": result.transaction.category if result.transaction else None,
                "date": result.transaction.local_date if result.transaction else None,
                "qwen_calls": service.calls, "qwen_raw": service.raw,
            }), flush=True)
        finally:
            database.close()
    print(json.dumps({"passed": passed, "total": len(cases),
                      "median_model_ms": statistics.median(latencies),
                      "max_model_ms": max(latencies)}), flush=True)


if __name__ == "__main__":
    main()
