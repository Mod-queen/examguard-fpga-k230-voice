"""Durable single-datagram HR v1 history-result receiver.

Each record is already one complete 128-byte datagram, so there is no frame or
window assembly. Records are keyed by (transaction, window, token) and written
as raw.hr + manifest.json under history_results/. Duplicate identical records
are ignored; a conflicting duplicate is rejected rather than overwritten.
This module does not prove coverage and does not associate pixels by itself.
"""
from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import time

from .history_result import HistoryResultError, decode_history_result
from .protocol import ProtocolError


@dataclass
class _Seen:
    sha256: str
    path: Path


class HistoryResultReceiver:
    def __init__(self, root, *, max_records=4096, clock=time.monotonic, on_write=None):
        if max_records <= 0:
            raise ValueError("max_records must be positive")
        self.root = Path(root)
        self.max_records = max_records
        self.clock = clock
        self.on_write = on_write
        self.seen: OrderedDict[tuple, _Seen] = OrderedDict()
        self.written = 0
        self.duplicates = 0
        self.rejected = 0

    def _key(self, record, data):
        return (record.transaction, record.window, record.token)

    def _target(self, record):
        return (self.root / "history_results" / record.transaction.hex()
                / f"w{record.window:08x}_t{record.token:08x}")

    def ingest(self, data: bytes):
        try:
            record = decode_history_result(data)
        except HistoryResultError as exc:
            raise ProtocolError(f"bad HR record: {exc}") from exc
        key = self._key(record, data)
        digest = hashlib.sha256(data).hexdigest()
        if key in self.seen:
            if self.seen[key].sha256 == digest:
                self.duplicates += 1
                return self.seen[key].path / "manifest.json"
            self.rejected += 1
            raise ProtocolError("conflicting HR result for the same transaction/window/token")
        target = self._target(record)
        raw_path = target / "raw.hr"
        if raw_path.exists():
            existing = hashlib.sha256(raw_path.read_bytes()).hexdigest()
            if existing == digest:
                self._remember(key, digest, target)
                self.duplicates += 1
                return target / "manifest.json"
            self.rejected += 1
            raise ProtocolError("stored HR result differs from incoming record")
        target.mkdir(parents=True, exist_ok=True)
        tmp = target / "raw.hr.tmp"
        tmp.write_bytes(data)
        os.replace(tmp, raw_path)
        manifest = {
            "schema": "examguard-history-result-v1",
            "received_utc": datetime.now(timezone.utc).isoformat(),
            "raw_sha256": digest,
            "raw_bytes": len(data),
            "result": record.as_dict(),
        }
        manifest_tmp = target / "manifest.json.tmp"
        manifest_tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(manifest_tmp, target / "manifest.json")
        self._remember(key, digest, target)
        if len(self.seen) > self.max_records:
            self.seen.popitem(last=False)
        self.written += 1
        if self.on_write:
            self.on_write(target / "manifest.json", record)
        return target / "manifest.json"

    def _remember(self, key, digest, target):
        self.seen[key] = _Seen(digest, target)
        self.seen.move_to_end(key)

    def flush(self, *, force=False):
        return None
