from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import random
import re
import statistics
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from jiwer import process_words
from scipy.stats import binomtest
from whisper_normalizer.english import EnglishTextNormalizer

from bench.asr.manifest import read_jsonl, validate_manifest
from bench.asr.normalize import canonical_text, recover_amount


ROOT = Path(__file__).resolve().parent
FILLERS = {"ah", "er", "erm", "hmm", "like", "uh", "um"}
RATE_FIELDS = ("arr", "aer", "b_prime_rate", "mrr", "merchant_exact_rate", "item_exact_rate", "adversarial_arr", "adverse_arr")


def rate(count: int, total: int) -> dict[str, float | int | None]:
    if total == 0:
        return {"count": count, "n": total, "rate": None, "ci_low": None, "ci_high": None}
    p = count / total
    z = 1.959963984540054
    denominator = 1 + z * z / total
    centre = (p + z * z / (2 * total)) / denominator
    spread = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    return {"count": count, "n": total, "rate": p, "ci_low": max(0.0, centre - spread), "ci_high": min(1.0, centre + spread)}


def percentile(values: list[float], percentile_value: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentile_value
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def normalize_for_wer(text: str, normalizer: EnglishTextNormalizer) -> str:
    return " ".join(normalizer(text).split())


def content_words(text: str, normalizer: EnglishTextNormalizer) -> str:
    return " ".join(word for word in normalize_for_wer(text, normalizer).split() if word not in FILLERS)


def simple_tokens(text: str) -> list[str]:
    return re.findall(r"[\w]+", canonical_text(text).replace("'", ""))


def contains_tokens(text: str, entity: str) -> bool:
    tokens = simple_tokens(text)
    target = simple_tokens(entity)
    return any(tokens[index:index + len(target)] == target for index in range(len(tokens) - len(target) + 1))


def observed_entity(reference: str, hypothesis: str, entity: str) -> str:
    ref_tokens = simple_tokens(reference)
    hyp_tokens = simple_tokens(hypothesis)
    target = simple_tokens(entity)
    start = next((i for i in range(len(ref_tokens) - len(target) + 1) if ref_tokens[i:i + len(target)] == target), None)
    if start is None:
        return ""
    end = start + len(target)
    observed: list[str] = []
    for tag, i1, i2, j1, j2 in SequenceMatcher(a=ref_tokens, b=hyp_tokens, autojunk=False).get_opcodes():
        if max(i1, start) < min(i2, end) or (tag == "insert" and start <= i1 <= end):
            observed.extend(hyp_tokens[j1:j2])
    return " ".join(observed)


def load_raw(results: Path, configs: list[str]) -> dict[str, list[dict[str, Any]]]:
    raw = {}
    for config in configs:
        path = results / config / "raw.jsonl"
        if not path.is_file():
            raise SystemExit(f"Missing raw results: {path}")
        raw[config] = read_jsonl(path)
    return raw


def prepare_adjudication(
    manifest: list[dict[str, Any]], raw: dict[str, list[dict[str, Any]]], priors: dict[str, Any], results: Path
) -> None:
    clips = {clip["id"]: clip for clip in manifest}
    visible: list[dict[str, Any]] = []
    key: dict[str, Any] = {}
    for config, rows in raw.items():
        first_pass = {row["clip_id"]: row for row in rows if row["pass"] == 1}
        for clip_id, row in first_pass.items():
            resolution = recover_amount(row["raw_transcript"], priors)
            expected_minor = round(float(clips[clip_id]["expect"]["amount"]) * 100)
            if resolution.provisional_tier == "A" and resolution.amount_minor == expected_minor:
                continue
            token = hashlib.sha256(f"noted-gate2|{config}|{clip_id}".encode()).hexdigest()[:12]
            visible.append({
                "token": token,
                "clip_id": clip_id,
                "set": clips[clip_id]["set"],
                "category": clips[clip_id]["category"],
                "intended_amount": f"{expected_minor / 100:.2f}",
                "transcript": row["raw_transcript"],
                "normalizer_amount": "" if resolution.amount_minor is None else f"{resolution.amount_minor / 100:.2f}",
                "normalizer_tier": resolution.provisional_tier,
                "normalizer_rung": "" if resolution.rung is None else resolution.rung,
                "alternatives": ";".join(f"{value / 100:.2f}" for value in resolution.alternatives_minor),
                "adjudicated_tier": "",
                "adjudicator_notes": "",
            })
            key[token] = {"config": config, "clip_id": clip_id, "resolution": resolution.to_dict()}
    random.Random(20260914).shuffle(visible)
    fields = list(visible[0]) if visible else [
        "token", "clip_id", "set", "category", "intended_amount", "transcript", "normalizer_amount",
        "normalizer_tier", "normalizer_rung", "alternatives", "adjudicated_tier", "adjudicator_notes",
    ]
    with (results / "adjudication.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(visible)
    (results / ".adjudication-key.json").write_text(json.dumps(key, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Prepared {len(visible)} blinded rows in {results / 'adjudication.csv'}")
    print("Fill adjudicated_tier with A, B, B', or C without opening .adjudication-key.json, then rerun score.py.")


def load_adjudication(results: Path, *, allow_unadjudicated: bool) -> dict[tuple[str, str], str]:
    csv_path = results / "adjudication.csv"
    key_path = results / ".adjudication-key.json"
    if not csv_path.exists() or not key_path.exists():
        return {}
    keys = json.loads(key_path.read_text(encoding="utf-8"))
    decisions: dict[tuple[str, str], str] = {}
    missing = []
    with csv_path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            tier = row["adjudicated_tier"].strip().upper().replace("B’", "B'")
            if not tier:
                missing.append(row["token"])
                continue
            if tier not in {"A", "B", "B'", "C"}:
                raise SystemExit(f"Invalid adjudicated tier {tier!r} for token {row['token']}")
            hidden = keys[row["token"]]
            decisions[(hidden["config"], hidden["clip_id"])] = tier
    if missing and not allow_unadjudicated:
        raise SystemExit(f"{len(missing)} blinded rows still need adjudicated_tier values")
    return decisions


def score_config(
    config: str,
    manifest: list[dict[str, Any]],
    rows: list[dict[str, Any]],
    priors: dict[str, Any],
    run_meta: dict[str, Any],
    adjudication: dict[tuple[str, str], str],
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    clips = {clip["id"]: clip for clip in manifest}
    by_clip: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_clip[row["clip_id"]].append(row)
    expected_passes = int(run_meta["passes"])
    if set(by_clip) != set(clips):
        raise SystemExit(f"{config}: raw clip IDs differ from manifest")

    normalizer = EnglishTextNormalizer()
    item_results: dict[str, dict[str, Any]] = {}
    total_ref_words = total_errors = total_content_ref = total_content_errors = 0
    for clip_id, pass_rows in by_clip.items():
        pass_rows.sort(key=lambda row: row["pass"])
        transcripts = [row["raw_transcript"] for row in pass_rows]
        if len(pass_rows) != expected_passes:
            raise SystemExit(f"{config}/{clip_id}: expected {expected_passes} passes, found {len(pass_rows)}")
        transcript = transcripts[0]
        clip = clips[clip_id]
        resolution = recover_amount(transcript, priors)
        expected_minor = round(float(clip["expect"]["amount"]) * 100)
        automatic_tier = resolution.provisional_tier
        if automatic_tier in {"A", "B"} and resolution.amount_minor != expected_minor:
            automatic_tier = "C"
        elif automatic_tier == "B'" and expected_minor not in resolution.alternatives_minor:
            automatic_tier = "C"
        tier = adjudication.get((config, clip_id), automatic_tier)
        ref = normalize_for_wer(clip["spoken"], normalizer)
        hyp = normalize_for_wer(transcript, normalizer)
        wer_result = process_words(ref, hyp)
        ref_content = content_words(clip["spoken"], normalizer)
        hyp_content = content_words(transcript, normalizer)
        content_result = process_words(ref_content, hyp_content)
        total_ref_words += wer_result.hits + wer_result.substitutions + wer_result.deletions
        total_errors += wer_result.substitutions + wer_result.deletions + wer_result.insertions
        total_content_ref += content_result.hits + content_result.substitutions + content_result.deletions
        total_content_errors += content_result.substitutions + content_result.deletions + content_result.insertions
        merchant = clip["expect"].get("merchant")
        item = clip["expect"].get("item")
        item_results[clip_id] = {
            "tier": tier,
            "automatic_tier": automatic_tier,
            "resolution": resolution.to_dict(),
            "transcript": transcript,
            "deterministic": len(set(transcripts)) == 1,
            "latency_median_ms": statistics.median(row["latency_ms"] for row in pass_rows),
            "merchant_expected": merchant,
            "merchant_observed": observed_entity(clip["spoken"], transcript, merchant) if merchant else None,
            "merchant_exact": bool(merchant and contains_tokens(transcript, merchant)),
            "item_expected": item,
            "item_observed": observed_entity(clip["spoken"], transcript, item) if item else None,
            "item_exact": bool(item and contains_tokens(transcript, item)),
        }

    # Stable means a non-empty wrong rendering is identical on every occurrence of the term.
    primary_ids = [clip["id"] for clip in manifest if clip["set"] == "primary"]
    adverse_ids = [clip["id"] for clip in manifest if clip["set"] == "adverse"]
    g_ids = [clip["id"] for clip in manifest if clip["set"] == "primary" and clip["category"] == "G"]
    for entity_type in ("merchant", "item"):
        term_variants: dict[str, set[str]] = defaultdict(set)
        for clip_id in primary_ids:
            result = item_results[clip_id]
            expected = result[f"{entity_type}_expected"]
            if expected:
                term_variants[canonical_text(expected)].add(result[f"{entity_type}_observed"] or "")
        for result in item_results.values():
            expected = result[f"{entity_type}_expected"]
            variants = term_variants.get(canonical_text(expected), set()) if expected else set()
            stable = bool(expected and not result[f"{entity_type}_exact"] and len(variants) == 1 and "" not in variants)
            result[f"{entity_type}_stable"] = stable
            result[f"{entity_type}_status"] = "exact" if result[f"{entity_type}_exact"] else "stable" if stable else "lost"

    merchant_ids = [clip_id for clip_id in primary_ids if item_results[clip_id]["merchant_expected"]]
    item_ids = [clip_id for clip_id in primary_ids if item_results[clip_id]["item_expected"]]
    entity_pairs = [
        (clip_id, entity_type)
        for clip_id in primary_ids
        for entity_type in ("merchant", "item")
        if item_results[clip_id][f"{entity_type}_expected"]
    ]
    tiers = Counter(item_results[clip_id]["tier"] for clip_id in primary_ids)
    adverse_tiers = Counter(item_results[clip_id]["tier"] for clip_id in adverse_ids)
    latencies = [item_results[clip_id]["latency_median_ms"] for clip_id in primary_ids]
    merchant_exact = sum(item_results[clip_id]["merchant_exact"] for clip_id in merchant_ids)
    item_exact = sum(item_results[clip_id]["item_exact"] for clip_id in item_ids)
    entity_resolvable = sum(item_results[clip_id][f"{entity_type}_status"] in {"exact", "stable"} for clip_id, entity_type in entity_pairs)

    itn = {}
    for category in sorted({clips[clip_id]["category"] for clip_id in primary_ids}):
        ids = [clip_id for clip_id in primary_ids if clips[clip_id]["category"] == category]
        forms = Counter(item_results[clip_id]["resolution"]["surface_class"] for clip_id in ids)
        modal, modal_count = forms.most_common(1)[0]
        fci = modal_count / len(ids)
        disposition = "Preserving" if fci >= 0.9 and modal == "word_form" else "Committing" if fci >= 0.9 else "Inconsistent" if fci < 0.75 else "Mixed"
        itn[category] = {"n": len(ids), "forms": dict(forms), "modal_form": modal, "fci": fci, "disposition": disposition}

    category_tiers = {}
    for category in sorted({clip["category"] for clip in manifest if clip["set"] == "primary"}):
        ids = [clip["id"] for clip in manifest if clip["set"] == "primary" and clip["category"] == category]
        category_tiers[category] = dict(Counter(item_results[clip_id]["tier"] for clip_id in ids))
    rungs = Counter(
        str(item_results[clip_id]["resolution"]["rung"] or "none")
        for clip_id in primary_ids
    )
    rung_correct = Counter(
        str(item_results[clip_id]["resolution"]["rung"] or "none")
        for clip_id in primary_ids if item_results[clip_id]["tier"] in {"A", "B"}
    )
    model_passes = run_meta["models"][config]["passes"]
    steady_rss = max(entry["steady_rss_bytes"] for entry in model_passes)
    peak_rss = max(entry["peak_process_rss_bytes"] for entry in model_passes)
    peak_mlx = max(entry["peak_mlx_bytes"] for entry in model_passes)
    deterministic = all(item_results[clip_id]["deterministic"] for clip_id in item_results)

    metrics = {
        "config": config,
        "tier_counts": dict(tiers),
        "arr": rate(tiers["A"] + tiers["B"], len(primary_ids)),
        "aer": rate(tiers["A"], len(primary_ids)),
        "b_prime_rate": rate(tiers["B'"], len(primary_ids)),
        "mrr": rate(entity_resolvable, len(entity_pairs)),
        "merchant_exact_rate": rate(merchant_exact, len(merchant_ids)),
        "item_exact_rate": rate(item_exact, len(item_ids)),
        "adversarial_arr": rate(sum(item_results[x]["tier"] in {"A", "B"} for x in g_ids), len(g_ids)),
        "adverse_arr": rate(adverse_tiers["A"] + adverse_tiers["B"], len(adverse_ids)),
        "wer": total_errors / total_ref_words if total_ref_words else None,
        "content_word_wer": total_content_errors / total_content_ref if total_content_ref else None,
        "latency_p50_ms": percentile(latencies, 0.50),
        "latency_p95_ms": percentile(latencies, 0.95),
        "cold_load_ms": run_meta["models"][config]["cold_load_ms"],
        "steady_rss_bytes": steady_rss,
        "peak_process_rss_bytes": peak_rss,
        "peak_mlx_bytes": peak_mlx,
        "on_disk_bytes": run_meta["models"][config].get("on_disk_bytes"),
        "deterministic": deterministic,
        "itn": itn,
        "category_tiers": category_tiers,
        "rungs": {rung: {"count": count, "correct": rung_correct[rung], "accuracy": rung_correct[rung] / count} for rung, count in rungs.items()},
    }
    elimination = []
    if metrics["arr"]["rate"] < 0.85: elimination.append("ARR < 85%")
    if category_tiers.get("A", {}).get("C", 0) >= 4: elimination.append("Tier C in category A >= 4")
    if any(value["fci"] < 0.75 for value in itn.values()): elimination.append("ITN FCI < 0.75")
    if metrics["mrr"]["rate"] is not None and metrics["mrr"]["rate"] < 0.80: elimination.append("MRR < 80%")
    if metrics["latency_p95_ms"] > 900: elimination.append("p95 latency > 900 ms")
    if steady_rss > 5.0 * 1024**3: elimination.append("steady RSS > 5.0 GiB")
    if not deterministic: elimination.append("non-deterministic transcript")
    if metrics["adversarial_arr"]["rate"] is not None and metrics["adversarial_arr"]["rate"] < 0.60: elimination.append("category G ARR < 60%")
    metrics["eliminated_by"] = elimination
    metrics["survives"] = not elimination
    ship_misses = []
    if metrics["arr"]["rate"] < 0.97: ship_misses.append("ARR < 97%")
    if metrics["aer"]["rate"] < 0.88: ship_misses.append("AER < 88%")
    if metrics["b_prime_rate"]["rate"] > 0.08: ship_misses.append("B′ > 8%")
    if category_tiers.get("A", {}).get("C", 0) > 2: ship_misses.append("category-A Tier C > 2")
    if any(value["fci"] < 0.90 for value in itn.values()): ship_misses.append("FCI < 90%")
    if metrics["mrr"]["rate"] is not None and metrics["mrr"]["rate"] < 0.90: ship_misses.append("MRR < 90%")
    if metrics["merchant_exact_rate"]["rate"] is not None and metrics["merchant_exact_rate"]["rate"] < 0.70: ship_misses.append("merchant exact < 70%")
    if metrics["latency_p95_ms"] > 600: ship_misses.append("p95 latency > 600 ms")
    if steady_rss > 4.0 * 1024**3: ship_misses.append("steady RSS > 4.0 GiB")
    if metrics["adversarial_arr"]["rate"] is not None and metrics["adversarial_arr"]["rate"] < 0.85: ship_misses.append("category-G ARR < 85%")
    metrics["ship_advisory_misses"] = ship_misses
    metrics["clears_ship_advisory"] = not ship_misses
    return metrics, item_results


def mcnemar(config_a: str, config_b: str, items: dict[str, dict[str, dict[str, Any]]], primary_ids: list[str]) -> dict[str, Any]:
    a_fixed_b_lost = sum(items[config_a][clip]["tier"] != "C" and items[config_b][clip]["tier"] == "C" for clip in primary_ids)
    a_lost_b_fixed = sum(items[config_a][clip]["tier"] == "C" and items[config_b][clip]["tier"] != "C" for clip in primary_ids)
    discordant = a_fixed_b_lost + a_lost_b_fixed
    p = binomtest(a_fixed_b_lost, discordant, 0.5).pvalue if discordant else 1.0
    return {"a": config_a, "b": config_b, "a_fixed_b_lost": a_fixed_b_lost, "a_lost_b_fixed": a_lost_b_fixed, "exact_p": p}


def pct(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.1f}%"


def four_way_decision_ladder(survivors: list[dict[str, Any]]) -> tuple[dict[str, Any], int, str]:
    top = max(survivors, key=lambda metric: metric["arr"]["rate"])
    if all(
        other is top or top["arr"]["ci_low"] > other["arr"]["ci_high"]
        for other in survivors
    ):
        return top, 2, "higher ARR with non-overlapping Wilson intervals"
    disposition_rank = {"Preserving": 3, "Committing": 2, "Mixed": 1, "Inconsistent": 0}
    tests = [
        (3, "better category-A ITN disposition and FCI", lambda metric: (disposition_rank[metric["itn"].get("A", {}).get("disposition", "Inconsistent")], min(value["fci"] for value in metric["itn"].values()))),
        (4, "lower B′ confirmation rate", lambda metric: -metric["b_prime_rate"]["rate"]),
        (5, "higher merchant exact rate", lambda metric: metric["merchant_exact_rate"]["rate"] or 0),
        (6, "lower steady-state RAM", lambda metric: -metric["steady_rss_bytes"]),
        (7, "lower p95 latency", lambda metric: -metric["latency_p95_ms"]),
        (8, "smaller model on disk", lambda metric: -(metric["on_disk_bytes"] or math.inf)),
    ]
    candidates = list(survivors)
    for rung, reason, key in tests:
        best_value = max(key(metric) for metric in candidates)
        candidates = [metric for metric in candidates if key(metric) == best_value]
        if len(candidates) == 1:
            return candidates[0], rung, reason
    return candidates[0], 9, "equivalent in-process Python/MLX integration; config order is the final stable fallback"


def render_markdown(summary: dict[str, Any], output: Path) -> None:
    lines = [
        "# Gate 2 — ASR benchmark results",
        "",
        f"Status: **{summary['outcome']}** · Stage 1",
        "",
        "> Stage 1 (n = 44): CI ≈ ±9 points. Detects ~15-point gaps. Cannot detect 5-point gaps.",
        "> Stage 2 (n = 84): CI ≈ ±5 points. Detects ~8-point gaps. Cannot detect 2-point gaps.",
        "",
        "Stage 2 has not run. This file is generated from machine-readable Stage 1 results.",
        "",
        "## Environment and resolved snapshots",
        "",
        f"macOS {summary['environment']['macos']} on {summary['environment']['machine']}; Python {summary['environment']['python']}; "
        f"MLX {summary['environment']['packages']['mlx']}; parakeet-mlx {summary['environment']['packages']['parakeet-mlx']}; "
        f"mlx-whisper {summary['environment']['packages']['mlx-whisper']}.",
        "",
        "| Config | Repository | Commit SHA | On disk | Cold load |",
        "|---|---|---|---:|---:|",
    ]
    for metric in summary["configs"]:
        model = summary["models"][metric["config"]]
        lines.append(f"| {metric['config']} | `{model.get('repo_id', 'unknown')}` | `{model.get('commit_sha', 'unknown')}` | {(metric['on_disk_bytes'] or 0) / 1024**3:.3f} GiB | {metric['cold_load_ms']:.0f} ms |")
    lines.extend([
        "", "## Metric matrix",
        "",
        "| Config | ARR (95% CI) | AER | B′ | MRR | Merchant exact | Product exact | p50 / p95 | Steady RSS | Disk | Deterministic | Verdict |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|",
    ])
    for metric in summary["configs"]:
        arr = metric["arr"]
        verdict = "SURVIVES" if metric["survives"] else "ELIMINATED: " + "; ".join(metric["eliminated_by"])
        lines.append(
            f"| {metric['config']} | {pct(arr['rate'])} ({pct(arr['ci_low'])}–{pct(arr['ci_high'])}) | "
            f"{pct(metric['aer']['rate'])} | {pct(metric['b_prime_rate']['rate'])} | {pct(metric['mrr']['rate'])} | "
            f"{pct(metric['merchant_exact_rate']['rate'])} | {pct(metric['item_exact_rate']['rate'])} | {metric['latency_p50_ms']:.0f} / {metric['latency_p95_ms']:.0f} ms | "
            f"{metric['steady_rss_bytes'] / 1024**3:.2f} GiB | "
            f"{(metric['on_disk_bytes'] or 0) / 1024**3:.2f} GiB | {'yes' if metric['deterministic'] else 'NO'} | {verdict} |"
        )
    lines.extend(["", "## Pairwise McNemar exact tests", "", "| A | B | A fixed / B lost | A lost / B fixed | exact p |", "|---|---|---:|---:|---:|"])
    for comparison in summary["mcnemar"]:
        lines.append(f"| {comparison['a']} | {comparison['b']} | {comparison['a_fixed_b_lost']} | {comparison['a_lost_b_fixed']} | {comparison['exact_p']:.4f} |")
    lines.extend(["", "## Per-category amount tiers", "", "| Config | Category | A | B | B′ | C |", "|---|---|---:|---:|---:|---:|"])
    for metric in summary["configs"]:
        for category, counts in metric["category_tiers"].items():
            lines.append(f"| {metric['config']} | {category} | {counts.get('A', 0)} | {counts.get('B', 0)} | {counts.get("B'", 0)} | {counts.get('C', 0)} |")
    lines.extend(["", "## ITN disposition", ""])
    for metric in summary["configs"]:
        lines.extend([f"### {metric['config']}", "", "| Category | Modal form | FCI | Disposition |", "|---|---|---:|---|"])
        for category, value in metric["itn"].items():
            lines.append(f"| {category} | {value['modal_form']} | {pct(value['fci'])} | {value['disposition']} |")
        lines.append("")
    lines.extend(["## Context-ladder rungs", "", "| Config | Rung | Fires | Correct | Accuracy |", "|---|---|---:|---:|---:|"])
    for metric in summary["configs"]:
        for rung, value in metric["rungs"].items():
            lines.append(f"| {metric['config']} | {rung} | {value['count']} | {value['correct']} | {pct(value['accuracy'])} |")
    lines.extend(["", "## Adverse-set profile", "", "| Config | Adverse ARR (95% CI) |", "|---|---:|"])
    for metric in summary["configs"]:
        adverse = metric["adverse_arr"]
        lines.append(f"| {metric['config']} | {pct(adverse['rate'])} ({pct(adverse['ci_low'])}–{pct(adverse['ci_high'])}) |")
    lines.extend(["## Tier-C incidents", ""])
    for incident in summary["tier_c_incidents"]:
        lines.append(f"- `{incident['config']}` / `{incident['clip_id']}`: intended MYR {incident['intended']:.2f}; transcribed “{incident['transcript']}”.")
    if not summary["tier_c_incidents"]:
        lines.append("None.")
    lines.extend([
        "", "## Decision", "", summary["decision"], "",
        "### Stage 2 ship-threshold advisory", "",
    ])
    for metric in summary["configs"]:
        advisory = "clears every advisory threshold" if metric["clears_ship_advisory"] else "misses: " + "; ".join(metric["ship_advisory_misses"])
        lines.append(f"- `{metric['config']}` {advisory}.")
    lines.extend([
        "",
        "## What this benchmark could not resolve", "",
        summary["limitations"], "",
    ])
    output.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Score NOTED Gate 2 without reducing it to WER")
    parser.add_argument("--manifest", type=Path, default=ROOT / "corpus.jsonl")
    parser.add_argument("--priors", type=Path, default=ROOT / "priors.json")
    parser.add_argument("--results", type=Path, default=ROOT / "results")
    parser.add_argument("--markdown", type=Path, default=ROOT.parents[1] / "docs" / "02-gate2-results.md")
    parser.add_argument("--prepare-adjudication", action="store_true")
    parser.add_argument("--allow-incomplete", action="store_true", help="smoke fixtures only")
    parser.add_argument("--allow-unadjudicated", action="store_true", help="smoke fixtures only")
    args = parser.parse_args()
    manifest = validate_manifest(args.manifest, require_audio=True, require_complete_stage1=not args.allow_incomplete)
    priors = json.loads(args.priors.read_text(encoding="utf-8")) if args.priors.exists() else {"merchants": []}
    run_meta = json.loads((args.results / "run.json").read_text(encoding="utf-8"))
    configs = run_meta["selected_configs"]
    raw = load_raw(args.results, configs)
    if args.prepare_adjudication:
        prepare_adjudication(manifest, raw, priors, args.results)
        return
    adjudication = load_adjudication(args.results, allow_unadjudicated=args.allow_unadjudicated)
    metrics = []
    items = {}
    for config in configs:
        scored, item_results = score_config(config, manifest, raw[config], priors, run_meta, adjudication)
        metrics.append(scored)
        items[config] = item_results
    primary_ids = [clip["id"] for clip in manifest if clip["set"] == "primary"]
    comparisons = [mcnemar(a, b, items, primary_ids) for i, a in enumerate(configs) for b in configs[i + 1:]]
    survivors = [metric for metric in metrics if metric["survives"]]
    if args.allow_incomplete:
        outcome = "SMOKE ONLY"
        decision = "Synthetic diagnostic fixture only. This is not a Gate 2 model decision and cannot eliminate or select a config."
    elif not survivors:
        outcome = "NO SURVIVORS"
        decision = "No config clears every Stage 1 elimination gate. Follow §5.5, beginning with the audio-chain check."
    elif len(survivors) == 1:
        outcome = "DECISIVE"
        decision = f"{survivors[0]['config']} is the only survivor; §6.6 rung 1 decides it. Apply the §5.4 advisory ship-threshold check."
    else:
        best = max(survivors, key=lambda metric: metric["arr"]["rate"])
        relevant = []
        for comparison in comparisons:
            if best["config"] not in {comparison["a"], comparison["b"]} or comparison["exact_p"] >= 0.01:
                continue
            fixed = comparison["a_fixed_b_lost"] if best["config"] == comparison["a"] else comparison["a_lost_b_fixed"]
            lost = comparison["a_lost_b_fixed"] if best["config"] == comparison["a"] else comparison["a_fixed_b_lost"]
            if fixed > lost:
                relevant.append(comparison)
        if len(relevant) == len(survivors) - 1:
            outcome = "DECISIVE"
            decision = f"{best['config']} beats every other survivor on Tier-C incidence at McNemar exact p < 0.01."
        elif len(survivors) == 4:
            winner, rung, reason = four_way_decision_ladder(survivors)
            outcome = "DECISIVE"
            decision = f"All four configs survived and accuracy remained tied; {winner['config']} wins at pre-committed §6.6 rung {rung}: {reason}. Stage 2 is skipped under §5.2."
        else:
            outcome = "CLOSE"
            decision = f"{len(survivors)} configs survive without decisive paired separation. Stage 2 is conditional under §5.2."
    incidents = []
    clip_map = {clip["id"]: clip for clip in manifest}
    for config in configs:
        for clip_id in primary_ids:
            if items[config][clip_id]["tier"] == "C":
                incidents.append({"config": config, "clip_id": clip_id, "intended": float(clip_map[clip_id]["expect"]["amount"]), "transcript": items[config][clip_id]["transcript"]})
    summary = {
        "stage": 1,
        "outcome": outcome,
        "decision": decision,
        "limitations": "Stage 1 has only 44 primary clips. Overlapping ARR Wilson intervals are ties; small apparent gaps cannot be resolved from this corpus.",
        "configs": metrics,
        "mcnemar": comparisons,
        "tier_c_incidents": incidents,
        "artifacts": run_meta["artifacts"],
        "environment": run_meta["environment"],
        "models": run_meta["models"],
    }
    (args.results / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    with (args.results / "summary.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = ["config", "survives", "eliminated_by", "arr", "aer", "b_prime_rate", "mrr", "merchant_exact_rate", "item_exact_rate", "adversarial_arr", "adverse_arr", "wer", "content_word_wer", "latency_p50_ms", "latency_p95_ms", "steady_rss_bytes", "peak_process_rss_bytes", "peak_mlx_bytes", "on_disk_bytes", "deterministic"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for metric in metrics:
            row = {field: metric.get(field) for field in fields}
            row["eliminated_by"] = "; ".join(metric["eliminated_by"])
            for field in RATE_FIELDS:
                row[field] = metric[field]["rate"]
            writer.writerow(row)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    render_markdown(summary, args.markdown)
    print(f"Scored {len(configs)} configs; outcome: {outcome}")
    print(f"Wrote {args.results / 'summary.json'}, {args.results / 'summary.csv'}, and {args.markdown}")


if __name__ == "__main__":
    main()
