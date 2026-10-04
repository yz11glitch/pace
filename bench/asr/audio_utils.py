"""Compatibility exports for benchmark tooling; production owns WAV inspection."""

from noted.audio import AudioValidationError, inspect_wav, inspect_wav_bytes

__all__ = ["AudioValidationError", "inspect_wav", "inspect_wav_bytes"]
