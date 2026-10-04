from __future__ import annotations

import argparse
import gc
import hashlib
import importlib.metadata
import json
import os
import platform
import random
import re
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import mlx.core as mx
import psutil

from bench.asr.adapters import create_adapter, load_configs
from bench.asr.manifest import validate_manifest
from bench.asr.normalize import normalize_transcript


ROOT = Path(__file__).resolve().parent


class MemoryMonitor:
    def __init__(self, hz: int = 20):
        self.interval = 1 / hz
        self.process = psutil.Process()
        self.peak_rss = self.process.memory_info().rss
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._sample, daemon=True)

    def _sample(self) -> None:
        while not self._stop.wait(self.interval):
            self.peak_rss = max(self.peak_rss, self.process.memory_info().rss)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *_args):
        self._stop.set()
        self._thread.join()
        self.peak_rss = max(self.peak_rss, self.process.memory_info().rss)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def environment() -> dict[str, Any]:
    packages = {}
    for name in ("mlx", "mlx-whisper", "parakeet-mlx", "psutil", "jiwer", "scipy"):
        packages[name] = importlib.metadata.version(name)
    try:
        power = subprocess.run(["pmset", "-g", "batt"], check=False, capture_output=True, text=True).stdout.strip()
    except OSError:
        power = "unavailable"
    return {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "macos": platform.mac_ver()[0],
        "machine": platform.machine(),
        "python": platform.python_version(),
        "logical_cpu_count": psutil.cpu_count(),
        "physical_memory_bytes": psutil.virtual_memory().total,
        "power_status": power,
        "packages": packages,
    }


def assert_machine_conditions() -> None:
    battery = subprocess.run(["pmset", "-g", "batt"], check=True, capture_output=True, text=True).stdout
    if "AC Power" not in battery:
        raise SystemExit("Stage 1 must run on mains power; pmset reports battery power.")
    current = subprocess.run(["pmset", "-g"], check=True, capture_output=True, text=True).stdout
    match = next((line for line in current.splitlines() if "lowpowermode" in line), "")
    if match and not re.search(r"lowpowermode\s+0\b", match):
        raise SystemExit(f"Stage 1 requires Low Power Mode off; pmset reports: {match.strip()}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run identical audio through Gate 2 ASR configs")
    parser.add_argument("--model", action="append", default=[], help="config ID; repeatable (default: all four)")
    parser.add_argument("--manifest", type=Path, default=ROOT / "corpus.jsonl")
    parser.add_argument("--priors", type=Path, default=ROOT / "priors.json")
    parser.add_argument("--results", type=Path, default=ROOT / "results")
    parser.add_argument("--passes", type=int, default=3)
    parser.add_argument("--cooldown", type=float, default=60.0, help="seconds between configs")
    parser.add_argument("--seed", type=int, default=20260914)
    parser.add_argument("--allow-incomplete", action="store_true", help="smoke fixtures only")
    parser.add_argument("--conditions-confirmed", action="store_true", help="assert mains, Low Power Mode off, and other apps closed")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.passes < 1:
        raise SystemExit("--passes must be positive")
    configs = load_configs()
    selected = args.model or list(configs)
    unknown = set(selected) - configs.keys()
    if unknown:
        raise SystemExit(f"Unknown configs: {sorted(unknown)}")
    if not args.allow_incomplete and not args.conditions_confirmed:
        raise SystemExit("Full Stage 1 requires --conditions-confirmed after checking mains power, Low Power Mode, and other apps.")
    if not args.allow_incomplete:
        assert_machine_conditions()

    if not args.allow_incomplete:
        freeze_path = ROOT / "frozen-artifacts.json"
        if not freeze_path.is_file():
            raise SystemExit("Freeze the validated artifacts first: uv run python -m bench.asr.freeze")
        frozen = json.loads(freeze_path.read_text(encoding="utf-8"))["artifacts"]
        current = {
            "corpus.jsonl": sha256_file(args.manifest),
            "priors.json": sha256_file(args.priors),
            "normalize.py": sha256_file(ROOT / "normalize.py"),
        }
        if frozen != current:
            raise SystemExit(f"Frozen artifact mismatch; a full rerun/change log is required.\nFrozen: {frozen}\nCurrent: {current}")

    clips = validate_manifest(
        args.manifest,
        require_audio=True,
        require_complete_stage1=not args.allow_incomplete,
    )
    priors = json.loads(args.priors.read_text(encoding="utf-8")) if args.priors.exists() else {"merchants": []}
    args.results.mkdir(parents=True, exist_ok=True)
    for name in selected:
        target = args.results / name
        target.mkdir(parents=True, exist_ok=True)
        (target / "raw.jsonl").write_text("", encoding="utf-8")

    run_metadata: dict[str, Any] = {
        "environment": environment(),
        "selected_configs": selected,
        "passes": args.passes,
        "cooldown_seconds": args.cooldown,
        "random_seed": args.seed,
        "conditions_confirmed": args.conditions_confirmed,
        "artifacts": {
            "manifest": {"path": str(args.manifest), "sha256": sha256_file(args.manifest)},
            "priors": {"path": str(args.priors), "sha256": sha256_file(args.priors)} if args.priors.exists() else None,
            "normalizer": {"path": str(ROOT / "normalize.py"), "sha256": sha256_file(ROOT / "normalize.py")},
        },
        "config_order": [],
        "models": {},
    }
    model_metadata_path = ROOT / "models" / "metadata.json"
    resolved_models = json.loads(model_metadata_path.read_text(encoding="utf-8")) if model_metadata_path.exists() else {}

    rng = random.Random(args.seed)
    total_configs_run = 0
    for pass_index in range(1, args.passes + 1):
        order = list(selected)
        rng.shuffle(order)
        run_metadata["config_order"].append({"pass": pass_index, "order": order})
        print(f"Pass {pass_index}/{args.passes}: {' -> '.join(order)}", flush=True)
        for config_index, config_id in enumerate(order):
            if total_configs_run and args.cooldown:
                print(f"Cooling down for {args.cooldown:g}s before {config_id}…", flush=True)
                time.sleep(args.cooldown)
            total_configs_run += 1
            started_at = datetime.now(timezone.utc).isoformat()
            print(f"Loading {config_id} at {started_at}", flush=True)
            mx.reset_peak_memory()
            monitor = MemoryMonitor(hz=20)
            with monitor:
                adapter = create_adapter(config_id)
                load_started = time.perf_counter()
                adapter.load()
                load_ms = (time.perf_counter() - load_started) * 1000

                warmup_started = time.perf_counter()
                adapter.transcribe((args.manifest.parent / clips[0]["audio"]).read_bytes())
                warmup_ms = (time.perf_counter() - warmup_started) * 1000
                steady_rss = psutil.Process().memory_info().rss
                steady_mlx_active = mx.get_active_memory()
                print(f"  loaded {load_ms:.0f}ms; warm-up {warmup_ms:.0f}ms", flush=True)

                for clip in clips:
                    wav = (args.manifest.parent / clip["audio"]).read_bytes()
                    started = time.perf_counter()
                    transcript = adapter.transcribe(wav)
                    latency_ms = (time.perf_counter() - started) * 1000
                    row = {
                        "config": config_id,
                        "pass": pass_index,
                        "clip_id": clip["id"],
                        "set": clip["set"],
                        "category": clip["category"],
                        "raw_transcript": transcript,
                        "normalized_transcript": normalize_transcript(transcript),
                        "latency_ms": round(latency_ms, 3),
                        "config_started_at": started_at,
                    }
                    with (args.results / config_id / "raw.jsonl").open("a", encoding="utf-8") as handle:
                        handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
                    print(f"  {clip['id']}: {latency_ms:.0f}ms | {transcript}", flush=True)

                pass_peak_mlx = mx.get_peak_memory()
                adapter.close()
            gc.collect()
            model_entry = run_metadata["models"].setdefault(config_id, {
                **resolved_models.get(config_id, {}),
                "passes": [],
            })
            if "cold_load_ms" not in model_entry:
                model_entry["cold_load_ms"] = round(load_ms, 3)
            model_entry["passes"].append({
                "pass": pass_index,
                "started_at": started_at,
                "load_ms": round(load_ms, 3),
                "warmup_ms": round(warmup_ms, 3),
                "steady_rss_bytes": steady_rss,
                "steady_mlx_active_bytes": steady_mlx_active,
                "peak_process_rss_bytes": monitor.peak_rss,
                "peak_mlx_bytes": pass_peak_mlx,
            })
            (args.results / "run.json").write_text(json.dumps(run_metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"Raw results written to {args.results}")


if __name__ == "__main__":
    main()
