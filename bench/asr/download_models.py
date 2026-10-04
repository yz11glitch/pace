from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any

from huggingface_hub import HfApi, snapshot_download


ROOT = Path(__file__).resolve().parent


def directory_size(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def main() -> None:
    parser = argparse.ArgumentParser(description="Resolve and download the four pinned Gate 2 snapshots")
    parser.add_argument("--model", action="append", default=[], help="config ID; repeatable (default: all)")
    parser.add_argument("--verify-only", action="store_true", help="query metadata without downloading")
    args = parser.parse_args()
    configs = json.loads((ROOT / "configs.json").read_text(encoding="utf-8"))
    selected = args.model or list(configs)
    unknown = set(selected) - configs.keys()
    if unknown:
        raise SystemExit(f"Unknown configs: {sorted(unknown)}")

    available = shutil.disk_usage(ROOT).free
    expected_total = sum(int(configs[name]["expected_repo_bytes"]) for name in selected)
    print(f"Selected snapshot payload: {expected_total / 1024**3:.3f} GiB; free disk: {available / 1024**3:.1f} GiB")
    if not args.verify_only and available < expected_total + 2 * 1024**3:
        raise SystemExit("Insufficient free space (requires payload plus 2 GiB safety margin)")

    api = HfApi()
    metadata_path = ROOT / "models" / "metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8")) if metadata_path.exists() else {}
    for name in selected:
        config = configs[name]
        info = api.model_info(config["repo_id"], revision=config["revision"], files_metadata=True)
        resolved_bytes = sum(int(sibling.size or 0) for sibling in info.siblings)
        if info.sha != config["revision"]:
            raise SystemExit(f"{name}: requested {config['revision']} but hub resolved {info.sha}")
        if resolved_bytes != config["expected_repo_bytes"]:
            raise SystemExit(
                f"{name}: repository size changed: pinned {config['expected_repo_bytes']}, resolved {resolved_bytes}"
            )
        print(f"{name}: {config['repo_id']}@{info.sha} = {resolved_bytes / 1024**3:.3f} GiB")
        entry = {"repo_id": config["repo_id"], "commit_sha": info.sha, "repo_bytes": resolved_bytes}
        if not args.verify_only:
            target = ROOT / "models" / name
            snapshot_download(
                repo_id=config["repo_id"],
                revision=config["revision"],
                local_dir=target,
            )
            entry["on_disk_bytes"] = directory_size(target)
            print(f"  stored at {target} ({entry['on_disk_bytes'] / 1024**3:.3f} GiB)")
        metadata[name] = entry
    if not args.verify_only:
        metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"Wrote {metadata_path}")


if __name__ == "__main__":
    main()
