"""Opt-in, local, bounded capture diagnostics. No audio bytes or model raw output."""

from __future__ import annotations

import threading
import uuid
from collections import deque
from datetime import datetime, timezone


def _bound(value):
    if isinstance(value, str):
        return value[:1000]
    if isinstance(value, dict):
        return {key: _bound(item) for key, item in list(value.items())[:20]}
    if isinstance(value, (list, tuple)):
        return [_bound(item) for item in value[:10]]
    return value


class CaptureTrace:
    def __init__(self, kind: str):
        self.id = str(uuid.uuid4())
        self.started_at = datetime.now(timezone.utc).isoformat()
        self.kind = kind
        self.stages: list[dict] = []

    def add(self, stage: str, status: str, **details) -> None:
        self.stages.append({"stage": stage, "status": status, **_bound(details)})

    def has_final(self) -> bool:
        return any(stage["stage"] == "final" for stage in self.stages)

    def as_dict(self) -> dict:
        return {"id": self.id, "started_at": self.started_at,
                "kind": self.kind, "stages": self.stages}


class CaptureTraceBuffer:
    def __init__(self, *, enabled: bool, capacity: int = 50):
        self.enabled = enabled
        self.capacity = capacity
        self._items: deque[dict] = deque(maxlen=capacity)
        self._lock = threading.Lock()

    def begin(self, kind: str) -> CaptureTrace | None:
        return CaptureTrace(kind) if self.enabled else None

    def finish(self, trace: CaptureTrace | None) -> None:
        if trace is None:
            return
        with self._lock:
            self._items.appendleft(trace.as_dict())

    def recent(self, limit: int = 20) -> list[dict]:
        with self._lock:
            return list(self._items)[:limit]


def trace_event(trace: CaptureTrace | None, stage: str, status: str, **details) -> None:
    if trace is not None:
        trace.add(stage, status, **details)
