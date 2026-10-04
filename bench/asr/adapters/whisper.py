from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

import mlx.core as mx
import mlx_whisper
from mlx_whisper.transcribe import ModelHolder

from bench.asr.adapters.base import ASRAdapter


class WhisperAdapter(ASRAdapter):
    def load(self) -> None:
        mx.random.seed(0)
        model = ModelHolder.get_model(str(self.model_path), mx.float16)
        mx.eval(model.parameters())

    def transcribe(self, wav_bytes: bytes) -> str:
        if ModelHolder.model is None or ModelHolder.model_path != str(self.model_path):
            raise RuntimeError("load() must be called before transcribe()")
        mx.random.seed(0)
        with tempfile.NamedTemporaryFile(suffix=".wav") as audio:
            audio.write(wav_bytes)
            audio.flush()
            result = mlx_whisper.transcribe(
                audio.name,
                path_or_hf_repo=str(self.model_path),
                language=self.config.get("language", "en"),
                task="transcribe",
                temperature=0.0,
                beam_size=None,
                best_of=None,
                condition_on_previous_text=False,
                fp16=True,
                verbose=None,
            )
        return str(result["text"]).strip()

    def close(self) -> None:
        ModelHolder.model = None
        ModelHolder.model_path = None
        mx.clear_cache()

