from __future__ import annotations

import argparse
import json
import statistics
import time
import urllib.request
from pathlib import Path

from noted.llm import LlamaServerUnderstanding, llama_json_schema


ROOT = Path(__file__).parent
TRANSCRIPT = "Roti canai was eight ringgit just now."
ALTERNATE_TRANSCRIPT = "Grab ride was eighteen ringgit."
FRAME = """CONTEXT
  now_local: 2026-09-15 14:32 (Asia/Kuala_Lumpur)
  pending_question: none
  recent_transactions: none
  known_merchants_sample: ZUS Coffee, McDonald's, Grab, Shell, Shopee"""


def percentile(values: list[float], proportion: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, int(len(ordered) * proportion + 0.999999) - 1)]


def main() -> None:
    parser = argparse.ArgumentParser(description="Gate B.2 fixed-overhead diagnostic")
    parser.add_argument("variant", choices=("full", "single", "none"))
    parser.add_argument("--repeats", type=int, default=20)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--server-mode", choices=("auto", "all"), default="auto")
    parser.add_argument("--alternate", action="store_true", help="Alternate two transcript tails to measure shared-prefix reuse.")
    args = parser.parse_args()

    service = LlamaServerUnderstanding()
    service.load()
    schema = {
        "full": llama_json_schema(full_proposal=True),
        "single": llama_json_schema("create_transaction"),
        "none": None,
    }[args.variant]
    results = []
    for repeat in range(1, args.repeats + 1):
        transcript = ALTERNATE_TRANSCRIPT if args.alternate and repeat % 2 == 0 else TRANSCRIPT
        messages = [
            {"role": "system", "content": service._prompt},
            {"role": "user", "content": f"{FRAME}\n\nTRANSCRIPT\n{transcript}"},
        ]
        prompt = "".join(
            f"<|im_start|>{message['role']}\n{message['content']}<|im_end|>\n"
            for message in messages
        ) + "<|im_start|>assistant\n"
        payload = {
            "prompt": prompt,
            "temperature": 0.0,
            "seed": 0,
            "n_predict": 82 if schema is None else 256,
            "stream": False,
        }
        if schema is not None:
            payload["json_schema"] = schema
        request = urllib.request.Request(
            f"{service.base_url}/completion",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        started = time.perf_counter()
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.load(response)
        wall_ms = (time.perf_counter() - started) * 1000
        timings = body["timings"]
        row = {
            "repeat": repeat,
            "prompt_n": timings["prompt_n"],
            "cached_prompt_n": timings.get("cache_n"),
            "tokens_cached_after": body.get("tokens_cached"),
            "prompt_ms": timings["prompt_ms"],
            "predicted_n": timings["predicted_n"],
            "predicted_ms": timings["predicted_ms"],
            "server_overhead_ms": wall_ms - timings["prompt_ms"] - timings["predicted_ms"],
            "total_latency_ms": wall_ms,
            "output_bytes": len(body["content"].encode("utf-8")),
            "raw_output": body["content"],
        }
        results.append(row)
        print(json.dumps({key: value for key, value in row.items() if key != "raw_output"}))

    measured = results[1:] if len(results) > 1 else results
    summary = {"variant": args.variant, "server_mode": args.server_mode, "alternate": args.alternate, "repeats": len(results)}
    for field in ("prompt_n", "cached_prompt_n", "prompt_ms", "predicted_n", "predicted_ms", "server_overhead_ms", "total_latency_ms"):
        values = [float(row[field]) for row in measured if row[field] is not None]
        summary[field] = {"median": statistics.median(values), "p95": percentile(values, 0.95)}
    report = {"summary": summary, "results": results}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
