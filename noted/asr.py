from __future__ import annotations

import threading
from typing import Protocol

from bench.asr.adapters import create_adapter


DEFAULT_ASR_MODEL = "whisper-turbo"


class ASRService(Protocol):
    model_id: str

    def load(self) -> None: ...
    def transcribe(self, wav_bytes: bytes) -> str: ...
    def close(self) -> None: ...


class ConfiguredASR:
    """Production ASR boundary; the configured benchmark-tested adapter is swappable."""

    def __init__(self, model_id: str = DEFAULT_ASR_MODEL):
        self.model_id = model_id
        self._adapter = create_adapter(model_id)
        self._lock = threading.Lock()

    def load(self) -> None:
        with self._lock:
            self._adapter.load()

    def transcribe(self, wav_bytes: bytes) -> str:
        with self._lock:
            return self._adapter.transcribe(wav_bytes)

    def close(self) -> None:
        with self._lock:
            self._adapter.close()

