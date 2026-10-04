from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from bench.asr.manifest import validate_manifest


ROOT = Path(__file__).resolve().parent


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    corpus = ROOT / "corpus.jsonl"
    priors = ROOT / "priors.json"
    normalizer = ROOT / "normalize.py"
    validate_manifest(corpus, require_audio=True, require_complete_stage1=True)
    if not priors.is_file():
        raise SystemExit(f"Missing {priors}")
    output = ROOT / "frozen-artifacts.json"
    if output.exists():
        raise SystemExit("Artifacts are already frozen. Do not overwrite; log the change and rerun everything if an extension is necessary.")
    payload = {
        "frozen_at": datetime.now(timezone.utc).isoformat(),
        "note": "Repository had no Git metadata, so content SHA-256 values are the audit boundary.",
        "artifacts": {
            "corpus.jsonl": digest(corpus),
            "priors.json": digest(priors),
            "normalize.py": digest(normalizer),
        },
    }
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Frozen corpus, priors, and normalizer in {output}")


if __name__ == "__main__":
    main()
