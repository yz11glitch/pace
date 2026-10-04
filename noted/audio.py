from __future__ import annotations

import hashlib
import io
import wave
from pathlib import Path


class AudioValidationError(ValueError):
    pass


def inspect_wav_bytes(data: bytes) -> dict[str, int | str]:
    sha256 = hashlib.sha256(data).hexdigest()
    try:
        with wave.open(io.BytesIO(data), "rb") as wav:
            channels = wav.getnchannels()
            sample_rate = wav.getframerate()
            sample_width = wav.getsampwidth()
            frames = wav.getnframes()
            compression = wav.getcomptype()
    except (wave.Error, EOFError) as exc:
        raise AudioValidationError(f"invalid WAV: {exc}") from exc
    if channels != 1:
        raise AudioValidationError(f"expected mono WAV, got {channels} channels")
    if sample_rate != 16_000:
        raise AudioValidationError(f"expected 16000 Hz WAV, got {sample_rate} Hz")
    if sample_width != 2:
        raise AudioValidationError(f"expected PCM16 WAV, got {sample_width * 8}-bit samples")
    if compression != "NONE":
        raise AudioValidationError(f"expected uncompressed PCM WAV, got {compression}")
    if frames == 0:
        raise AudioValidationError("WAV contains no audio frames")
    return {
        "sha256": sha256,
        "duration_ms": round(frames * 1000 / sample_rate),
        "sample_rate": sample_rate,
        "channels": channels,
        "sample_width_bits": sample_width * 8,
        "frames": frames,
        "bytes": len(data),
    }


def inspect_wav(path: Path) -> dict[str, int | str]:
    return inspect_wav_bytes(path.read_bytes())

