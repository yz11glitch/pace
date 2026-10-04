from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import statistics
import time
from collections import defaultdict
from pathlib import Path

import psutil

from noted.actions import TurnProposal
from noted.compact import CompactProposal
from noted.llm import LlamaServerUnderstanding, validate_compact_proposal, validate_raw_proposal


ROOT = Path(__file__).parent


def _actual_fields(proposal) -> dict:
    action = proposal.actions[0]
    fields = {"turn_kind": proposal.turn_kind, "intent": action.intent}
    if action.intent == "create_transaction":
        for name in ("amount_expr", "direction", "merchant_expr", "item_expr", "category_hint", "date_expr"):
            fields[name] = getattr(action, name)
    elif action.intent == "update_transaction":
        fields.update(reference=action.target.reference, amount_expr=action.changes.amount_expr)
    elif action.intent in {"categorize_transaction", "delete_transaction"}:
        fields["merchant_expr"] = action.target.merchant_expr
        fields["reference"] = action.target.reference
        for name in ("category_hint", "negated_category_hint", "reason_hint"):
            if hasattr(action, name): fields[name] = getattr(action, name)
    elif action.intent == "query_transactions":
        for name in ("shape", "period_expr", "compare_period_expr", "category_hint", "merchant_expr", "item_expr", "direction", "limit"):
            fields[name] = getattr(action.query, name)
    elif action.intent == "teach_memory":
        for name in ("kind", "surface_expr", "category_hint"):
            fields[name] = getattr(action, name)
    elif action.intent == "answer_clarification":
        fields.update(choice_ordinal=action.choice_ordinal, answer_expr=action.answer_expr, polarity=action.polarity)
    return fields


def _expected_fields(expected: dict) -> dict:
    action = expected["action"]
    return {"turn_kind": expected["turn_kind"], **action}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=ROOT / "corpus.jsonl")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--passes", type=int, choices=(1, 2), default=1)
    parser.add_argument("--contract", choices=("v1", "v2"), default="v2")
    parser.add_argument("--cadence", choices=("burst", "sustained"), default="sustained")
    parser.add_argument("--idle-seconds", type=float, default=20.0)
    parser.add_argument("--seed", type=int, default=20260917)
    parser.add_argument("--baseline", type=Path, help="Report byte-exact raw-output matches against another run.")
    parser.add_argument("--limit", type=int, help="Run only the first N cases (diagnostics only).")
    args = parser.parse_args()
    service = LlamaServerUnderstanding(passes=args.passes, contract=args.contract)
    service.load()
    frame_base = "CONTEXT\n  now_local: 2026-09-15 14:32 (Asia/Kuala_Lumpur)\n  pending_question: {pending}\n  recent_transactions: none\n  known_merchants_sample: ZUS Coffee, McDonald's, Grab, Shell, Shopee"
    counts = defaultdict(lambda: [0, 0])
    results = []
    grammar_valid = 0
    lines = args.corpus.read_text(encoding="utf-8").splitlines()
    cases = [json.loads(line) for line in lines]
    random.Random(args.seed).shuffle(cases)
    if args.limit:
        cases = cases[:args.limit]
    baseline = {}
    if args.baseline:
        baseline = {row["id"]: row["raw_json"] for row in json.loads(args.baseline.read_text())["results"]}
    for index, case in enumerate(cases):
        if args.cadence == "burst" and index:
            time.sleep(args.idle_seconds)
        pending = "Which transaction? choices: 1, 2" if case["expected"]["action"]["intent"] == "answer_clarification" else "none"
        frame = frame_base.format(pending=pending)
        raw = service.understand(case["text"], frame)
        outcome = validate_compact_proposal(raw, case["text"]) if args.contract == "v2" else validate_raw_proposal(raw, case["text"])
        grammar_proposal = None
        try:
            json.loads(outcome.raw_json)
            grammar_valid += 1
            if args.contract == "v2":
                CompactProposal.model_validate_json(outcome.raw_json)
            else:
                grammar_proposal = TurnProposal.model_validate_json(outcome.raw_json)
        except ValueError:
            pass
        actual = _actual_fields(outcome.proposal or grammar_proposal) if (outcome.proposal or grammar_proposal) else {}
        expected = _expected_fields(case["expected"])
        field_results = {}
        for field, wanted in expected.items():
            if field == "merchant_expr" and wanted == "previous":
                field, wanted = "reference", "previous"
            got = actual.get(field)
            correct = got == wanted
            counts[field][0] += int(correct)
            counts[field][1] += 1
            field_results[field] = {"expected": wanted, "actual": got, "correct": correct}
        timings = raw.timings or {}
        results.append({"id": case["id"], "text": case["text"], "expected_intent": expected["intent"],
                        "status": outcome.status, "latency_ms": outcome.latency_ms,
                        "prompt_n": timings.get("prompt_n"), "cached_prompt_n": timings.get("cached_prompt_n"),
                        "prompt_ms": timings.get("prompt_ms"), "predicted_n": timings.get("predicted_n"),
                        "predicted_ms": timings.get("predicted_ms"),
                        "output_chars": len(outcome.raw_json or ""),
                        "output_bytes": len((outcome.raw_json or "").encode("utf-8")),
                        "output_sha256": hashlib.sha256((outcome.raw_json or "").encode()).hexdigest(),
                        "baseline_byte_exact": baseline.get(case["id"]) == outcome.raw_json if baseline else None,
                        "fields": field_results, "error": outcome.error, "raw_json": outcome.raw_json})
        print(f"{case['id']} {outcome.status} {outcome.latency_ms}ms")
    def distribution(values):
        ordered = sorted(values)
        return {"p50_ms": statistics.median(ordered),
                "p95_ms": ordered[max(0, math.ceil(len(ordered) * .95) - 1)]}

    latencies = [result["latency_ms"] for result in results]
    by_intent = {}
    for intent in sorted({result["expected_intent"] for result in results}):
        selected = [result["latency_ms"] for result in results if result["expected_intent"] == intent]
        by_intent[intent] = {"cases": len(selected), **distribution(selected)}
    rss = None
    for process in psutil.process_iter(("name", "cmdline", "memory_info")):
        if "llama-server" in (process.info["name"] or ""):
            rss = process.info["memory_info"].rss
            break
    summary = {
        "cases": len(results),
        "passes": args.passes,
        "contract": args.contract,
        "cadence": args.cadence,
        "idle_seconds": args.idle_seconds if args.cadence == "burst" else 0,
        "shuffle_seed": args.seed,
        "grammar_conformance_rate": grammar_valid / len(results),
        "semantic_validation_rate": sum(result["status"] == "validated" for result in results) / len(results),
        "intent_accuracy": counts["intent"][0] / counts["intent"][1],
        "per_field_accuracy": {field: correct / total for field, (correct, total) in sorted(counts.items())},
        **distribution(latencies),
        "per_intent_latency": by_intent,
        "output_chars_mean": statistics.mean(result["output_chars"] for result in results),
        "output_bytes_mean": statistics.mean(result["output_bytes"] for result in results),
        "predicted_tokens_mean": statistics.mean(result["predicted_n"] for result in results if result["predicted_n"] is not None),
        "prompt_ms_mean": statistics.mean(result["prompt_ms"] for result in results if result["prompt_ms"] is not None),
        "predicted_ms_mean": statistics.mean(result["predicted_ms"] for result in results if result["predicted_ms"] is not None),
        "byte_exact_rate": (sum(result["baseline_byte_exact"] for result in results) / len(results)) if baseline else None,
        "llama_rss_bytes": rss,
    }
    report = {"summary": summary, "results": results}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
