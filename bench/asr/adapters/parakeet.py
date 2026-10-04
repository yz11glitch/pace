from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

import mlx.core as mx
from parakeet_mlx import DecodingConfig, from_pretrained

from bench.asr.adapters.base import ASRAdapter


class ParakeetAdapter(ASRAdapter):
    def __init__(self, config_id: str, config: dict[str, Any], model_path: Path):
        super().__init__(config_id, config, model_path)
        self.model = None
        self.decoding_config = DecodingConfig()

    def load(self) -> None:
        mx.random.seed(0)
        self.model = from_pretrained(str(self.model_path), dtype=mx.bfloat16)
        # Force lazy arrays to materialize during the cold-load measurement.
        mx.eval(self.model.parameters())

    def transcribe(self, wav_bytes: bytes) -> str:
        if self.model is None:
            raise RuntimeError("load() must be called before transcribe()")
        mx.random.seed(0)
        with tempfile.NamedTemporaryFile(suffix=".wav") as audio:
            audio.write(wav_bytes)
            audio.flush()
            result = self.model.transcribe(
                audio.name,
                decoding_config=self.decoding_config,
            )
        return result.text.strip()

    def close(self) -> None:
        self.model = None
        mx.clear_cache()
