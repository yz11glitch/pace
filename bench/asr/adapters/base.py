from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any


class ASRAdapter(ABC):
    def __init__(self, config_id: str, config: dict[str, Any], model_path: Path):
        self.config_id = config_id
        self.config = config
        self.model_path = model_path

    @abstractmethod
    def load(self) -> None:
        """Load and evaluate weights so cold-load time is measurable."""

    @abstractmethod
    def transcribe(self, wav_bytes: bytes) -> str:
        """Return only the raw transcript for a PCM WAV byte string."""

    @abstractmethod
    def close(self) -> None:
        """Release references and clear the MLX cache where possible."""

