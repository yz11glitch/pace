from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from bench.asr.audio_utils import AudioValidationError, inspect_wav


PRIMARY_COUNTS = {"A": 15, "B": 5, "C": 7, "D": 5, "E": 5, "F": 3, "G": 4}
REQUIRED_FIELDS = {
    "id",
    "stage",
    "set",
    "category",
    "phrase_category",
    "audio",
    "sha256",
    "duration_ms",
    "spoken",
    "expect",
    "ambiguous_by_construction",
    "prior_available",
    "notes",
}


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{line_number}: {exc}") from exc
        if not isinstance(row, dict):
            raise ValueError(f"{path}:{line_number}: each line must be a JSON object")
        rows.append(row)
    return rows


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows)
    path.write_text(text, encoding="utf-8")


def validate_manifest(
    path: Path,
    *,
    require_audio: bool = True,
    require_complete_stage1: bool = True,
) -> list[dict[str, Any]]:
    rows = read_jsonl(path)
    errors: list[str] = []
    ids: set[str] = set()
    merchant_carriers: dict[str, set[str]] = defaultdict(set)
    item_counts: Counter[str] = Counter()
    categories: Counter[str] = Counter()
    sets: Counter[str] = Counter()
    four_digit = 0
    ambiguous_prior = 0
    ambiguous_novel = 0

    for index, row in enumerate(rows, 1):
        prefix = f"row {index}"
        missing = REQUIRED_FIELDS - row.keys()
        if missing:
            errors.append(f"{prefix}: missing {sorted(missing)}")
            continue
        clip_id = row["id"]
        if clip_id in ids:
            errors.append(f"{prefix}: duplicate id {clip_id!r}")
        ids.add(clip_id)
        if row["stage"] != 1:
            errors.append(f"{clip_id}: Stage 1 manifest contains stage={row['stage']!r}")
        if row["set"] not in {"primary", "adverse"}:
            errors.append(f"{clip_id}: invalid set {row['set']!r}")
        sets[row["set"]] += 1
        if row["set"] == "primary":
            categories[row["category"]] += 1
        expect = row.get("expect") or {}
        for field in ("amount", "currency", "direction", "merchant", "item", "date_expr"):
            if field not in expect:
                errors.append(f"{clip_id}: expect.{field} is missing")
        amount = expect.get("amount")
        if amount is not None and float(amount) >= 1000:
            four_digit += 1
        merchant = expect.get("merchant")
        if merchant:
            merchant_carriers[str(merchant).casefold()].add(str(row.get("planned_prompt") or row.get("spoken") or clip_id).casefold())
        item = expect.get("item")
        if item:
            item_counts[str(item).casefold()] += 1
        if row.get("ambiguous_by_construction"):
            if row.get("prior_available"):
                ambiguous_prior += 1
            else:
                ambiguous_novel += 1

        if not isinstance(row.get("spoken"), str) or not row["spoken"].strip():
            errors.append(f"{clip_id}: spoken must be transcribed by ear before a model run")
        audio_rel = row.get("audio")
        if require_audio and audio_rel:
            audio_path = path.parent / audio_rel
            if not audio_path.is_file():
                errors.append(f"{clip_id}: audio not found: {audio_path}")
            else:
                try:
                    facts = inspect_wav(audio_path)
                    if row.get("sha256") != facts["sha256"]:
                        errors.append(f"{clip_id}: sha256 does not match audio")
                    if row.get("duration_ms") != facts["duration_ms"]:
                        errors.append(f"{clip_id}: duration_ms does not match audio")
                except AudioValidationError as exc:
                    errors.append(f"{clip_id}: {exc}")

    if require_complete_stage1:
        if len(rows) != 50:
            errors.append(f"Stage 1 requires exactly 50 clips, found {len(rows)}")
        if sets != Counter({"primary": 44, "adverse": 6}):
            errors.append(f"expected 44 primary + 6 adverse, found {dict(sets)}")
        if dict(categories) != PRIMARY_COUNTS:
            errors.append(f"primary category counts must be {PRIMARY_COUNTS}, found {dict(categories)}")
        if len(merchant_carriers) != 5:
            errors.append(f"expected exactly 5 benchmark merchants, found {len(merchant_carriers)}")
        for merchant, carriers in merchant_carriers.items():
            if len(carriers) < 3:
                errors.append(f"merchant {merchant!r} appears in fewer than 3 different carriers")
        if len(item_counts) != 2:
            errors.append(f"expected exactly 2 benchmark product/item terms, found {len(item_counts)}")
        for item, count in item_counts.items():
            if count < 3:
                errors.append(f"item {item!r} appears only {count} times; need at least 3")
        if four_digit < 2:
            errors.append("need at least 2 genuinely intended four-digit amounts")
        if ambiguous_prior < 3:
            errors.append("need at least 3 ambiguous clips with seeded merchant priors")
        if ambiguous_novel < 2:
            errors.append("need at least 2 ambiguous clips without a seeded merchant prior")

    if errors:
        raise ValueError("Manifest validation failed:\n- " + "\n- ".join(errors))
    return rows

