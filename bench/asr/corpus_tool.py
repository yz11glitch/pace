from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from bench.asr.audio_utils import inspect_wav
from bench.asr.manifest import read_jsonl, validate_manifest, write_jsonl


ROOT = Path(__file__).resolve().parent


def render(value: Any, profile: dict[str, Any]) -> Any:
    if isinstance(value, str):
        return value.format_map(profile)
    if isinstance(value, list):
        return [render(item, profile) for item in value]
    if isinstance(value, dict):
        return {key: render(item, profile) for key, item in value.items()}
    return value


def init_corpus(profile_path: Path, output: Path, priors_path: Path) -> None:
    if output.exists() or priors_path.exists():
        raise SystemExit("Refusing to overwrite corpus or priors; move them aside explicitly first.")
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    required = {*(f"merchant_{i}" for i in range(1, 6)), "item_1", "item_2", "merchant_priors"}
    missing = required - profile.keys()
    if missing:
        raise SystemExit(f"Profile is missing: {sorted(missing)}")
    rows = []
    for plan in read_jsonl(ROOT / "recording-plan.jsonl"):
        row = render(plan, profile)
        row.update({
            "stage": 1,
            "audio": f"audio/{row['id']}.wav",
            "sha256": None,
            "duration_ms": None,
            "spoken": None,
        })
        rows.append(row)
    write_jsonl(output, rows)
    merchants = []
    for index in range(1, 6):
        key = f"merchant_{index}"
        prior = dict(profile["merchant_priors"][key])
        merchants.append({"name": profile[key], "aliases": [], **prior})
    priors_path.write_text(json.dumps({
        "merchants": merchants,
        "global": {"amount_count": 0, "amount_p99_minor": None},
        "categories": [],
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Created {output} with {len(rows)} planned clips")
    print(f"Created {priors_path}; review the ranges before recording")


def annotate(path: Path, clip_id: str, spoken: str) -> None:
    rows = read_jsonl(path)
    matches = [row for row in rows if row["id"] == clip_id]
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one clip {clip_id!r}, found {len(matches)}")
    matches[0]["spoken"] = spoken.strip()
    write_jsonl(path, rows)
    print(f"Updated spoken truth for {clip_id}")


def export_sheet(path: Path, output: Path) -> None:
    rows = read_jsonl(path)
    fields = ["id", "audio", "planned_prompt", "spoken", "notes"]
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field) or "" for field in fields})
    print(f"Wrote {output}; listen to each WAV and fill the spoken column by ear")


def import_sheet(path: Path, sheet: Path) -> None:
    rows = read_jsonl(path)
    by_id = {row["id"]: row for row in rows}
    seen = set()
    with sheet.open(newline="", encoding="utf-8") as handle:
        for entry in csv.DictReader(handle):
            clip_id = entry.get("id", "")
            if clip_id not in by_id:
                raise SystemExit(f"Unknown clip ID in sheet: {clip_id!r}")
            spoken = entry.get("spoken", "").strip()
            if not spoken:
                raise SystemExit(f"Missing spoken truth for {clip_id}")
            by_id[clip_id]["spoken"] = spoken
            seen.add(clip_id)
    missing = set(by_id) - seen
    if missing:
        raise SystemExit(f"Sheet is missing {len(missing)} clips: {sorted(missing)}")
    write_jsonl(path, rows)
    print(f"Imported spoken truth for {len(seen)} clips")


def show_status(path: Path, clip_id: str | None) -> None:
    rows = read_jsonl(path)
    if clip_id:
        rows = [row for row in rows if row["id"] == clip_id]
        if not rows:
            raise SystemExit(f"Unknown clip ID: {clip_id}")
    recorded = 0
    for row in rows:
        audio_path = path.parent / row["audio"]
        if not row.get("sha256") or not audio_path.is_file():
            if clip_id:
                print(f"{row['id']}: NOT UPLOADED ({audio_path})")
            continue
        facts = inspect_wav(audio_path)
        matches = facts["sha256"] == row["sha256"] and facts["duration_ms"] == row["duration_ms"]
        state = "UPLOADED AND VERIFIED" if matches else "FILE/MANIFEST MISMATCH"
        print(f"{row['id']}: {state} | {audio_path} | {facts['duration_ms']} ms | {facts['bytes']} bytes | sha256 {facts['sha256']}")
        if not matches:
            raise SystemExit(1)
        recorded += 1
    print(f"Recorded files verified: {recorded}/{len(rows)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare and validate the NOTED Gate 2 corpus")
    subparsers = parser.add_subparsers(dest="command", required=True)
    init_parser = subparsers.add_parser("init", help="render the 50-clip plan with your real terms")
    init_parser.add_argument("--profile", type=Path, default=ROOT / "recording-profile.json")
    init_parser.add_argument("--output", type=Path, default=ROOT / "corpus.jsonl")
    init_parser.add_argument("--priors", type=Path, default=ROOT / "priors.json")
    annotate_parser = subparsers.add_parser("annotate", help="set verbatim spoken truth after listening")
    annotate_parser.add_argument("clip_id")
    annotate_parser.add_argument("spoken")
    annotate_parser.add_argument("--manifest", type=Path, default=ROOT / "corpus.jsonl")
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--manifest", type=Path, default=ROOT / "corpus.jsonl")
    validate_parser.add_argument("--draft", action="store_true", help="allow missing audio and spoken truth")
    export_parser = subparsers.add_parser("export-sheet", help="make a CSV for by-ear transcription")
    export_parser.add_argument("--manifest", type=Path, default=ROOT / "corpus.jsonl")
    export_parser.add_argument("--output", type=Path, default=ROOT / "transcription-sheet.csv")
    import_parser = subparsers.add_parser("import-sheet", help="import the completed spoken column")
    import_parser.add_argument("--manifest", type=Path, default=ROOT / "corpus.jsonl")
    import_parser.add_argument("--sheet", type=Path, default=ROOT / "transcription-sheet.csv")
    status_parser = subparsers.add_parser("status", help="verify uploaded files against manifest metadata")
    status_parser.add_argument("--manifest", type=Path, default=ROOT / "corpus.jsonl")
    status_parser.add_argument("--clip")
    args = parser.parse_args()

    if args.command == "init":
        init_corpus(args.profile, args.output, args.priors)
    elif args.command == "annotate":
        annotate(args.manifest, args.clip_id, args.spoken)
    elif args.command == "export-sheet":
        export_sheet(args.manifest, args.output)
    elif args.command == "import-sheet":
        import_sheet(args.manifest, args.sheet)
    elif args.command == "status":
        show_status(args.manifest, args.clip)
    else:
        rows = validate_manifest(
            args.manifest,
            require_audio=not args.draft,
            require_complete_stage1=True,
        ) if not args.draft else _validate_draft(args.manifest)
        print(f"Valid: {len(rows)} clips")


def _validate_draft(path: Path) -> list[dict[str, Any]]:
    rows = read_jsonl(path)
    temporary = []
    for row in rows:
        copied = dict(row)
        copied["spoken"] = copied.get("spoken") or copied.get("planned_prompt") or "draft"
        temporary.append(copied)
    temp_path = path.with_suffix(".validation.tmp")
    try:
        write_jsonl(temp_path, temporary)
        return validate_manifest(temp_path, require_audio=False, require_complete_stage1=True)
    finally:
        temp_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
