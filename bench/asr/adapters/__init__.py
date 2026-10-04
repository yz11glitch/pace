from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from bench.asr.adapters.parakeet import ParakeetAdapter
from bench.asr.adapters.whisper import WhisperAdapter


ASR_ROOT = Path(__file__).resolve().parents[1]


def load_configs() -> dict[str, dict[str, Any]]:
    return json.loads((ASR_ROOT / "configs.json").read_text(encoding="utf-8"))


def create_adapter(config_id: str, model_root: Path | None = None):
    configs = load_configs()
    if config_id not in configs:
        raise KeyError(f"Unknown config {config_id!r}; choose from {', '.join(configs)}")
    config = configs[config_id]
    model_path = (model_root or ASR_ROOT / "models") / config_id
    if not model_path.is_dir():
        raise FileNotFoundError(
            f"Model snapshot missing: {model_path}. Run: uv run python -m bench.asr.download_models --model {config_id}"
        )
    if config["family"] == "parakeet":
        return ParakeetAdapter(config_id, config, model_path)
    if config["family"] == "whisper":
        return WhisperAdapter(config_id, config, model_path)
    raise ValueError(f"Unsupported adapter family: {config['family']}")

