"""Create two synthetic diagnostic clips; never use these as benchmark evidence."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

from bench.asr.audio_utils import inspect_wav
from bench.asr.manifest import write_jsonl


ROOT = Path(__file__).resolve().parent
SMOKE = ROOT / "smoke"
CLIPS = [
    {
        "id": "smoke-01",
        "text": "Spent sixteen fifty at McDonald's.",
        "expect": {"amount": 16.50, "currency": "MYR", "direction": "expense", "merchant": "McDonald's", "item": None, "date_expr": None},
        "ambiguous_by_construction": True,
        "prior_available": True,
    },
    {
        "id": "smoke-02",
        "text": "I got paid three thousand five hundred today.",
        "expect": {"amount": 3500.00, "currency": "MYR", "direction": "income", "merchant": None, "item": None, "date_expr": "today"},
        "ambiguous_by_construction": False,
        "prior_available": False,
    },
]


def main() -> None:
    SMOKE.mkdir(parents=True, exist_ok=True)
    rows = []
    with tempfile.TemporaryDirectory() as temporary:
        for clip in CLIPS:
            aiff = Path(temporary) / f"{clip['id']}.aiff"
            wav = SMOKE / f"{clip['id']}.wav"
            subprocess.run(["say", "-v", "Samantha", "-o", str(aiff), clip["text"]], check=True)
            subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(aiff),
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav),
            ], check=True)
            facts = inspect_wav(wav)
            rows.append({
                "id": clip["id"], "stage": 1, "set": "primary", "category": "A" if clip["id"].endswith("01") else "F",
                "phrase_category": "synthetic_smoke_only", "audio": wav.name, "sha256": facts["sha256"],
                "duration_ms": facts["duration_ms"], "spoken": clip["text"], "planned_prompt": clip["text"],
                "expect": clip["expect"], "ambiguous_by_construction": clip["ambiguous_by_construction"],
                "prior_available": clip["prior_available"], "notes": "Synthetic runtime smoke fixture; excluded from benchmark",
            })
    write_jsonl(SMOKE / "corpus.jsonl", rows)
    (SMOKE / "priors.json").write_text(json.dumps({"merchants": [{
        "name": "McDonald's", "aliases": ["mcdonalds"], "amount_count": 20,
        "amount_min_minor": 600, "amount_max_minor": 4500, "amount_median_minor": 1850,
    }]}, indent=2) + "\n", encoding="utf-8")
    print(f"Created {len(rows)} synthetic smoke clips in {SMOKE}; do not use them in Stage 1 scoring")


if __name__ == "__main__":
    main()
